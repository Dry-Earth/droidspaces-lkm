#!/system/bin/sh
# action.sh - KernelSU 模块页「操作」按钮
#
# 用途：给出"当前到底能用什么"的一屏结论。用户报 issue 时贴这一段就够定位
# 大部分问题（模块有没有加载、KMI 选得对不对、能力是否真的可用）。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
LOG=/data/local/tmp/droidspaces-lkm.log

echo "=== Droidspaces LKM ==="
echo "内核    : $(uname -r)"
echo "模块版本: $(grep -m1 '^version=' "$MODDIR/module.prop" 2>/dev/null | cut -d= -f2)"
echo "架构    : $(uname -m)"
echo

echo "=== 加载状态 ==="
if lsmod | grep -qE '^(lkm4ctr|devtmpfs_lkm)'; then
    lsmod | grep -E '^(lkm4ctr|devtmpfs_lkm|ip6table_nat|macvlan|vkms|droid_lkm_pids|droid_lkm_cpu)'
else
    echo "未加载"
fi
echo

echo "=== 能力验证 ==="
userns=$(unshare -U readlink /proc/self/ns/user 2>/dev/null)
hostns=$(readlink /proc/self/ns/user 2>/dev/null)
if [ -n "$userns" ] && [ "$userns" != "$hostns" ]; then
    echo "  [OK]   user namespace ($userns)"
else
    echo "  [FAIL] user namespace"
fi

if unshare -Urmpf true 2>/dev/null; then
    echo "  [OK]   PID + mount + user namespace 组合"
else
    echo "  [FAIL] PID + mount + user namespace 组合"
fi

if unshare -Urmpf sh -c 'mount -t proc proc /proc' 2>/dev/null; then
    echo "  [OK]   容器内挂载 /proc"
else
    echo "  [FAIL] 容器内挂载 /proc"
fi

grep -q '^devtmpfs' /proc/filesystems 2>/dev/null \
    && echo "  [OK]   devtmpfs" \
    || echo "  [--]   devtmpfs 未注册"

[ -e /dev/dri/renderD128 ] \
    && echo "  [OK]   /dev/dri/renderD128 (vkms)" \
    || echo "  [--]   /dev/dri/renderD128 不存在"
echo

echo "=== 日志（末尾 30 行）==="
tail -30 "$LOG" 2>/dev/null || echo "(无日志)"
