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
    lsmod | grep -E '^(lkm4ctr|devtmpfs_lkm|ip6table_nat|macvlan|vkms|droid_lkm_pids|droid_lkm_cpu|uart_guard)'
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

if unshare -Urmpf true 2>/dev/null; then
    echo "  [OK]   ${M_CAP_PIDMNT}"
else
    echo "  [FAIL] ${M_CAP_PIDMNT}"
fi

if unshare -Urmpf sh -c 'mount -t proc proc /proc' 2>/dev/null; then
    echo "  [OK]   ${M_CAP_PROC}"
else
    echo "  [FAIL] ${M_CAP_PROC}"
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

[ -e /dev/dri/renderD128 ] \
    && echo "  [OK]   ${M_CAP_VKMS}" \
    || echo "  [--]   ${M_CAP_VKMS_NO}"
echo

echo "=== ${M_SEC_LOG} ==="
tail -30 "$LOG" 2>/dev/null || echo "(no log)"