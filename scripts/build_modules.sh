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

# 构建期文案目录。i18n.sh 之后所有输出按 LKM4CTR_LANG / LANG 选语言，
# 默认英文。里面的句子是 printf 格式串，变量在调用点替换。
# $WS 在上面的 $3 已经赋值，直接用；从 $0 推路径在符号链接下会错。
[ -f "$WS/scripts/i18n.sh" ] && . "$WS/scripts/i18n.sh"

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
        warn "$(printf "$B_RELOC_C" "$(basename "$ko")")"
        printf '%s
' "$bad" | while read -r x; do warn "        $x"; done
        return 1
    fi
    return 0
}


# DDK 的 kdir 可能只有 vmlinux/symvers, 源码在别处; 两个位置都试
KSRC=""
for c in "$KDIR" "$KDIR/../src" "/opt/ddk/src/$KMI" "/opt/ddk/kernel/$KMI"; do
    if [ -d "$c/drivers/gpu/drm" ] || [ -d "$c/drivers/net" ]; then
        KSRC="$c"; break
    fi
done

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
    log "$(printf "$B_STACK_PROBE" "$GUARD_MODE" "${GUARD_CFLAGS:-$B_NONE}")"
else
    warn "$(printf "$B_NO_CONFIG" "$KDIR")"
fi

if [ -n "$KSRC" ]; then
    log "$B_SRC_TREE=$KSRC"
    log "  vkms:    $([ -d "$KSRC/drivers/gpu/drm/vkms" ] && echo "$B_HAVE" || echo "$B_ABSENT")"
    log "  macvlan: $([ -f "$KSRC/drivers/net/macvlan.c" ] && echo "$B_HAVE" || echo "$B_ABSENT")"
else
    warn "$B_NO_KSRC"
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
if make -C "$KDIR" M=/tmp/lkm4ctr/vendor LKM4CTR_LOG_DMESG=y KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
    cp /tmp/lkm4ctr/vendor/lkm4ctr.ko "$OUT/lkm4ctr-$KMI.ko" && log "  [OK]"
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
            warn "$(printf "$B_VKMS_DR_PATCH" "$KMI")"
        fi
    fi
    # 二次确认: 没打上就不出货 —— 没有 DRIVER_RENDER 的 vkms 只能建 card,
    # 拿不到 render node, 对 Wayland 合成器完全没用
    if ! grep -q 'DRIVER_RENDER' "$DST/vkms_drv.c" 2>/dev/null; then
        warn "$(printf "$B_VKMS_NO_DR" "$KMI")"
        SKIP_VKMS=1
    fi

    # drm_debugfs_create_files / drm_crtc_add_crc_entry 由
    # drm-$(CONFIG_DEBUG_FS) 提供。GKI 的 gdefconfig 没打开 DEBUG_FS，
    # 相当一部分真机是 n —— 那些内核里这两个符号根本不存在，vkms 直接
    # "Unknown symbol" 装不上（实测 5.10.269-gki）。
    # 两处都是纯调试功能，去掉不影响 render node。
    if ! python3 "$WS/scripts/patch_vkms_debugfs.py" "$DST"; then
        warn "$(printf "$B_VKMS_DEBUGFS" "$KMI")"
        SKIP_VKMS=1
    fi

    log "  driver_features: $(grep -h 'driver_features' "$DST/vkms_drv.c" 2>/dev/null | head -1 | tr -s ' ')"

    if [ "${SKIP_VKMS:-0}" = "1" ]; then
        warn "$(printf "$B_VKMS_PATCH_NOEFF" "$KMI")"
    else
        gen_makefile "$DST" vkms "-DCONFIG_DRM_VKMS=1"
        if make -C "$KDIR" M="$DST" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
            cp "$DST/vkms.ko" "$OUT/vkms-$KMI.ko" && log "  [OK]"
        else
            warn "vkms @ $KMI"
        fi
    fi
else
    warn "$(printf "$B_VKMS_NO_SRC" "$KMI")"
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
    # [TRIM] 去掉三个在部分厂商内核上不导出的符号依赖：
    #   ndo_dflt_fdb_dump  删掉赋值（NULL 时 rtnl_fdb_dump 本来就会回退到它）
    #   __netif_rx         → netif_rx（同一条收包路径，后者所有内核都导出）
    #   ip_check_defrag    → 恒等内联，跳过分片重组（唯一有语义损失的替换）
    # 依据与取舍写在 scripts/patch_macvlan.py 的头注释里。
    if [ -f "$WS/scripts/patch_macvlan.py" ]; then
        python3 "$WS/scripts/patch_macvlan.py" "$DST/macvlan.c" || \
            warn "$(printf "$B_MACVLAN_REWRITE" "$KMI")"
    fi
    gen_makefile "$DST" macvlan "-DCONFIG_MACVLAN=1"
    if make -C "$KDIR" M="$DST" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
        cp "$DST/macvlan.ko" "$OUT/macvlan-$KMI.ko" && log "  [OK]"
    else
        warn "macvlan @ $KMI"
    fi
else
    warn "$(printf "$B_MACVLAN_NO_SRC" "$KMI")"
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
              warn "$(printf "$B_DLM_AUDIT" "$m" "$KMI")"
              rm -f "$OUT/droid_lkm_$m-$KMI.ko"
              continue
          fi
            log "  [OK]"
        else
            warn "$(printf "$B_DLM_NOPROD" "$m" "$KMI")"
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
            warn "$(printf "$B_UART_NOPROD" "$KMI")"
        fi
    else
        warn "uart_guard @ $KMI"
    fi
    find "$UG" -name '*.o' -delete 2>/dev/null || true
    find "$UG" -name '.*.cmd' -delete 2>/dev/null || true
    find "$UG" -name '*.ko' -delete 2>/dev/null || true
    rm -f "$UG"/modules.order "$UG"/Module.symvers 2>/dev/null || true
else
    warn "$(printf "$B_UART_NOSRC" "$KMI")"
fi

# ---------------------------------------------------------------------------
# mali_nsfix —— 让 Mali kbase 驱动在 PID namespace 里可用
#
# kbase_create_context() 用 task_struct->tgid（init ns 的值）去 find_get_pid()，
# 而 find_get_pid → find_vpid 在调用者的 ns 里查；容器内两者不等，查找失败，
# GPU context 创建被拒（-ESRCH，"Failed to get pid pointer"）。
# 本模块 kprobe find_get_pid，调用者位于 mali_kbase* 模块内时返回调用者自己的
# group_leader —— 宿主机进程本来就是这个结果，所以对 Android 是无操作。
#
# 实验性：只编译，不进完整性断言；编译失败只警告，不阻断发布。
# ---------------------------------------------------------------------------
log "=== mali_nsfix @ $KMI ==="
MN="$WS/extra/mali_nsfix"
if [ -d "$MN" ]; then
    find "$MN" -name '*.o' -delete 2>/dev/null || true
    find "$MN" -name '.*.cmd' -delete 2>/dev/null || true
    find "$MN" -name '*.ko' -delete 2>/dev/null || true
    rm -f "$MN"/modules.order "$MN"/Module.symvers 2>/dev/null || true
    if make -C "$KDIR" M="$MN" KCFLAGS="$GUARD_CFLAGS" modules -j"$NPROC"; then
        if [ -f "$MN/mali_nsfix.ko" ]; then
            cp "$MN/mali_nsfix.ko" "$OUT/mali_nsfix-$KMI.ko" && log "  [OK]"
        else
            warn "$(printf "$B_MALI_NOPROD" "$KMI")"
        fi
    else
        warn "$(printf "$B_MALI_FAIL" "$KMI")"
    fi
    find "$MN" -name '*.o' -delete 2>/dev/null || true
    find "$MN" -name '.*.cmd' -delete 2>/dev/null || true
    find "$MN" -name '*.ko' -delete 2>/dev/null || true
    rm -f "$MN"/modules.order "$MN"/Module.symvers 2>/dev/null || true
else
    warn "$(printf "$B_MALI_NOSRC" "$KMI")"
fi



# ---------------------------------------------------------------------------
# 产物符号自检
#
# 装了才知道缺符号是最贵的失败方式：用户装完只看到一句
# "unknown symbol in module"，我们这边什么信号都没有。这里把已知在部分
# 内核上不存在的符号直接查出来，在 CI 就报。
#
# 已知清单（按来源分组）：
#
# A. 内核配置差异（不是裁剪）
#   __stack_chk_guard      5.10 GKI 是 PER_TASK 模式，全局符号不存在
#                          -> 构建期用 -fno-stack-protector 规避
#   cgroup_rm_cftypes      5.10 里存在但没 EXPORT_SYMBOL_GPL（6.1 才加）
#                          -> cpu_mod/pids_mod 走 cpu_ksym() 运行时解析
#   drm_crtc_add_crc_entry 属 drm.ko 的模块依赖，加载时序不对就缺
#                          -> patch_vkms_debugfs.py 去掉调用
#   drmm_crtc_init_with_planes
#                          6.12 厂商内核（小米系）只裁了较新的 drmm_ 版
#                          -> 换成签名完全相同的 drm_crtc_init_with_planes
#                          （两者都 variadic，上游都 EXPORT_SYMBOL）
#                          实测：K90PM / 一加15 / 6.12.23-android16-5
#
# B. CONFIG_TRIM_UNUSED_KSYMS 一类（厂商只保留树内模块用到的导出）
#   以下全部已通过 VNS_OVL_VFS_COMPAT_LIST + shadow_hook_resolve 运行时解析，
#   或同名转发函数（/glue/vendor_kernel_ovl_vfs_compat.c）处理：
#
#   file_remove_privs / seq_escape_mem / kill_pid
#       来自 vendored overlayfs 与 diag 路径。实测 Meizu 21 Pro /
#       Flyme 12.7 / 6.1.25-android14-11（issue #2）。
#   path_put / kern_path
#       droid_lkm_cpu 的路径解析用。
#   ip_check_defrag / __netif_rx / ndo_dflt_fdb_dump
#       macvlan 从内核树源码编出来时引用的 IPv4/netdev 符号。
#       注意 __netif_rx 在 5.18 之后已从主线移除 —— 出现它说明
#       编译用的内核树比目标内核老，这类符号永远不可能在目标上解析到。
#   get_next_ino
#       mqueue / diagfs 用。6.12 厂商内核裁掉（issue #3 / #4）。
#       -> 三层清单都列 + 同名转发函数
#   cgroup_add_dfl_cftypes
#       droid_lkm_cpu / droid_lkm_pids 用。原来直接调用，6.12 上未导出
#       （issue #3 / #4）-> 改走 cpu_ksym() / kallrecon_klp()
#   __dev_forward_skb / dev_forward_skb / dev_mc_add_excl / dev_uc_add_excl
#   eth_header_cache / eth_header_cache_update
#       macvlan 用。6.12 上连 dev_forward_skb 都没导出，所以不能靠「换名字」
#       -> 同名转发函数 + 运行时解析（MACVLAN_SYMRES shim）
#   backing_file_user_path
#       6.12 实机报缺（issue #3 / #4），但源码里唯一调用点在
#       #if >= 6.18 分支内 —— 矛盾未查清，暂按「可能被裁」列入
#
# C. 任何 _trace_android_vh_*  vendor hook，不是所有厂商内核都开
#
# 这份清单的作用：任何一次改动如果让某个 .ko 重新带上这些符号，CI 立刻
# 报出来，而不是等用户装完只看到一句 "unknown symbol in module"。
# ---------------------------------------------------------------------------
echo
echo "$(printf "$B_SYMCHECK_HEAD" "$KMI")"
BAD_SYMS="__stack_chk_guard cgroup_rm_cftypes cgroup_add_dfl_cftypes \
drm_crtc_add_crc_entry drmm_crtc_init_with_planes \
file_remove_privs seq_escape_mem kill_pid path_put kern_path get_next_ino \
ip_check_defrag __netif_rx ndo_dflt_fdb_dump \
__dev_forward_skb dev_forward_skb dev_mc_add_excl dev_uc_add_excl \
eth_header_cache eth_header_cache_update \
backing_file_user_path \
d_instantiate d_obtain_alias d_splice_alias ihold clear_inode clear_nlink \
drop_nlink inc_nlink set_nlink inode_init_once inode_init_owner \
inode_set_flags init_special_inode unlock_new_inode iget5_locked ilookup5 \
insert_inode_hash __insert_inode_hash finish_open notify_change \
setattr_prepare sync_filesystem touch_atime truncate_inode_pages_final \
vfs_fsync generic_permission generic_file_splice_read kmem_cache_alloc_lru \
capable_wrt_inode_uidgid in_group_p current_umask \
__percpu_counter_init percpu_counter_destroy"
bad=0
for ko in "$OUT"/*-"$KMI".ko; do
    [ -f "$ko" ] || continue
    undef=$(nm -u "$ko" 2>/dev/null | awk '{print $2}')
    for sym in $BAD_SYMS; do
        if echo "$undef" | grep -qx "$sym"; then
            echo "  [SYM] $(printf "$B_SYM_BAD" "$(basename "$ko")" "$sym")"
            bad=$((bad + 1))
        fi
    done
    vh=$(echo "$undef" | grep -E '^_trace_android_vh_' | head -3)
    [ -n "$vh" ] && { echo "  [SYM] $(basename "$ko") 依赖 vendor hook:"; echo "$vh" | sed 's/^/         /'; bad=$((bad + 1)); }
done
if [ "$bad" -eq 0 ]; then
    echo "  [OK] $B_SYM_OK"
else
    echo "  [WARN] $(printf "$B_SYM_WARN" "$bad")"
fi

# ---------------------------------------------------------------------------
# 回归检查：这些符号已经改成运行时解析/同名转发，**不允许再出现在 nm -u 里**。
#
# BAD_SYMS 上面那条是软告警（历史包袱里有几个还没修完，见清单 C 组）；
# 这一条是硬的：一旦某个已修好的符号重新变成静态导入，说明有人改回去或者
# 补丁顺序被打乱，必须当场失败，不能等用户装完报 "unknown symbol"。
#
# 维护：每修好一个符号，就把它加到 MUST_NOT_APPEAR。
# ---------------------------------------------------------------------------
MUST_NOT_APPEAR="get_next_ino cgroup_add_dfl_cftypes \
dev_forward_skb eth_header_cache eth_header_cache_update \
drmm_crtc_init_with_planes \
file_remove_privs seq_escape_mem kill_pid \
__dev_forward_skb dev_mc_add_excl dev_uc_add_excl \
ip_check_defrag __netif_rx ndo_dflt_fdb_dump"

regress=0
for ko in "$OUT"/*-"$KMI".ko; do
    [ -f "$ko" ] || continue
    undef=$(nm -u "$ko" 2>/dev/null | awk '{print $2}')
    for sym in $MUST_NOT_APPEAR; do
        if echo "$undef" | grep -qx "$sym"; then
            echo "  [REGRESS] $(basename "$ko") 重新静态导入了 $sym"
            echo "            这个符号已改成运行时解析/同名转发，不该再出现在 nm -u 里"
            regress=$((regress + 1))
        fi
    done
done

if [ "$regress" -gt 0 ]; then
    # 符号回退是代码缺陷，不是「这台设备不支持」，所以直接让这一格红。
    # （模块编译失败才是宽松处理 —— 见上面 FAILED 的注释。）
    echo
    echo "  [FATAL] $KMI: $regress 个已修好的符号重新变成静态导入"
    echo "          改回去会重现 issue #2/#3/#4 的装机失败，拒绝出货"
    exit 1
fi

echo
echo "$(printf "$B_PROD_HEAD" "$KMI")"
ls -lh "$OUT" 2>/dev/null
echo
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "$(printf "$B_FAIL_HEAD" "${#FAILED[@]}")"
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
      echo "  $(printf "$B_MISSING" "$KMI" "$missing")"
      echo "         $B_INCOMPLETE"
      exit 1
  fi
  echo "  [OK] $B_ALL_PRESENT"

  # ---------------------------------------------------------------------
  # 内核导出依赖清单
  #
  # 装机失败最常见的原因是「这个内核没导出某个符号」，而 insmod 只回一句
  # "unknown symbol in module"，具体是哪个符号只在 dmesg 里，很多设备上
  # dmesg 还读不到（issue 里两台设备，一台能抓一台抓不到）。
  #
  # 所以在构建期把每个 .ko 的**未定义符号**固化成一个清单打进模块包，
  # 装机时拿清单逐条查 /proc/kallsyms 的 __ksymtab_，直接报出缺哪几个。
  # 不依赖 dmesg，也不依赖设备上有 nm。
  # ---------------------------------------------------------------------
  SYMFILE="$OUT/symcheck-$KMI.txt"
  : > "$SYMFILE"
  # DDK 容器里是 clang 工具链，不一定有 binutils 的 nm；llvm-nm 通常有
  NM=""
  for c in nm llvm-nm "$CROSS_COMPILE"nm; do
      if command -v "$c" >/dev/null 2>&1; then NM="$c"; break; fi
  done
  if [ -z "$NM" ]; then
      echo "  [WARN] $B_NO_NM"
  else
      echo "  [OK] $(printf "$B_NM_TOOL" "$NM")"
  fi
  for ko in "$OUT"/*-"$KMI".ko; do
      [ -f "$ko" ] || continue
      mod=$(basename "$ko" "-$KMI.ko")
      [ -n "$NM" ] || continue
      "$NM" -u "$ko" 2>/dev/null | awk '{print $2}' | \
          grep -vE '^(__this_module|_GLOBAL_OFFSET_TABLE_)$' | \
          while read -r s; do echo "$mod $s"; done >> "$SYMFILE"
  done
  n_syms=$(wc -l < "$SYMFILE" 2>/dev/null || echo 0)
  echo "  [OK] $(printf "$B_MANIFEST" "$(basename "$SYMFILE")" "$n_syms")"

exit 0
