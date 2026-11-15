#!/system/bin/sh
# boot-completed.sh - Android 真正启动完成后才清零开机计数器
#
# 为什么不在 service.sh 里清零：
#   之前的写法是 service.sh 一跑完就清零。但模块本身就是在 service.sh 里
#   insmod 的 —— 加载成功、随后系统卡死的情况，计数器已经被清了，保护完全
#   不会触发。实际发生过一次：service.sh 报了「=== 完成 ===」，之后整个系统
#   卡住，只能手动进安全模式救回来。
#
#   boot-completed 是 KernelSU 在系统启动完成后调用的，那时 zygote、system_server
#   都已经起来，卡死不会被误判成「启动成功」。只有走到这里才算这次开机真的成功。
#
# 这个脚本要快：它不影响任何逻辑，只是删一个文件。

rm -f /data/adb/droidspaces_lkm.bootcount

# 开机成功：在 kernel log 和持久日志里各留一条，
# 这样 bugreport 里能直接看出"这次开机到底成没成"。
_msg="=== boot-completed：本次开机成功，计数器已清零 ==="
printf '%s
' "[$(date '+%m-%d %H:%M:%S')] $_msg" >> /data/adb/droidspaces_lkm.log 2>/dev/null
printf '<6>droidspaces_lkm: %s
' "$_msg" > /dev/kmsg 2>/dev/null
exit 0
