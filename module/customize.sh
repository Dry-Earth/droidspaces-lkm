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

# 文案语言目录。安装期就按系统语言显示，国际用户不用看中文猜。
# shellcheck source=i18n.sh
[ -f "${MODPATH:-.}/i18n.sh" ] && . "${MODPATH:-.}/i18n.sh"
[ -f "${0%/*}/i18n.sh" ] && . "${0%/*}/i18n.sh"

ui_print " "
ui_print "*********************************"
ui_print "  Droidspaces LKM"
ui_print "  ${M_INSTALL_TAGLINE}"
ui_print "*********************************"
ui_print " "

# 只支持 arm64：全部 .ko 都是 aarch64
case "$(uname -m)" in
    aarch64|arm64) ;;
    *)
        ui_print "! ${M_ARCH_UNSUPPORTED}$(uname -m)"
        abort "  ${M_INSTALL_ABORTED}"
        ;;
esac

KREL=$(uname -r)
ui_print "- ${M_KERNEL}: $KREL"

# 提前告诉用户会选中哪个 KMI，装错包时一眼能看出来（见 issues/1）
major=$(echo "$KREL" | grep -oE '^[0-9]+[.][0-9]+')
case "$major" in
    5.10) ui_print "- ${M_KERNEL_LINE}: 5.10 (Android 12 / 13)" ;;
    5.15) ui_print "- ${M_KERNEL_LINE}: 5.15 (Android 13 / 14)" ;;
    6.1)  ui_print "- ${M_KERNEL_LINE}: 6.1 (Android 14)" ;;
    6.6)  ui_print "- ${M_KERNEL_LINE}: 6.6 (Android 15)" ;;
    6.12) ui_print "- ${M_KERNEL_LINE}: 6.12 (Android 16)" ;;
    *)    ui_print "! ${M_KERNEL_UNSUPPORTED}: ${major:-?}" ;;
esac

ui_print "- ${M_COMPONENTS}: lkm4ctr / devtmpfs_lkm / macvlan / ip6table_nat / vkms"
ui_print "-                droid_lkm_pids / droid_lkm_cpu"
ui_print "- ${M_LOAD_STAGE}"
ui_print " "
ui_print "- ${M_RUNTIME_LOG}: /data/adb/droidspaces_lkm.log"
ui_print "- ${M_HANG_REPORT}: /data/adb/droidspaces_lkm.d/hang-report.txt"
ui_print "- ${M_STATUS_QUERY}"
ui_print " "

# 把本地化描述写进 module.prop。
#
# KernelSU 模块列表显示的就是这里的 description；仓库里那份是固定的英文，
# 安装时按系统语言改写一次，之后一直生效。拿不到 M_DESC 就不动它。
if [ -n "$M_DESC" ] && [ -f "${MODPATH:-.}/module.prop" ]; then
    # 用 | 作分隔符，描述里可能有 / 和空格
    if sed -i "s|^description=.*|description=$M_DESC|" "${MODPATH:-.}/module.prop" 2>/dev/null; then
        ui_print "- description -> ${LANG_CODE}"
    fi
fi

ui_print "${M_REBOOT_AFTER}"
ui_print " "