#!/bin/sh
# i18n.sh - 构建脚本的文案目录
#
# 与 module/i18n.sh 分开：那份在设备上跑，靠 getprop 判定语言；
# 这份在构建机/CI 容器里跑，没有 getprop，只能看 LANG / LC_ALL。
#
# 判定顺序：
#   LKM4CTR_LANG（显式指定，优先） -> LC_ALL -> LANG -> 英文
#
# 约束与模块侧相同：**标记与数据不翻译**。
#   [OK] [FAIL] [WARN] [SYM] [MISS]    标记
#   KMI 标签、模块名、符号名、路径      数据
# 只翻译标记后面的人读描述。
#
# 注意：这里的文案是 **printf 格式串**，不是成品句子。
# 变量（$KMI、模块名、符号名）在调用点才替换 —— i18n.sh 被 source 时
# 那些变量还不存在，直接写进字符串会展开成空。
# 调用方式：
#   printf "$B_MISSING\n" "$KMI" "$missing"

if [ -z "${LKM4CTR_LANG:-}" ]; then
    _loc="${LC_ALL:-${LANG:-}}"
    case "$_loc" in
        zh*|*CN*|*Hans*) LKM4CTR_LANG=zh ;;
        *)               LKM4CTR_LANG=en ;;
    esac
fi
BUILD_LANG="$LKM4CTR_LANG"

# ---------------------------------------------------------------------------
# 英文默认值。各语言分支只覆盖自己翻译过的键。
# %s 的位置见每行末尾注释。
# ---------------------------------------------------------------------------
B_HAVE='present'
B_ABSENT='absent'
B_NONE='none'

# %s=GUARD_MODE  %s=GUARD_CFLAGS 或 none
B_STACK_PROBE='stack protector: tree=%s extra flags=[%s]'
# %s=KDIR
B_NO_CONFIG='cannot locate %s/.config; stack protector mode undetermined, symbol check runs after the build'
B_SRC_TREE='source tree'
B_NO_KSRC='kernel source tree not found, falling back to the in-repo copy'

# %s=模块文件名
B_RELOC_C='%s issues a CALL26 to a data symbol (declared with the wrong type):'

# %s=KMI
B_VKMS_DR_PATCH='vkms @ %s (DRIVER_RENDER patch failed)'
B_VKMS_NO_DR='vkms @ %s (driver_features has no DRIVER_RENDER, not shipping)'
B_VKMS_DEBUGFS='vkms @ %s (DEBUG_FS compat patch failed, not shipping)'
B_VKMS_PATCH_NOEFF='vkms @ %s (patch had no effect, not building)'
B_VKMS_NO_SRC='vkms @ %s (no source in kernel tree)'
B_MACVLAN_REWRITE='macvlan @ %s (source rewrite failed, symbol dependencies remain)'
B_MACVLAN_NO_SRC='macvlan @ %s (no source in kernel tree)'
# %s=模块名(小写)  %s=KMI
B_DLM_AUDIT='droid_lkm_%s @ %s failed symbol type check, artifact removed'
B_DLM_NOPROD='droid_lkm_%s @ %s (no artifact)'
B_UART_NOPROD='uart_guard @ %s (no artifact)'
B_UART_NOSRC='uart_guard @ %s (extra/uart_guard missing)'
B_MALI_NOPROD='mali_nsfix @ %s (no artifact)'
B_MALI_FAIL='mali_nsfix @ %s (build failed, experimental module, not fatal)'
B_MALI_NOSRC='mali_nsfix @ %s (extra/mali_nsfix missing)'

# %s=KMI
B_SYMCHECK_HEAD='=== %s symbol check ==='
# %s=模块文件名  %s=符号名
B_SYM_BAD='%s imports %s -- not exported by some kernels'
B_SYM_OK='no known non-portable symbols'
# %s=计数
B_SYM_WARN='%s found; confirm the target kernel export table before shipping'
# %s=KMI
B_PROD_HEAD='=== %s artifacts ==='
# %s=计数
B_FAIL_HEAD='=== failures for this KMI (%s) ==='
# %s=KMI  %s=缺失模块列表
B_MISSING='[FAIL] %s missing modules:%s'
B_INCOMPLETE='a partial package must not be published'
B_ALL_PRESENT='8/8 modules present'
B_NO_NM='no nm/llvm-nm found; the symbol manifest will be empty and devices cannot report which symbol is missing'
# %s=工具名
B_NM_TOOL='symbol extraction tool: %s'
# %s=文件名  %s=条数
B_MANIFEST='symbol manifest: %s (%s entries)'

# ---------------------------------------------------------------------------
# 语言覆盖
# ---------------------------------------------------------------------------
case "$BUILD_LANG" in
zh)
    B_HAVE='有'
    B_ABSENT='无'
    B_NONE='无'

    B_STACK_PROBE='栈保护: 树=%s 额外参数=[%s]'
    B_NO_CONFIG='找不到 %s/.config，栈保护模式无法判定；构建后再做符号校验'
    B_SRC_TREE='源码树'
    B_NO_KSRC='找不到内核源码树，退回仓库内副本'

    B_RELOC_C='%s 对数据符号发起了函数调用（声明类型写错）:'

    B_VKMS_DR_PATCH='vkms @ %s (DRIVER_RENDER 补丁失败)'
    B_VKMS_NO_DR='vkms @ %s (driver_features 里没有 DRIVER_RENDER，跳过出货)'
    B_VKMS_DEBUGFS='vkms @ %s (DEBUG_FS 兼容补丁失败，跳过出货)'
    B_VKMS_PATCH_NOEFF='vkms @ %s (补丁未生效，不编译)'
    B_VKMS_NO_SRC='vkms @ %s (内核树无源码)'
    B_MACVLAN_REWRITE='macvlan @ %s (源码改写失败，仍有符号依赖)'
    B_MACVLAN_NO_SRC='macvlan @ %s (内核树无源码)'
    B_DLM_AUDIT='droid_lkm_%s @ %s 符号类型自检失败，已删除产物'
    B_DLM_NOPROD='droid_lkm_%s @ %s (没有产物)'
    B_UART_NOPROD='uart_guard @ %s (没有产物)'
    B_UART_NOSRC='uart_guard @ %s (缺少 extra/uart_guard)'
    B_MALI_NOPROD='mali_nsfix @ %s (没有产物)'
    B_MALI_FAIL='mali_nsfix @ %s (编译失败，实验模块，不阻断)'
    B_MALI_NOSRC='mali_nsfix @ %s (缺少 extra/mali_nsfix)'

    B_SYMCHECK_HEAD='=== %s 符号自检 ==='
    B_SYM_BAD='%s 依赖 %s —— 部分内核不导出'
    B_SYM_OK='无已知不可移植符号'
    B_SYM_WARN='共 %s 处，装机前请确认目标内核的导出表'
    B_PROD_HEAD='=== %s 产物 ==='
    B_FAIL_HEAD='=== 本 KMI 失败项 (%s) ==='
    B_MISSING='[FAIL] %s 缺少模块:%s'
    B_INCOMPLETE='残缺的模块包不能发布'
    B_ALL_PRESENT='8/8 模块齐全'
    B_NO_NM='找不到 nm/llvm-nm，符号依赖清单会是空的（装机时无法报出缺哪个符号）'
    B_NM_TOOL='符号提取工具: %s'
    B_MANIFEST='符号依赖清单: %s（%s 条）'
    ;;
esac