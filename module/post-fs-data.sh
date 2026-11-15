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

cur=$(cat "$COUNT" 2>/dev/null)
case "$cur" in
    ''|*[!0-9]*) cur=0 ;;
esac
cur=$((cur + 1))
echo "$cur" > "$COUNT"

if [ "$cur" -gt "$LIMIT" ]; then
    # 已经连续失败太多次：禁用自己，并留下证据
    touch "$MODDIR/disable"
    echo "$(date): 连续 $((cur - 1)) 次开机未成功加载，已自动禁用本模块" \
        >> /data/local/tmp/droidspaces-lkm.log
    echo 0 > "$COUNT"
fi
