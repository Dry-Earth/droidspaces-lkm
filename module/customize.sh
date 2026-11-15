# customize.sh - 安装脚本（KernelSU 在解压 zip 后执行本文件）
#
# 规范要求（KernelSU 文档 "Module guide"）：
#   - 所有脚本用 MODDIR=${0%/*} 取自身目录，不要硬编码 /data/adb/modules/<id>
#   - 只在这里做安装期决策；运行期逻辑放 service.sh
#   - SKIPUNZIP=0 表示照常解压；置 1 则完全自己解压
#
# 本模块不含 system/ 覆盖，也不需要 sepolicy.rule：
# 它只是把若干 .ko 放进 ko/，由 service.sh 在 late_start 阶段按 KMI 加载。

SKIPUNZIP=0

ui_print " "
ui_print "*********************************"
ui_print "  Droidspaces LKM"
ui_print "  在原始 GKI 内核上补齐容器能力"
ui_print "*********************************"
ui_print " "

# 只支持 arm64：全部 .ko 都是 aarch64
case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
        ui_print "! 本模块只支持 arm64，当前架构：$(uname -m)"
        abort "  安装已中止"
        ;;
esac

KREL=$(uname -r)
ui_print "- 内核版本: $KREL"

# 提前告诉用户会选中哪个 KMI，装错包时一眼能看出来（见 issues/1）
major=$(echo "$KREL" | grep -oE '^[0-9]+[.][0-9]+')
case "$major" in
    5.10) ui_print "- 内核主线: 5.10（Android 12 / 13）" ;;
    5.15) ui_print "- 内核主线: 5.15（Android 13 / 14）" ;;
    6.1)  ui_print "- 内核主线: 6.1（Android 14）" ;;
    6.6)  ui_print "- 内核主线: 6.6（Android 15）" ;;
    6.12) ui_print "- 内核主线: 6.12（Android 16）" ;;
    *)    ui_print "! 未在支持列表中的内核主线：${major:-未知}" ;;
esac

ui_print "- 组件: lkm4ctr / devtmpfs_lkm / macvlan / ip6table_nat / vkms"
ui_print "-        droid_lkm_pids / droid_lkm_cpu"
ui_print "- 加载阶段: late_start（service.sh），不阻塞开机"
ui_print " "
ui_print "- 运行日志: /data/adb/droidspaces_lkm.log"
ui_print "- 卡死现场: /data/adb/droidspaces_lkm.d/hang-report.txt"
ui_print "- 状态查询: KernelSU 模块页的「操作」按钮"
ui_print " "
ui_print "安装完成后请重启设备"
ui_print " "
