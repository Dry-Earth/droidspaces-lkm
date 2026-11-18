#!/system/bin/sh
# action.sh - KernelSU 模块页「操作」按钮
#
# 用途：给出"当前到底能用什么"的一屏结论。用户报 issue 时贴这一段就够定位
# 大部分问题（模块有没有加载、KMI 选得对不对、能力是否真的可用）。
#
# 国际化：文案来自 i18n.sh，按系统语言显示。
# 但 [OK] / [FAIL] / [--] / [缺] 这些标记、符号名、KMI 标签一律不翻译 ——
# 它们是机器可读的，翻译了日志就没法 grep 也没法跨语言比对了。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
LOG=/data/adb/droidspaces_lkm.log
STATE_DIR=/data/adb/droidspaces_lkm.d

# `action.sh doctor`：只输出诊断段（状态/加载/导出/能力），不打日志尾部。
# 借鉴 live-gpu-driver 的 doctor 子命令；KernelSU 的「操作」按钮不带参数
# 调用本脚本，默认路径与原来完全一致。
_DOCTOR=0
[ "${1:-}" = "doctor" ] && _DOCTOR=1

# shellcheck source=i18n.sh
[ -f "$MODDIR/i18n.sh" ] && . "$MODDIR/i18n.sh"

echo "=== Droidspaces LKM ==="
echo "${M_KERNEL}: $(uname -r)"
echo "${M_MODULE_VER}: $(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
echo "${M_ARCH}: $(uname -m)"
echo

echo "=== ${M_SEC_STATE} ==="
count=$(cat /data/adb/droidspaces_lkm.bootcount 2>/dev/null)
echo "${M_BOOTCOUNT}: ${count:-$M_NONE}${M_BOOTCOUNT_HINT}"
if [ -f "$MODDIR/disable" ]; then
    echo "${M_DISABLE}: ${M_DISABLE_YES}"
else
    echo "${M_DISABLE}: ${M_DISABLE_NO}"
fi
if [ -f "$STATE_DIR/hang-report.txt" ]; then
    echo "${M_HANG_REPORT}: ${M_HANGREPORT_HAS} ($(wc -c < "$STATE_DIR/hang-report.txt" 2>/dev/null || echo 0) bytes)"
    echo "          /data/adb/droidspaces_lkm.d/hang-report.txt"
else
    echo "${M_HANG_REPORT}: ${M_NONE}"
fi
snap_age=""
if [ -f "$STATE_DIR/snapshot.txt" ]; then
    snap_age=$(wc -c < "$STATE_DIR/snapshot.txt" 2>/dev/null)
fi
echo "${M_SNAPSHOT}: ${snap_age:-$M_NONE} bytes"
if [ -f "$STATE_DIR/crash-module.txt" ]; then
    echo "${M_LASTCRASH}: $(cat "$STATE_DIR/crash-module.txt" 2>/dev/null) ${M_LASTCRASH_HINT}"
fi
if [ -f "$STATE_DIR/blacklist" ]; then
    echo "${M_BLACKLIST}: $(tr '\n' ' ' < "$STATE_DIR/blacklist" 2>/dev/null)"
fi
echo

echo "=== ${M_SEC_LOAD} ==="
if lsmod | grep -qE '^(lkm4ctr|devtmpfs_lkm)'; then
    lsmod | grep -E '^(lkm4ctr|devtmpfs_lkm|ip6table_nat|macvlan|vkms|droid_lkm_pids|droid_lkm_cpu|uart_guard|mali_nsfix)'
else
    echo "${M_NOT_LOADED}"
fi
echo

echo "=== ${M_SEC_EXPORT} ==="
# 构建期把每个 .ko 的未定义符号导成 ko/symcheck-<kmi>.txt。
# 这里拿清单查 /proc/kallsyms 的 __ksymtab_ 条目 —— 直接报出「本内核缺哪些」，
# 不依赖能读 dmesg（有些厂商内核上读不到，用户只能看到笼统的 unknown symbol）。
_kmi=""
# 不能只抄 service.sh 第一段那个模式（*android14*-6.1*）：它要求内核串里
# 出现字面量 "-6.1"，而实际串是 6.1.157-android14-11-o-g...，只有 "6.1.157-"。
# service.sh 能得出正确 KMI 是靠后面的回退（androidNN + X.Y 拼），这里照做。
_krel=$(uname -r)
_kandroid=$(echo "$_krel" | grep -oE 'android[0-9]+' | head -1)
_kmajor=$(echo "$_krel" | grep -oE '^[0-9]+[.][0-9]+' | head -1)
if [ -n "$_kandroid" ] && [ -n "$_kmajor" ]; then
    _kmi="${_kandroid}-${_kmajor}"
fi
# 兜底：service.sh 开机时已经把推导结果写进日志，直接读它
if [ -z "$_kmi" ] && [ -f "$LOG" ]; then
    _kmi=$(grep -a 'kmi:' "$LOG" 2>/dev/null | tail -1 | sed 's/.*kmi:[[:space:]]*//' | tr -d ' \r')
    case "$_kmi" in android*) ;; *) _kmi="" ;; esac
fi
_sf="$MODDIR/ko/symcheck-${_kmi}.txt"
if [ -z "$_kmi" ]; then
    echo "  [--]   ${M_EXPORT_NONE}"
elif [ ! -f "$_sf" ]; then
    echo "  [--]   $(msg "$M_EXPORT_NOFILE" "$_kmi")"
else
    # /proc/kallsyms 只读一次。
    #
    # 之前是每查一个符号就 grep 一遍整个文件：641 条依赖 × 二十多万行
    # （CONFIG_KALLSYMS_ALL=y 的设备），在 KSU 的「操作」按钮里就是看起来
    # 卡死 —— 用户等不到输出就退出了。
    #
    # 现在先抽出一份导出符号名单（__ksymtab_ 后面的名字），再用 awk 单趟比对。
    # 两个文件的读取次数都是 1。
    _have=$(mktemp)
    grep -a '__ksymtab_' /proc/kallsyms 2>/dev/null \
        | sed 's/.*__ksymtab_//' | sort -u > "$_have"

    _miss=$(awk '
        FNR == NR { have[$1] = 1; next }
        NF >= 2 && !($2 in have) { n++ }
        END { print n + 0 }
    ' "$_have" "$_sf" 2>/dev/null)
    _miss=${_miss:-0}

    if [ "$_miss" -eq 0 ]; then
        echo "  [OK]   ${M_EXPORT_ALL_OK}"
    else
        # 标记 [缺] 不翻译；后面的描述由 i18n 给
        awk -v fmt="$M_EXPORT_MISS_ONE" '
            FNR == NR { have[$1] = 1; next }
            NF >= 2 && !($2 in have) { printf "  [SYM]  "; printf fmt "\n", $1, $2 }
        ' "$_have" "$_sf" 2>/dev/null
        echo "         $(msg "$M_EXPORT_MISS_HEAD" "$_miss")"
        echo "         ${M_EXPORT_MISS_TAIL}"
    fi
    rm -f "$_have"
fi
echo

echo "=== ${M_SEC_CAPS} ==="
userns=$(unshare -U readlink /proc/self/ns/user 2>/dev/null)
hostns=$(readlink /proc/self/ns/user 2>/dev/null)
if [ -n "$userns" ] && [ "$userns" != "$hostns" ]; then
    echo "  [OK]   ${M_CAP_USERNS} ($userns)"
else
    echo "  [FAIL] ${M_CAP_USERNS}"
fi

# PID + mount 命名空间组合。不带 -U：容器用的是宿主的 user namespace，
# 加 -U 会进入一个新 userns，那里的 root 挂不了 proc（内核的 userns 挂载限制），
# 报出来的 FAIL 与模块能力无关。service.sh 用的也是不带 -U 的写法。
if unshare -pmf true 2>/dev/null; then
    echo "  [OK]   ${M_CAP_PIDMNT}"
else
    echo "  [FAIL] ${M_CAP_PIDMNT}"
fi

# 容器内挂载 /proc。挂到临时目录而不是覆盖 /proc：
# 覆盖一个已存在的挂载点在 userns 下会 EPERM，且真挂上去会污染当前会话。
#
# 路径放 /mnt 而不是 /data/local/tmp：本脚本以 root 跑，而 /data/local/tmp 全局
# 可写，普通用户可以先把它做成指向敏感目录的符号链接，root 的 mount 会跟着链
# 挂到攻击者选定的目标上。/mnt 只有 root 能写（下面 devtmpfs 探针也用它），
# 攻击面消失。再加一道 -L 检查兜底，万一被换成链接就直接放弃。
_procmnt=/mnt/.dsp_proctest
if [ -L "$_procmnt" ]; then
    # 是指向别处的符号链接（-L 不跟随）：绝不跟着挂，判 FAIL。
    # 注意不能只用 [ ! -d ]：-d 会跟随符号链接，symlink 指向目录时会当成正常目录放过。
    echo "  [FAIL] ${M_CAP_PROC}"
else
    mkdir -p "$_procmnt" 2>/dev/null
    if unshare -pf mount -t proc proc "$_procmnt" 2>/dev/null; then
        echo "  [OK]   ${M_CAP_PROC}"
        umount "$_procmnt" 2>/dev/null
        rmdir "$_procmnt" 2>/dev/null
    else
        echo "  [FAIL] ${M_CAP_PROC}"
    fi
fi

# /proc/filesystems 的格式是 "nodev<TAB>devtmpfs"：第一列是 nodev，
# 文件系统名在第二列。用 ^devtmpfs 永远匹配不到 —— 这个错误让「操作」按钮
# 一直报「devtmpfs 未注册」，而 droidspaces check 显示 [✓] devtmpfs support。
if awk '{print $NF}' /proc/filesystems 2>/dev/null | grep -qx devtmpfs; then
    # probe=2 只注册文件系统、不装 device_add 钩子，所以挂上去是空的。
    # 对 Droidspaces 而言注册本身就够了，这里如实标注节点数。
    n=0
    mkdir -p /mnt/.dsp_devtest 2>/dev/null
    if mount -t devtmpfs devtmpfs /mnt/.dsp_devtest 2>/dev/null; then
        n=$(ls /mnt/.dsp_devtest 2>/dev/null | wc -l)
        umount /mnt/.dsp_devtest 2>/dev/null
    fi
    rmdir /mnt/.dsp_devtest 2>/dev/null
    echo "  [OK]   $(msg "$M_CAP_DEVTMPFS" "$n")"
else
    echo "  [--]   ${M_CAP_DEVTMPFS_NO}"
fi

# 显示链路的两个不同要素，别混：
#   /dev/mali0        —— Droidspaces --hw-access 映射的设备节点；mali_nsfix
#                        只负责让容器内进程能用它建 GPU context。
#   /dev/dri/renderD128 —— DRM render node，标准 Wayland 合成器（5.x / 自带
#                        合成器的桌面）才要，由 vkms 提供；6.x waylandbridge
#                        直接用 /dev/mali0，不需要它。
if [ -e /dev/mali0 ]; then
    echo "  [OK]   ${M_DISP_MALI0}"
else
    echo "  [--]   ${M_DISP_MALI0_NO}"
fi
if lsmod | grep -q '^mali_kbase'; then
    echo "  [OK]   ${M_DISP_KBASE}"
else
    echo "  [--]   ${M_DISP_KBASE_NO}"
fi

# vkms 默认不加载。缺不缺取决于走哪条桌面路线（6.x waylandbridge 不需要，
# 5.x / 自带合成器的桌面需要），所以缺失本身不算失败。
# 只有用户显式开了 enable_vkms 却没拿到节点时才标 FAIL。
if [ -e /dev/dri/renderD128 ]; then
    echo "  [OK]   ${M_CAP_VKMS}"
elif [ -f "/data/adb/modules/droidspaces_lkm/enable_vkms" ]; then
    echo "  [FAIL] ${M_CAP_VKMS_NO} (enable_vkms is set)"
else
    echo "  [--]   ${M_CAP_VKMS_NO} (${M_VKMS_HINT})"
fi

# Mali：有 /dev/mali0 说明是 Mali 平台，这时 mali_nsfix 是否加载决定容器内能否
# 创建 GPU context。没有 /dev/mali0 的设备直接标 [--]，不制造无关的 FAIL。
#
# 除了 [OK]/[FAIL]，把模块自己的状态参数摊开报：armed / 探针可用性 / 布局校验 /
# 绑定的驱动 / 拦截计数。用户贴一段就能定位「没生效」到底是哪一环。
if [ -e /dev/mali0 ] || lsmod | grep -q '^mali_kbase'; then
    if ! lsmod | grep -q '^mali_nsfix'; then
        echo "  [FAIL] ${M_MALI_NOT_LOADED}"
    else
        _p=/sys/module/mali_nsfix/parameters
        _act=$(cat "$_p/nshf_active" 2>/dev/null)
        _probe=$(cat "$_p/nshf_probe_ok" 2>/dev/null)
        _lay=$(cat "$_p/nshf_layout_valid" 2>/dev/null)
        _drv=$(cat "$_p/nshf_driver" 2>/dev/null)
        _seen=$(cat "$_p/nshf_seen" 2>/dev/null)
        _hits=$(cat "$_p/nshf_hits" 2>/dev/null)
        case "$_act" in
            1) echo "  [OK]   ${M_MALI_ACTIVE} (${M_MALI_DRIVER}=${_drv:-?})" ;;
            *) echo "  [FAIL] ${M_MALI_DRY}" ;;
        esac
        case "$_probe" in
            1) echo "  [OK]   ${M_MALI_PROBE_OK}" ;;
            *) echo "  [FAIL] ${M_MALI_PROBE_NO}" ;;
        esac
        case "$_lay" in
            1) : ;;
            *) echo "  [FAIL] ${M_MALI_LAYOUT_BAD}" ;;
        esac
        printf "         %s\n" "$(printf "$M_MALI_COUNT" "${_seen:-?}" "${_hits:-?}")"
        # 机器可读一行：脚本和 Issue 模板可以直接 grep，不受语言影响
        echo "  nshf_status active=${_act:-?} probe_ok=${_probe:-?} layout=${_lay:-?} driver=${_drv:-?} seen=${_seen:-?} hits=${_hits:-?}"
    fi
else
    echo "  [--]   ${M_MALI_NA}"
fi

# doctor 到这里就够了；默认路径继续往下打日志尾部。
[ "$_DOCTOR" = "1" ] && exit 0
echo

echo "=== ${M_SEC_LOG} ==="
tail -30 "$LOG" 2>/dev/null || echo "(no log)"