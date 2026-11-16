#!/bin/bash
# 在 DDK 容器里为本 KMI 构建全部模块。
#
# 核心原则: 每个 KMI 用**它自己内核树里的**驱动源码。
#
#   vkms / macvlan 都是内核树里的普通驱动文件, 它们的 API 随内核版本变化
#   (net_device 的字段、drm_gem_shmem 的接口、drmm_ 系列的引入时间...)。
#   拿 6.1 的副本去编 5.10 必然缺字段。DDK 的 kdir 是完整内核源码树,
#   直接用它 drivers/ 下的源码, 天然匹配该版本。
#
#   devtmpfs_lkm / ip6table_nat 是我们自己的实现(内核里没有可对应的独立
#   驱动), 跨版本失败可以接受, 记 warning 继续。
#
# 用法: build_modules.sh <KMI> <KDIR> <WORKSPACE> <OUT>
set -uo pipefail

KMI="${1:?KMI}"
KDIR="${2:?KDIR}"
WS="${3:?WORKSPACE}"
OUT="${4:?OUT}"
NPROC="$(nproc 2>/dev/null || echo 4)"

mkdir -p "$OUT"
FAILED=()

log() { echo ">>> $*"; }
warn() { echo "::warning::$*"; FAILED+=("$*"); }


# ---------------------------------------------------------------------------
# 符号类型自检：模块内定义为 OBJECT（数据）的符号，不能被 CALL26（函数调用）引用
#
# 这是 v0.1.15 那个 panic 的特征：kallrecon_klp 其实是函数指针变量，
# common.c 里写成了函数。符号名相同所以链接过得去，但运行时是跳到那个
# 数据变量的地址执行，写坏内核内存，几十毫秒后在完全无关的路径上崩。
#
# 静态类型检查跨编译单元看不到这种错，只有看最终产物的重定位类型才能发现。
# ---------------------------------------------------------------------------
reloc_audit() {
    local ko="$1" objf callf bad
    command -v readelf >/dev/null 2>&1 || return 0
    objf=$(mktemp); callf=$(mktemp)
    readelf -sW "$ko" 2>/dev/null | awk '$4=="OBJECT"{print $8}' | sort -u > "$objf"
    readelf -rW "$ko" 2>/dev/null | awk '$3=="R_AARCH64_CALL26"{print $5}' | sort -u > "$callf"
    bad=$(comm -12 "$objf" "$callf" 2>/dev/null)
    rm -f "$objf" "$callf"
    if [ -n "$bad" ]; then
        warn "RELO C: $(basename "$ko") 对数据符号发起了函数调用（声明类型写错）:"
        printf '%s
' "$bad" | while read -r x; do warn "        $x"; done
        return 1
    fi
    return 0
}


# DDK 的 kdir 可能只有 vmlinux/symvers, 源码在别处; 两个位置都试
KSRC=""
if [ -n "${KSRC_OVERRIDE:-}" ] && [ -d "$KSRC_OVERRIDE" ]; then
    KSRC="$KSRC_OVERRIDE"
else
for c in "$KDIR" "$KDIR/../src" "/opt/ddk/src/$KMI" "/opt/ddk/kernel/$KMI"; do
    if [ -d "$c/drivers/gpu/drm" ] || [ -d "$c/drivers/net" ]; then
        KSRC="$c"; break
    fi
done
fi

log "KMI=$KMI"
log "KDIR=$KDIR"

# ---------------------------------------------------------------------------
# 栈保护 guard 模式：必须和目标内核一致，否则模块根本装不上
#
# arm64 有两种模式：
#   CONFIG_STACKPROTECTOR_PER_TASK=y  金丝雀放在 task_struct 里，用
#                                      sp_el0+offset 相对寻址，**不需要**任何
#                                      全局符号。
#   否则                              模块引用全局的 __stack_chk_guard。
#
# 而 5.10 GKI 的 arch/arm64/kernel/process.c 写得很清楚：
#   #if defined(CONFIG_STACKPROTECTOR) && !defined(CONFIG_STACKPROTECTOR_PER_TASK)
#   EXPORT_SYMBOL(__stack_chk_guard);
#   #endif
# 也就是说真机（PER_TASK=y）**导出的符号表里没有 __stack_chk_guard**。
#
# DDK 给 5.10 的那棵树如果判定不出 sysreg 支持（老 clang 缺
# -mstack-protector-guard=sysreg），会退回全局模式，编出来的 .ko 就带着
# 这个符号，到了真机 insmod 全报 "Unknown symbol __stack_chk_guard"。
#
# 树不是 PER_TASK 模式时，干脆关掉本模块的栈保护：金丝雀没了，但能装。
# 树是 PER_TASK 模式时保持原样（kbuild 自己会加 sysreg 参数）。
# ---------------------------------------------------------------------------
GUARD_CFLAGS=""
GUARD_MODE="per-task"
CFG=""
for c in "$KDIR/.config" "$KDIR/out/.config"; do
    [ -f "$c" ] && { CFG="$c"; break; }
done
if [ -n "$CFG" ]; then
    if ! grep -qx 'CONFIG_STACKPROTECTOR_PER_TASK=y' "$CFG"; then
        GUARD_CFLAGS="-fno-stack-protector"
        GUARD_MODE="global->disabled"
    fi
    log "栈保护: 树=$GUARD_MODE 额外参数=[${GUARD_CFLAGS:-无}]"
else
    warn "找不到 $KDIR/.config，栈保护模式无法判定；构建后会再做符号校验"
fi

if [ -n "$KSRC" ]; then
    log "源码树=$KSRC"
    log "  vkms:    $([ -d "$KSRC/drivers/gpu/drm/vkms" ] && echo 有 || echo 无)"
    log "  macvlan: $([ -f "$KSRC/drivers/net/macvlan.c" ] && echo 有 || echo 无)"
else
    warn "找不到内核源码树, 将退回仓库内副本"
fi

# 把一组 .c 编成 obj-m := <mod>.o 形式的 Makefile
gen_makefile() {
    local dir="$1" mod="$2" extra_cflags="${3:-}"
    local objs count single
    objs="$(cd "$dir" && ls ./*.c 2>/dev/null | sed 's#^\./##; s#\.c$#.o#' | tr '\n' ' ')"
    count="$(cd "$dir" && ls ./*.c 2>/dev/null | wc -l)"
    single="$(echo "$objs" | awk '{print $1}')"
    {
        echo "obj-m := $mod.o"
        # 单文件且源码名等于模块名 (macvlan.c → macvlan.o) 时**不能**写
        # "<mod>-y := <mod>.o": kbuild 会报
        #   Circular <mod>.o <- <mod>.o dependency dropped
        # 然后 ld 找不到目标文件。这种情况让 kbuild 自己按 <mod>.c 推导即可。
        if [ "$count" -gt 1 ]; then
            echo "$mod-y := $objs"
        elif [ "$single" != "$mod.o" ]; then
            # 多源或文件名与模块名不一致 (vkms_drv.c → vkms.o), 必须显式列出
            echo "$mod-y := $objs"
        fi
        [ -n "$extra_cflags" ] && echo "ccflags-y += $extra_cflags"
    } > "$dir/Makefile"
}

# ---------------------------------------------------------------------------
# 1) lkm4ctr —— 上游已做跨版本适配, 直接用
# ---------------------------------------------------------------------------
log "=== lkm4ctr @ $KMI ==="
LKM4CTR_DIR=${LKM4CTR_DIR:-/tmp/lkm4ctr}
if make -C "$KDIR" M="$LKM4CTR_DIR/vendor" LKM4CTR_LOG_DMESG=y KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
    cp "$LKM4CTR_DIR/vendor/lkm4ctr.ko" "$OUT/lkm4ctr-$KMI.ko" && log "  [OK]"
else
    warn "lkm4ctr @ $KMI"
fi

# ---------------------------------------------------------------------------
# 2) vkms —— 内核树里的源码 + DRIVER_RENDER 补丁
#
# 上游 vkms 的 driver_features 没有 DRIVER_RENDER, drm_dev_register() 就
# 不会分配 render minor, 于是只有 card 没有 /dev/dri/renderD*。而 Wayland
# 合成器(gbm_create_device + drmOpenRender)要的正是 render node。
# ---------------------------------------------------------------------------
log "=== vkms @ $KMI ==="
SKIP_VKMS=0
DST=/tmp/mod-vkms
rm -rf "$DST"; mkdir -p "$DST"
if [ -n "$KSRC" ] && [ -d "$KSRC/drivers/gpu/drm/vkms" ]; then
    cp -a "$KSRC/drivers/gpu/drm/vkms/". "$DST/" 2>/dev/null || true
    # Makefile 由我们生成, 内核树里那份是 obj-$(CONFIG_DRM_VKMS) 形式
    rm -f "$DST/Makefile" "$DST/Kconfig"

    # DRIVER_RENDER 补丁交给独立脚本。内联 heredoc 里的正则很容易
    # 被 shell 转义吃掉: 之前 [^,换行] 那个字符类被写成真实换行,
    # 正则失效, 补丁静默没打上, 产物里的 vkms 只建 card 没有 render node。
    if ! grep -q 'DRIVER_RENDER' "$DST/vkms_drv.c" 2>/dev/null; then
        if ! python3 "$WS/scripts/patch_vkms_driver_features.py" "$DST/vkms_drv.c"; then
            warn "vkms @ $KMI (DRIVER_RENDER 补丁失败)"
        fi
    fi
    # 二次确认: 没打上就不出货 —— 没有 DRIVER_RENDER 的 vkms 只能建 card,
    # 拿不到 render node, 对 Wayland 合成器完全没用
    if ! grep -q 'DRIVER_RENDER' "$DST/vkms_drv.c" 2>/dev/null; then
        warn "vkms @ $KMI (driver_features 里没有 DRIVER_RENDER, 跳过出货)"
        SKIP_VKMS=1
    fi

    # drm_debugfs_create_files / drm_crtc_add_crc_entry 由
    # drm-$(CONFIG_DEBUG_FS) 提供。GKI 的 gdefconfig 没打开 DEBUG_FS，
    # 相当一部分真机是 n —— 那些内核里这两个符号根本不存在，vkms 直接
    # "Unknown symbol" 装不上（实测 5.10.269-gki）。
    # 两处都是纯调试功能，去掉不影响 render node。
    if ! python3 "$WS/scripts/patch_vkms_debugfs.py" "$DST"; then
        warn "vkms @ $KMI (DEBUG_FS 兼容补丁失败, 跳过出货)"
        SKIP_VKMS=1
    fi

    log "  driver_features: $(grep -h 'driver_features' "$DST/vkms_drv.c" 2>/dev/null | head -1 | tr -s ' ')"

    if [ "${SKIP_VKMS:-0}" = "1" ]; then
        warn "vkms @ $KMI (补丁未生效, 不编译)"
    else
        gen_makefile "$DST" vkms "-DCONFIG_DRM_VKMS=1"
        if make -C "$KDIR" M="$DST" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
            cp "$DST/vkms.ko" "$OUT/vkms-$KMI.ko" && log "  [OK]"
        else
            warn "vkms @ $KMI"
        fi
    fi
else
    warn "vkms @ $KMI (内核树无源码)"
fi

# ---------------------------------------------------------------------------
# 3) macvlan —— 内核树里的源码
# ---------------------------------------------------------------------------
log "=== macvlan @ $KMI ==="
DST=/tmp/mod-macvlan
rm -rf "$DST"; mkdir -p "$DST"
if [ -n "$KSRC" ] && [ -f "$KSRC/drivers/net/macvlan.c" ]; then
    # 只复制 .c, 不复制头文件: macvlan.c 用的是 #include <linux/if_macvlan.h>,
    # 那个头必须从内核树的 include 路径解析。把副本塞进模块目录反而会因为它
    # 自己内部又 include 别的东西而失败 (表现为 "No such file or directory")
    cp "$KSRC/drivers/net/macvlan.c" "$DST/"
    gen_makefile "$DST" macvlan "-DCONFIG_MACVLAN=1"
    if make -C "$KDIR" M="$DST" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
        cp "$DST/macvlan.ko" "$OUT/macvlan-$KMI.ko" && log "  [OK]"
    else
        warn "macvlan @ $KMI"
    fi
else
    warn "macvlan @ $KMI (内核树无源码)"
fi

# ---------------------------------------------------------------------------
# 4) devtmpfs_lkm / ip6table_nat —— 仓库内实现
# ---------------------------------------------------------------------------
for m in devtmpfs net_ip6nat; do
    SRC="$WS/extra/$m"
    [ -f "$SRC/Makefile" ] || continue
    log "=== $m @ $KMI ==="
    find "$SRC" -name '*.o' -delete 2>/dev/null || true
    find "$SRC" -name '.*.cmd' -delete 2>/dev/null || true
    if make -C "$KDIR" M="$SRC" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
        case "$m" in
            devtmpfs)   cp "$SRC"/devtmpfs_lkm.ko "$OUT/devtmpfs_lkm-$KMI.ko" ;;
            net_ip6nat) cp "$SRC"/ip6table_nat.ko "$OUT/ip6table_nat-$KMI.ko" ;;
        esac
        log "  [OK]"
    else
        warn "$m @ $KMI"
    fi
    find "$SRC" -name '*.o' -delete 2>/dev/null || true
    find "$SRC" -name '.*.cmd' -delete 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# 5) droid_lkm_pids / droid_lkm_cpu —— cgroup limits 仿真
#
# 这两个模块在运行时解析符号并 kprobe，不依赖编译期 config；但内置的
# KallRecon 与布局自校验是按 CGROUP_SUBSYS_COUNT 算偏移的，各 KMI 的
# 控制器数量不同，所以每个 KMI 都要单独编、单独验。
# ---------------------------------------------------------------------------
for m in pids cpu; do
    SRC="$WS/extra/cgrouplimits"
    [ -f "$SRC/Makefile" ] || continue
    log "=== droid_lkm_$m @ $KMI ==="
    find "$SRC" -name '*.o' -delete 2>/dev/null || true
    find "$SRC" -name '.*.cmd' -delete 2>/dev/null || true
    find "$SRC" -name '*.ko' -delete 2>/dev/null || true
    find "$SRC" -name '*.mod' -delete 2>/dev/null || true
    rm -f "$SRC"/modules.order "$SRC"/Module.symvers 2>/dev/null || true
    # Makefile 支持 MODULE=<name> 只编一个目标；两个模块共用一份
    # KallRecon，同时编会让一条失败连带另一条，CI 逐个出货更稳
    if make -C "$KDIR" M="$SRC" MODULE="droid_lkm_$m" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
        if [ -f "$SRC/droid_lkm_$m.ko" ]; then
            cp "$SRC/droid_lkm_$m.ko" "$OUT/droid_lkm_$m-$KMI.ko"
          # 符号类型自检：防止"函数指针变量被误声明成函数"这类
          # 符号名对得上、运行时语义全错的问题流出去
          if ! reloc_audit "$OUT/droid_lkm_$m-$KMI.ko"; then
              warn "droid_lkm_$m @ $KMI 符号类型自检失败，已删除产物"
              rm -f "$OUT/droid_lkm_$m-$KMI.ko"
              continue
          fi
            log "  [OK]"
        else
            warn "droid_lkm_$m @ $KMI (没有产物)"
        fi
    else
        warn "droid_lkm_$m @ $KMI"
    fi
    find "$SRC" -name '*.o' -delete 2>/dev/null || true
    find "$SRC" -name '.*.cmd' -delete 2>/dev/null || true
    find "$SRC" -name '*.ko' -delete 2>/dev/null || true
    find "$SRC" -name '*.mod' -delete 2>/dev/null || true
    rm -f "$SRC"/modules.order "$SRC"/Module.symvers 2>/dev/null || true
done

# ---------------------------------------------------------------------------
# uart_guard —— 阻止读坏掉的 tty_port 把内核打挂
#
# 串口 sysfs 属性（port/type/console/...）走 uart_get_info() 或 console_show()，
# 两者都在**没有有效性检查**的情况下 lock port->mutex（上游至今如此）。
# 某设备的 tty_port 生命周期不完整时，容器里的 udev 扫一遍 /sys/class/tty
# 就能把宿主内核打 panic（实测 ttyS3 = 蓝牙串口）。
# ---------------------------------------------------------------------------
log "=== uart_guard @ $KMI ==="
UG="$WS/extra/uart_guard"
if [ -d "$UG" ]; then
    find "$UG" -name '*.o' -delete 2>/dev/null || true
    find "$UG" -name '.*.cmd' -delete 2>/dev/null || true
    find "$UG" -name '*.ko' -delete 2>/dev/null || true
    rm -f "$UG"/modules.order "$UG"/Module.symvers 2>/dev/null || true
    if make -C "$KDIR" M="$UG" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
        if [ -f "$UG/uart_guard.ko" ]; then
            cp "$UG/uart_guard.ko" "$OUT/uart_guard-$KMI.ko" && log "  [OK]"
        else
            warn "uart_guard @ $KMI (没有产物)"
        fi
    else
        warn "uart_guard @ $KMI"
    fi
    find "$UG" -name '*.o' -delete 2>/dev/null || true
    find "$UG" -name '.*.cmd' -delete 2>/dev/null || true
    find "$UG" -name '*.ko' -delete 2>/dev/null || true
    rm -f "$UG"/modules.order "$UG"/Module.symvers 2>/dev/null || true
else
    warn "uart_guard @ $KMI (缺少 extra/uart_guard)"
fi


# ---------------------------------------------------------------------------
# 产物符号自检
#
# 装了才知道缺符号是最贵的失败方式：用户装完只看到一句
# "unknown symbol in module"，我们这边什么信号都没有。这里把已知在部分
# 内核上不存在的符号直接查出来，在 CI 就报。
#
# 已知清单：
#   __stack_chk_guard      5.10 GKI 是 PER_TASK 模式，全局符号不存在
#   cgroup_rm_cftypes      5.10 里存在但没 EXPORT_SYMBOL_GPL（6.1 才加）
#   drm_crtc_add_crc_entry 属 drm.ko 的模块依赖，加载时序不对就缺
#   任何 _trace_android_vh_*  vendor hook，不是所有厂商内核都开
# ---------------------------------------------------------------------------
echo
echo "=== $KMI 符号自检 ==="
BAD_SYMS="__stack_chk_guard cgroup_rm_cftypes drm_crtc_add_crc_entry"
bad=0
for ko in "$OUT"/*-"$KMI".ko; do
    [ -f "$ko" ] || continue
    undef=$(nm -u "$ko" 2>/dev/null | awk '{print $2}')
    for sym in $BAD_SYMS; do
        if echo "$undef" | grep -qx "$sym"; then
            echo "  [SYM] $(basename "$ko") 依赖 $sym —— 部分内核不导出"
            bad=$((bad + 1))
        fi
    done
    vh=$(echo "$undef" | grep -E '^_trace_android_vh_' | head -3)
    [ -n "$vh" ] && { echo "  [SYM] $(basename "$ko") 依赖 vendor hook:"; echo "$vh" | sed 's/^/         /'; bad=$((bad + 1)); }
done
if [ "$bad" -eq 0 ]; then
    echo "  [OK] 无已知不可移植符号"
else
    echo "  [WARN] 共 $bad 处，装机前请确认目标内核的导出表"
fi

echo
echo "=== $KMI 产物 ==="
ls -lh "$OUT" 2>/dev/null
echo
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "=== 本 KMI 失败项 (${#FAILED[@]}) ==="
    printf '  - %s\n' "${FAILED[@]}"
fi
# 不返回非 0: 部分模块失败不应中断整条矩阵, 其余 KMI 还应继续产出。

  # ---------------------------------------------------------------------
  # 产物完整性：8 个模块一个都不能少
  #
  # 教训：v0.1.18 里我加的 reloc_audit 因为定义在调用点之后而「永远失败」，
  # 失败分支是「删产物 + continue」，构建照样绿 —— 结果所有 KMI 的 pids/cpu
  # 都被静默删掉，包发出去了才发现只有 6 个模块。
  #
  # 所以这里明确点名缺失项并返回非 0：宁可这一格红，也不要发出残缺的包。
  # ---------------------------------------------------------------------
  missing=""
  for want in lkm4ctr devtmpfs_lkm ip6table_nat macvlan vkms droid_lkm_pids droid_lkm_cpu uart_guard; do
      [ -f "$OUT/$want-$KMI.ko" ] || missing="$missing $want"
  done
  if [ -n "$missing" ]; then
      echo "  [FAIL] $KMI 缺少模块:$missing"
      echo "         残缺的模块包不能发布"
      exit 1
  fi
  echo "  [OK] 8/8 模块齐全"

exit 0
