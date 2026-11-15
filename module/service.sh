#!/system/bin/sh
# service.sh - late_start 阶段加载模块
#
# 按 KernelSU 文档，service.sh 在 late_start service 阶段执行，非阻塞，
# 是"跑开机脚本"的推荐阶段。本模块只往内核里 insmod，不碰系统分区，
# 因此不需要 post-fs-data.sh（那个阶段是阻塞的，能不用就不用）。
#
# 目录约定（打包时生成）：
#   ko/<模块名>-<kmi>.ko
#
# MODDIR 用规范写法取，不硬编码 /data/adb/modules/droidspaces_lkm。

# ---- 以下为各模块的加载顺序与原因 ----
# 加载顺序有讲究:
#   1) lkm4ctr       - PID/UTS/IPC namespace, Droidspaces 的硬性前提
#   2) devtmpfs_lkm  - 注册 devtmpfs (Droidspaces 靠 /proc/filesystems 判断)
#   3) ip6table_nat  - IPv6 NAT
#   4) macvlan       - 容器独立局域网 IP
#   5) vkms          - 虚拟 DRM 设备, 提供 /dev/dri/renderD128
#
# vkms 是 anland / wayland 桌面的前提:
#   Hyprland 和 KWin 的 Wayland 后端要一个能 gbm_create_device() 的
#   DRM render node。厂商内核没开 CONFIG_DRM_VGEM / CONFIG_DRM_VKMS,
#   只有 card0 (display controller), 没有 render 节点。
#
#   为什么是 vkms 而不是 vgem: Mesa 的 GBM 后端按 DRM driver 名字找 dri
#   驱动, 有 vkms_dri.so 却**没有** vgem_dri.so。用 vgem 时 Hyprland 停在
#     openRenderNode got drm device /dev/dri/renderD128
#     CRIT: Couldn't open a gbm device   (OpenGL.cpp:351)
#   vkms 是内核自带的虚拟 KMS 驱动 (card + render + CRTC + plane), 配
#   kms_swrast_dri.so 就能软件渲染出帧。
#
#   本仓库对 vkms 打了一个补丁: 上游 driver_features 只有
#   MODESET|ATOMIC|GEM, 不建 render node; 加上 DRIVER_RENDER 后才会生成
#   /dev/dri/renderD128。补丁见 scripts/patch_vkms_debugfs.py（同一处改的是
#   上游 drm_crtc_add_crc_entry 依赖 DEBUG_FS 的问题）。
#
#   必须在容器启动前加载, 否则 Droidspaces 扫描 /dev 时看不到它。
#
# devtmpfs_lkm 必须带 devtmpfs_probe=2:
#   默认 probe=0 会启动 kthread 并安装 device_add/device_del inline hook,
#   那套代码会改写内核只读段。实测在开机阶段用默认参数加载会导致卡开机。
#   probe=2 只注册文件系统, 不碰 hook —— 这正是 Droidspaces 需要的全部,
#   因为它只检查 /proc/filesystems 里有没有 devtmpfs。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
# ---------------------------------------------------------------------------
# 日志：三处同时落
#
# 为什么不能只写 /data/local/tmp：
#   KernelSU 的 bugreport 只抓 /data/adb 的**文件名列表**（ls -l），
#   /data/local/tmp 根本不抓；dmesg 才是按内容导出进 bootlog.tar.gz 的。
#   所以日志必须同时进 kernel log，否则用户报上来的报告里一行都看不到。
#
#   /data/adb/droidspaces_lkm.log   持久化，跨重启保留，可 adb pull
#   /dev/kmsg                      进 dmesg，被 bugreport 按内容抓走
#
# 不截断而是轮转：卡开机重启后，上一次的证据必须还在。
# ---------------------------------------------------------------------------
STATE_DIR=/data/adb/droidspaces_lkm.d
LOG=/data/adb/droidspaces_lkm.log
SNAP=$STATE_DIR/snapshot.txt
PREV=$STATE_DIR/prev-boot.txt
HANG=$STATE_DIR/hang-report.txt
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 755 "$STATE_DIR" 2>/dev/null

# 超过 256KB 就轮转一份，避免长期占空间
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 262144 ]; then
    mv -f "$LOG" "$LOG.old" 2>/dev/null
fi

dlog() {
    _line="[$(date '+%m-%d %H:%M:%S')] $*"
    printf '%s
' "$_line" >> "$LOG" 2>/dev/null
    # 进 kernel log，bugreport 就是从这里按内容导出的
    printf '<6>droidspaces_lkm: %s
' "$*" > /dev/kmsg 2>/dev/null
    # 必须返回 0：dlog 被用在 `test && dlog ... || dlog ...` 里，
    # /dev/kmsg 不可写时返回非 0 会把成功误报成失败
    return 0
}

dlog "=== Droidspaces LKM 启动 ==="
dlog "kernel: $(uname -r)"
dlog "moddir: $MODDIR"

# 从内核版本推导 KMI 标签, 例如 android14-6.1
# 6.1.157-android14-11-o-g... -> android14-6.1
KREL=$(uname -r)
KMI=""
for tag in android12-5.10 android13-5.10 android13-5.15 android14-5.15            android14-6.1 android15-6.6 android16-6.12 android17-6.18; do
    case "$KREL" in
        *"${tag%-*}"*"-${tag#*-}"*|*"-$tag"*) KMI="$tag"; break ;;
    esac
done

# 识别失败时不要放弃，也不要把系统属性当第一依据。
#
# 内核主版本才是硬约束：6.1 只可能是 android14，6.6 只可能是 android15。
# 有些 ROM 会伪造 ro.build.version.release（本机实测报 17、sdk 37，而内核是
# 6.1），拿属性当主依据会推出 android17-6.1 这种根本不存在的组合。
#
# 所以先用内核版本定候选，只有 5.10（12 或 13）、5.15（13 或 14）这种真的
# 有两代共用的才用属性消歧。
if [ -z "$KMI" ]; then
    major=$(echo "$KREL" | grep -oE '^[0-9]+[.][0-9]+' | head -1)
    android=$(echo "$KREL" | grep -oE 'android[0-9]+' | head -1)

    if [ -z "$android" ]; then
        case "$major" in
            5.10) android="android12 android13" ;;
            5.15) android="android13 android14" ;;
            6.1)  android="android14" ;;
            6.6)  android="android15" ;;
            6.12) android="android16" ;;
            6.18) android="android17" ;;
            *)    android="" ;;
        esac

        # 有多个候选时才看系统属性；取不到就保持第一个（较老的那一代）
        if [ "$(echo $android | wc -w)" -gt 1 ]; then
              # 判代际要用**出厂** API level，不能用 ro.build.version.release。
              #
              # release 会跟着 OTA 升级走，而 KMI 固定在设备出厂那一代。
              # 典型故障：一台 android13-5.15 的设备升到 Android 16 之后，
              # release=16，映射出来的 android16 在候选集 {android13,android14}
              # 里根本不存在，于是一路匹配失败。
              #（这条是 Dere3046/_patchHarmony 提交 f7c757e 指出的，我们原来
              #  用的正是 release/sdk。）
              #
              # ro.board.first_api_level 是出厂 API level，OTA 不会改它。
              api=$(getprop ro.board.first_api_level 2>/dev/null | grep -oE "^[0-9]+")
              [ -z "$api" ] && api=$(getprop ro.product.first_api_level 2>/dev/null | grep -oE "^[0-9]+")
              case "$api" in
                  31|32) pick=android12 ;;
                  33)    pick=android13 ;;
                  34)    pick=android14 ;;
                  35)    pick=android15 ;;
                  36)    pick=android16 ;;
                  37)    pick=android17 ;;
                  # 厂商有时把 first_api_level 写成 YYYYMM，按 2009 偏移折算
                  [0-9][0-9][0-9][0-9][0-9][0-9])
                      pick="android$(( ${api:0:4} - 2009 ))" ;;
                  *)     pick="" ;;
              esac
              # 拿不到出厂 level 时才退回 release/sdk —— 它们会漂，但比没有强
              if [ -z "$pick" ]; then
                  rel=$(getprop ro.build.version.release 2>/dev/null | grep -oE "^[0-9]+")
                  [ -z "$rel" ] && rel=$(getprop ro.build.version.sdk 2>/dev/null)
                  case "$rel" in
                      31|32|12) pick=android12 ;;
                      33|13)    pick=android13 ;;
                      34|14)    pick=android14 ;;
                      35|15)    pick=android15 ;;
                      36|16)    pick=android16 ;;
                      37|17)    pick=android17 ;;
                      *)        pick="" ;;
                  esac
              fi
              # 只接受候选集里有的那一代
              for c in $android; do
                  [ "$c" = "$pick" ] && { android="$pick"; break; }
              done
        fi
        android=$(echo "$android" | cut -d" " -f1)
    fi
    [ -n "$android" ] && [ -n "$major" ] && KMI="$android-$major"
fi
dlog "kmi:     ${KMI:-未识别}"

# 选 ko: 优先精确 KMI, 否则退回目录里唯一的一组
# 读 .ko 的 vermagic，和 uname -r 比"主版本.次版本"。只在无法确定 KMI
# 时用，作为最后一道防线 —— 版本对不上的模块 insmod 必然失败。
ko_vermagic_ok() {
    local ko="$1"
    local vm kmaj
    # grep -ao 在所有 Android 上都有；strings 不一定。
    vm=$(grep -ao 'vermagic=[^ ]*' "$ko" 2>/dev/null | head -1 | sed 's/^vermagic=//')
    [ -z "$vm" ] && return 1
    kmaj=$(echo "$(uname -r)" | grep -oE '^[0-9]+[.][0-9]+')
    case "$vm" in
        *" $kmaj "*|"$kmaj "*|*" $kmaj."*|"$kmaj."*) return 0 ;;
    esac
    return 1
}


# 5.10 / 5.15 各有两代共用同一个内核版本号：
#   5.10 → android12-5.10 与 android13-5.10
#   5.15 → android13-5.15 与 android14-5.15
# 内核串里没有 androidNN 字样时（例如 5.10.269-gki-g...），我们只能猜。
# 猜错了不会炸机——insmod 会因 vermagic 不符失败——但用户看到的是"模块装不上"。
# 所以这里用 ko 自带的 vermagic 去认，而不是靠猜：两代都试，谁对得上用谁。
find_sibling_ko() {
    local base="$1" cur="$2" sib n
    case "$cur" in
        android12-5.10) sib=android13-5.10 ;;
        android13-5.10) sib=android12-5.10 ;;
        android13-5.15) sib=android14-5.15 ;;
        android14-5.15) sib=android13-5.15 ;;
        *) return 1 ;;
    esac
    n="$MODDIR/ko/$base-$sib.ko"
    [ -f "$n" ] || return 1
    ko_vermagic_ok "$n" || return 1
    dlog "[KMI] $base: $cur 的 vermagic 不符，改用 $sib"
    echo "$n"
}

find_ko() {
    local base="$1"
    local f="$MODDIR/ko/$base-$KMI.ko"
    if [ -n "$KMI" ] && [ -f "$f" ]; then
        # 5.10/5.15 这种双代的组合，vermagic 说了算
        if ko_vermagic_ok "$f"; then
            echo "$f"; return 0
        fi
        if f2=$(find_sibling_ko "$base" "$KMI"); then
            echo "$f2"; return 0
        fi
        dlog "[MISS] $base: $KMI 的 vermagic 与 $(uname -r) 不符，且没有能对上的同代 ko"
        return 1
    fi
    # 不再"随便挑一个 KMI 的 ko"。之前 KMI 没识别出来时，ls | head -1 会
    # 挑到别的 KMI，insmod 必然 unknown symbol，用户看到"所有模块都装不上"，
    # 真正原因却被掩盖了（见 issues/1）。
    #
    # 仅当这个模块在目录里只有一份、且 vermagic 与本机内核一致时才用它。
    local all
    all=$(ls "$MODDIR/ko/$base"-*.ko 2>/dev/null)
    [ -z "$all" ] && return 1
    if [ "$(echo "$all" | wc -l)" -ne 1 ]; then
        dlog "[MISS] $base: KMI=${KMI:-未识别}，目录里有多份候选，拒绝猜"
        return 1
    fi
    if ! ko_vermagic_ok "$all"; then
        dlog "[MISS] $base: KMI=${KMI:-未识别}，$(basename "$all") 的 vermagic 与 $(uname -r) 不符"
        return 1
    fi
    echo "$all"
    return 0
}

# 参数是否真的被这个 .ko 支持。
#
# insmod 报 "unknown parameter" 的唯一成因就是传了模块没声明的参数。
# 设备上不一定有 modinfo，所以直接在 .ko 里找参数名——模块参数会以字符串
# 形式留在 __param / .modinfo 段里，能找到就说明支持。
ko_has_param() {
    local ko="$1" name="$2"
    grep -aq "$name" "$ko" 2>/dev/null
}

# 从内核日志里捞出 insmod 失败的具体原因。
#
# "unknown symbol in module" 只是个笼统结论，真正缺哪个符号在内核日志里：
#   lkm4ctr: Unknown symbol foo_bar (err -2)
# 把它抄进模块日志，用户报问题时一眼能看到缺什么，不用再去猜。
ko_load_error() {
    local mod="$1"
    dmesg 2>/dev/null | grep -E "Unknown symbol|unknown parameter|disagrees about version"         | tail -3 | while read -r _l; do dlog "  [kernel] $_l"; done
}

load_mod() {
    local base="$1" params="$2"
    local ko
    if ! ko=$(find_ko "$base"); then
        dlog "[MISS] $base (KMI=${KMI:-?})"
        return 1
    fi
    local name
    name=$(basename "$ko" .ko)

    # 先验 vermagic：KMI 选错时 insmod 只会报 "unknown symbol in module"，
    # 把"模块对不上内核"这条真因埋掉（issues/1 就是这么被误判的）。
    if ! ko_vermagic_ok "$ko"; then
        local vm
        vm=$(grep -ao 'vermagic=[^ ]*' "$ko" 2>/dev/null | head -1 | sed 's/^vermagic=//')
        dlog "[FAIL] $base: $(basename "$ko") 的 vermagic (${vm:-未知}) 与内核 $(uname -r) 不匹配，跳过"
        return 1
    fi

    # 只传这个 .ko 真支持的参数，否则内核会回 "unknown parameter"
    if [ -n "$params" ]; then
        local kept="" pname
        for p in $params; do
            pname=${p%%=*}
            if ko_has_param "$ko" "$pname"; then
                kept="$kept $p"
            else
                dlog "[WARN] $base 不支持参数 $pname，已忽略"
            fi
        done
        params=${kept# }
    fi

    # 判断是否已加载: 用模块名而不是文件名, 因为文件名带 KMI 后缀
    if grep -q "^${base} " /proc/modules 2>/dev/null; then
        dlog "[SKIP] $base 已加载"
        return 0
    fi

    # 黑名单：上一次开机死在加载这个模块上，就不再试。
    # 宁可少一个功能，也不要让设备再卡一次开机。
    if [ -f "$STATE_DIR/blacklist" ] && grep -qx "$base" "$STATE_DIR/blacklist" 2>/dev/null; then
        dlog "[SKIP] $base 在上次开机的黑名单里（加载它会卡死），跳过"
        return 1
    fi

    local out rc _sib _tryko
    # 5.10 / 5.15 各有两代共用同一个内核版本（android12-5.10 与 android13-5.10、
    # android13-5.15 与 android14-5.15）。内核串里没有 androidNN 时 KMI 只能猜，
    # 猜错时代的 vermagic 只到 5.10 这个粒度、分辨不出来，insmod 会因符号版本
    # 不符失败。这里换另一代的 ko 再试一次。
    #
    # 不能用 bash 的数组（cands=(...)）：Android 的 sh 是 mksh，不支持 `=()`，
    # 会直接 syntax error，而 bash -n 查不出来。用两次顺序尝试代替循环。
    case "$KMI" in
        android12-5.10) _sib=android13-5.10 ;;
        android13-5.10) _sib=android12-5.10 ;;
        android13-5.15) _sib=android14-5.15 ;;
        android14-5.15) _sib=android13-5.15 ;;
        *)              _sib="" ;;
    esac

    _try_load() {
        local k="$1" o
        printf '%s
' "${base}" > "$STATE_DIR/loading" 2>/dev/null
        sync
        if [ -n "$params" ]; then
            o=$(insmod "$k" $params 2>&1)
        else
            o=$(insmod "$k" 2>&1)
        fi
        out="$o"
        grep -q "^${base} " /proc/modules 2>/dev/null
    }

    if _try_load "$ko"; then
        rm -f "$STATE_DIR/loading" 2>/dev/null
        dlog "[OK]   $base  ($(basename "$ko"))${params:+ $params}"
        return 0
    fi

    if [ -n "$_sib" ] && [ -f "$MODDIR/ko/$base-$_sib.ko" ]; then
        _tryko="$MODDIR/ko/$base-$_sib.ko"
        dlog "[TRY] $base: $(basename "$ko") 失败，换 $_sib 再试"
        if _try_load "$_tryko"; then
            rm -f "$STATE_DIR/loading" 2>/dev/null
            dlog "[KMI] $base: ${KMI} 不符，实际用的是 $(basename "$_tryko")"
            dlog "[OK]   $base  ($(basename "$_tryko"))${params:+ $params}"
            return 0
        fi
    fi
    rm -f "$STATE_DIR/loading" 2>/dev/null
    # 把内核日志里的具体缺符号抄下来，避免用户只能看到一个笼统报错
    ko_load_error "$base"
    return 1
}

dlog "--- 加载 ---"
load_mod lkm4ctr ""
load_mod devtmpfs_lkm "devtmpfs_probe=2"
load_mod ip6table_nat ""
load_mod macvlan ""
# vkms 依赖 drm.ko 导出的 drm_crtc_add_crc_entry。5.10 里这个符号是导出的，
# 但它属于 drm.ko 的**模块依赖**：drm 还没加载时 insmod 只会报
# "Unknown symbol"，而这里跑在 late_start，drm 未必已经就绪。
# 所以失败后重试几次，而不是一次就放弃。
if ! load_mod vkms ""; then
    for _try in 1 2 3 4 5; do
        sleep 2
        if load_mod vkms ""; then
            break
        fi
        # find_ko 每轮都会重新判断，但已加载的模块会被 [SKIP]，
        # 这里只需处理"还没加载成功"的情况
    done
fi

# cgroup 限流仿真（--cpus / --pids-limit）。
# 装 kprobe 并在运行时解析符号，最坏表现是加载失败；
# 放最后，失败不挡前面五个模块。
# 想临时关掉：在模块目录放 disable_pids / disable_cpu。
MODDIR="/data/adb/modules/droidspaces_lkm"
[ -f "$MODDIR/disable_pids" ] || load_mod droid_lkm_pids ""
[ -f "$MODDIR/disable_cpu" ] || load_mod droid_lkm_cpu ""

# uart_guard：串口 sysfs 属性会去锁一个可能已损坏的 tty_port mutex，
# 容器里的 udev 扫一遍 /sys/class/tty 就能把宿主打 panic。
# 放最后，钩不上也不影响容器本身；想排查时看 dmesg 里的 uart_guard 行。
[ -f "$MODDIR/disable_uart_guard" ] || load_mod uart_guard ""

# 注意：这里**不清零**开机计数器。
# service.sh 只代表"模块加载流程跑完"，不代表系统能正常起来 —— 加载成功后
# 卡死的情况真实发生过。清零交给 boot-completed.sh，那是 Android 真正启动
# 完成的信号。

dlog "--- lsmod ---"
lsmod 2>/dev/null | grep -E '^(lkm4ctr|devtmpfs_lkm|ip6table_nat|macvlan|vkms|droid_lkm_pids|droid_lkm_cpu|uart_guard)' | while read -r _l; do dlog "  $_l"; done

dlog "--- 能力验证 ---"
unshare -pf true 2>/dev/null \
    && dlog "[OK] PID namespace" \
    || dlog "[FAIL] PID namespace"
unshare -i true 2>/dev/null \
    && dlog "[OK] IPC namespace" \
    || dlog "[FAIL] IPC namespace"
grep -q devtmpfs /proc/filesystems 2>/dev/null \
    && dlog "[OK] devtmpfs" \
    || dlog "[--] devtmpfs 未注册"
grep -q "^droid_lkm_pids " /proc/modules 2>/dev/null \
    && dlog "[OK] pids 控制器仿真" \
    || dlog "[--] pids 控制器仿真未加载"
grep -q "^droid_lkm_cpu " /proc/modules 2>/dev/null \
    && dlog "[OK] cpu.max 仿真" \
    || dlog "[--] cpu.max 仿真未加载"

# vkms 提供的 render node: anland / wayland 合成器的前提
if [ -e /dev/dri/renderD128 ]; then
    dlog "[OK] /dev/dri/renderD128 (vkms)"
else
    dlog "[--] /dev/dri/renderD128 缺失 (anland 桌面不可用)"
fi

# ---------------------------------------------------------------------------
# 后台快照守卫
#
# 卡开机是"没有 panic 的卡死"：pstore 里什么都不会有，重启后 dmesg 也被冲掉。
# 唯一能留下现场的办法是**在卡死之前**就把状态反复落盘。
#
# 这个后台循环跑 10 分钟（40 次 × 15 秒），每次把
#   uptime / 负载 / 我们模块的引用计数 / dmesg 尾部
# 写进 snapshot.txt 并 sync。真卡死时，最后一份 snapshot.txt 就是现场。
#
# sync 每次都要做：不 sync 的话数据可能还在 page cache 里，
# 卡死重启就丢了。
#
# 上一次启动的快照在 post-fs-data.sh 里已经被复制成 prev-boot.txt，
# 所以这里直接覆盖 snapshot.txt。
# ---------------------------------------------------------------------------
snapshot_once() {
    {
        printf '=== %s ===\n' "$(date '+%m-%d %H:%M:%S')"
        printf -- '-- uptime: %s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
        printf -- '-- load  : %s\n' "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
        printf -- '-- droidspaces 模块:\n'
        grep -E '^(lkm4ctr|devtmpfs_lkm|ip6table_nat|macvlan|vkms|droid_lkm_pids|droid_lkm_cpu|uart_guard) ' \
            /proc/modules 2>/dev/null \
            | awk '{printf "   %-14s ref=%-4s size=%s\n", $1, $3, $2}'
        printf -- '-- renderD128: %s\n' "$([ -e /dev/dri/renderD128 ] && echo 有 || echo 无)"
        printf -- '-- dmesg 尾部:\n'
        dmesg 2>/dev/null | tail -40

        #
        # 自家日志单独再放一份：dmesg 尾部很容易被充电/蓝牙/CCCI 刷屏挤满，
        # 真正要看的"service.sh 走到哪一步"反而被冲掉。快照自带这一段，
        # 事后只看 hang-report.txt 一个文件就够。
        printf -- '-- 模块日志尾部:\n'
        tail -30 "$LOG" 2>/dev/null
    } > "$SNAP.tmp" 2>/dev/null
    mv -f "$SNAP.tmp" "$SNAP" 2>/dev/null
    sync
}

snapshot_watchdog() {
    local i=0
    snapshot_once
    while [ "$i" -lt 40 ]; do
        sleep 15
        i=$((i + 1))
        snapshot_once
    done
}

# 立刻做一份"加载完成时"的快照（在后台跑，不挡退出）
( snapshot_watchdog ) >/dev/null 2>&1 &

dlog "=== 完成 ===（快照守卫已启动，10 分钟内每 15 秒落盘一次）"
exit 0
