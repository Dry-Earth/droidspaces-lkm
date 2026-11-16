#!/system/bin/sh
# post-fs-data.sh - 开机循环保护
#
# 这个模块会往内核里 insmod 并改写函数入口。万一某个版本在特定内核上 panic，
# 后果是重启 -> 再次 panic -> 无限循环，用户只能靠物理按键进安全模式。
#
# 所以这里放一个计数器：
#   每次开机 +1；service.sh 成功加载后清零。
#   连续 3 次没走到"成功"就自动创建 disable，让设备能正常开机。
#
# 只做计数和写文件，不加载任何东西，耗时是微秒级 —— 放在阻塞的 post-fs-data
# 阶段可以接受。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
COUNT=/data/adb/droidspaces_lkm.bootcount
LIMIT=3

# 与 service.sh 共用的状态目录
STATE_DIR=/data/adb/droidspaces_lkm.d
LOG=/data/adb/droidspaces_lkm.log
SNAP=$STATE_DIR/snapshot.txt
PREV=$STATE_DIR/prev-boot.txt
HANG=$STATE_DIR/hang-report.txt
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 755 "$STATE_DIR" 2>/dev/null

# 日志同时进 kernel log。KernelSU 的 bugreport 只按内容导出 dmesg，
# /data/local/tmp 根本不抓 —— 只写文件等于没写。
plog() {
    _line="[$(date '+%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$_line" >> "$LOG" 2>/dev/null
    printf '<6>droidspaces_lkm: %s\n' "$*" > /dev/kmsg 2>/dev/null
    return 0
}

# 上一次启动留下的快照就是"卡死现场"。这次启动一开头先把它固定住，
# 否则 service.sh 的快照守卫会把 snapshot.txt 覆盖成本次启动的样子，
# 卡死那次的最后状态就永远丢了。
if [ -f "$SNAP" ]; then
    cp -f "$SNAP" "$PREV" 2>/dev/null
fi

# ---------------------------------------------------------------------------
# pstore 现场：上次启动如果是**内核崩溃**（不是卡死），console-ramoops 会有内容
#
# 和下面面包屑的分工：
#   面包屑  -> 卡死（没有 panic），模块名还留在 loading 里
#   pstore -> 真 panic（BUG/Oops/panic_on_oops），内核自己落盘的现场
#
# 为什么要自动抓：issue #1（5.10.269-gki）报无限重启，请用户手动
#   cat /sys/fs/pstore/console-ramoops
# 但一直没等到 —— 多数用户要么 panic 后马上重启把 ramoops 冲掉，要么根本
# 进不去系统。这里自动做掉：这次启动能读到，就说明上次是崩溃退出的，
# 复制到状态目录并 sync，之后哪次抓日志都能看到现场。
#
# 不主动清空 pstore：那是系统的资源，ramoops 由内核/用户态自己轮转。
# ---------------------------------------------------------------------------
_ps=/sys/fs/pstore
if [ -d "$_ps" ]; then
    _n=0
    for _f in "$_ps"/console-ramoops* "$_ps"/dmesg-ramoops*; do
        [ -f "$_f" ] && [ -s "$_f" ] && _n=$((_n + 1))
    done
    if [ "$_n" -gt 0 ]; then
        _out="$STATE_DIR/pstore-$(date '+%Y%m%d-%H%M%S').txt"
        {
            printf '=== pstore 现场 ===\n'
            printf '本机内核: %s\n' "$(uname -r)"
            printf '说明: 上一次启动是内核崩溃退出的（正常重启时 pstore 为空）\n\n'
            for _f in "$_ps"/console-ramoops* "$_ps"/dmesg-ramoops*; do
                [ -f "$_f" ] || continue
                [ -s "$_f" ] || continue
                printf -- '--- %s ---\n' "$(basename "$_f")"
                cat "$_f"
                printf '\n'
            done
        } > "$_out" 2>/dev/null
        sync
        plog "上次启动是内核崩溃退出，pstore 现场已保存：$_out"
        plog "  把这个文件贴到 issue 里，里面通常有 panic 前的完整 dmesg"
        # 只保留最近 3 份，避免状态目录无限增长
        ls -1t "$STATE_DIR"/pstore-*.txt 2>/dev/null | tail -n +4 | while read -r _old; do
            rm -f "$_old" 2>/dev/null
        done
    fi
fi

# ---------------------------------------------------------------------------
# 面包屑判定：上次开机是不是死在某个模块的 insmod 上
#
# service.sh 在每个 insmod 前把模块名写进 loading 并 sync，成功后删掉。
# 如果这次开机它还躺在那儿，就说明上一次开机是在加载那个模块的时候死的
# —— 不是"某个模块有问题"这种猜测，而是有名字的结论。
#
# 直接把它拉黑，而不是让用户反复重启去试：卡开机是最难受的故障形态。
# ---------------------------------------------------------------------------
if [ -f "$STATE_DIR/loading" ]; then
    _dead=$(head -1 "$STATE_DIR/loading" 2>/dev/null)
    if [ -n "$_dead" ]; then
        plog "上次开机死在加载 $_dead 上（面包屑还在），已加入黑名单"
        printf '%s\n' "$_dead" >> "$STATE_DIR/blacklist" 2>/dev/null
        sort -u "$STATE_DIR/blacklist" -o "$STATE_DIR/blacklist" 2>/dev/null
        cp -f "$STATE_DIR/loading" "$STATE_DIR/crash-module.txt" 2>/dev/null
        rm -f "$STATE_DIR/loading"
        sync
    fi
fi

cur=$(cat "$COUNT" 2>/dev/null)
case "$cur" in
    ''|*[!0-9]*) cur=0 ;;
esac
cur=$((cur + 1))
echo "$cur" > "$COUNT"

if [ "$cur" -gt "$LIMIT" ]; then
    # 已经连续失败太多次：禁用自己，并留下证据
    # 把卡死那次的最终快照另存一份：这是事后唯一能看到"卡在哪一步"的东西，
    # 不能让它被下一轮覆盖。
    # 优先用开机时固化的 prev-boot.txt；升级上来的第一轮可能还没有，退回用当前的。
    if [ -f "$PREV" ]; then
        cp -f "$PREV" "$HANG" 2>/dev/null
    elif [ -f "$SNAP" ]; then
        cp -f "$SNAP" "$HANG" 2>/dev/null
    fi
    touch "$MODDIR/disable"
    plog "连续 $((cur - 1)) 次开机未成功加载，已自动禁用本模块"
    plog "排查：adb pull /data/adb/droidspaces_lkm.d/hang-report.txt"
    plog "      adb pull /data/adb/droidspaces_lkm.log"
    echo 0 > "$COUNT"
fi
