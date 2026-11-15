#!/system/bin/sh
# uninstall.sh - 卸载时执行
#
# 刻意不在这里 rmmod。
#
# 这些模块提供的是 namespace / 文件系统 / 字符设备，内核里可能还有进程或
# 容器正持有它们（比如某个容器进程的 nsproxy 指向模块创建的 nsproxy）。
# 卸载模块会把那些结构体一起释放，内核随即在别人的上下文里访问已释放内存
# —— 这是 panic，不是干净退出。
#
# 所以模块驻留到下次重启；重启后模块目录已消失，自然不会再加载。

rm -rf /data/adb/droidspaces_lkm.d
rm -f /data/adb/droidspaces_lkm.log /data/adb/droidspaces_lkm.log.old
