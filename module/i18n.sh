#!/system/bin/sh
# i18n.sh - 模块文案的语言目录
#
# 由 customize.sh / action.sh / service.sh source。
#
# 设计约束（重要）：**机器可读的部分一律不翻译**。
#   [OK] / [FAIL] / [缺] / [缺符号] / [--] / [MISS]   标记
#   符号名、KMI 标签、内核版本串、路径                数据
# 只翻译这些标记后面的人读描述。这样用户贴出来的日志
# 既能被人读懂，也能被 grep 正确解析。
#
# 语言判定顺序：
#   persist.sys.locale  →  ro.product.locale  →  ro.product.locale.language
# 取不到就用英文（国际用户优先，而不是默认中文）。

_i18n_locale() {
    for _p in persist.sys.locale ro.product.locale ro.product.locale.language; do
        _v=$(getprop "$_p" 2>/dev/null)
        [ -n "$_v" ] && { echo "$_v"; return; }
    done
    echo en
}

_RAW=$(_i18n_locale)

# 只看语言部分，忽略地区：zh-CN / zh_CN / zh-Hans-CN / zh-rTW 都归到 zh
case "$_RAW" in
    zh*|*Hans*|*Hant*|*CN*|*TW*|*HK*) LANG_CODE=zh ;;
    ja*|*JP*)                         LANG_CODE=ja ;;
    *)                                LANG_CODE=en ;;
esac

# 允许 installer / 用户强制指定：LKM4CTR_LANG=zh
[ -n "$LKM4CTR_LANG" ] && LANG_CODE="$LKM4CTR_LANG"

# ---------------------------------------------------------------------------
# 文案
#
# 变量名统一 M_ 前缀。英文是兜底，任何键在目标语言里缺失都回退英文。
# ---------------------------------------------------------------------------
# 先把英文填成默认值，各语言分支只覆盖自己翻译过的键。
# 这样某个语言漏翻一个键时回退到英文，而不是输出空字符串。
M_KERNEL="Kernel  "
M_MODULE_VER="Version "
M_ARCH="Arch    "
M_NONE="none"
M_COMPONENTS="Components"
M_INSTALL_TAGLINE="Container capabilities for stock GKI kernels"
M_ARCH_UNSUPPORTED="This module is arm64-only. Current architecture: "
M_INSTALL_ABORTED="Installation aborted"
M_KERNEL_LINE="Kernel series"
M_KERNEL_UNSUPPORTED="Kernel series not in the supported list"
M_LOAD_STAGE="Load stage: late_start (service.sh), does not block boot"
M_RUNTIME_LOG="Runtime log"
M_HANG_REPORT="Hang report"
M_STATUS_QUERY="Status: the Action button on the KernelSU module page"
M_REBOOT_AFTER="Reboot the device after installation"
M_DESC="Container capabilities for stock GKI kernels: PID/IPC/UTS/user namespaces, devtmpfs, macvlan, IPv6 NAT, virtual DRM render node, cgroup CPU/PID limits. Seven loadable modules, selected by KMI at boot."
M_SEC_STATE="Boot State"
M_SEC_LOAD="Load State"
M_SEC_EXPORT="Kernel Export Check"
M_SEC_CAPS="Capability Check"
M_SEC_LOG="Log (last 30 lines)"
M_BOOTCOUNT="Boot count"
M_BOOTCOUNT_HINT=" (>3 auto-disables)"
M_DISABLE="disable "
M_DISABLE_YES="present — module auto-disabled by boot guard"
M_DISABLE_NO="absent"
M_HANGREPORT_HAS="present"
M_SNAPSHOT="State snapshot"
M_LASTCRASH="Last hang"
M_LASTCRASH_HINT="← died while loading this"
M_BLACKLIST="Blacklist "
M_NOT_LOADED="not loaded"
M_EXPORT_NONE="Cannot derive KMI from kernel version, skipped"
M_EXPORT_NOFILE="No symbol manifest ko/symcheck-%s.txt (old module package?)"
M_EXPORT_ALL_OK="This kernel exports every symbol in the manifest"
M_EXPORT_MISS_ONE="%s needs %s — not exported by this kernel"
M_EXPORT_MISS_HEAD="%s missing. This is a vendor-kernel export-table difference,"
M_EXPORT_MISS_TAIL="not a broken package — please paste this whole section into the issue."
M_CAP_USERNS="user namespace"
M_CAP_PIDMNT="PID + mount + user namespace combo"
M_CAP_PROC="mount /proc inside container"
M_CAP_DEVTMPFS="devtmpfs (registered, %s nodes after mount)"
M_CAP_DEVTMPFS_NO="devtmpfs not registered"
M_CAP_VKMS="/dev/dri/renderD128 (vkms)"
M_CAP_VKMS_NO="/dev/dri/renderD128 absent"
M_LOG_LOADING="--- load ---"
M_LOG_LSMOD="--- lsmod ---"
M_LOG_CAPS="--- capability check ---"
M_LOG_DONE="=== done ==="
M_LOG_DONE_HINT=" (snapshot guard started, flushed every 15s for 10 min)"
M_LOG_BOOT_OK="=== boot-completed: this boot succeeded, counter cleared ==="
M_LOG_MISS_KO="missing module file"
M_LOG_VERMAGIC="has vermagic"
M_LOG_VERMAGIC_TAIL="which does not match kernel %s, skipped"
M_LOG_KMI_AMBIG="KMI %s, multiple candidates in directory, refusing to guess"
M_LOG_MISSING_SYM="needs but this kernel does not export:"
M_LOG_MISSING_SYM_TAIL="(vendor-kernel export-table difference, not a broken package)"
M_LOG_OPTIONAL="optional, skipped"

case "$LANG_CODE" in

zh)
    # --- 通用 ---
    M_KERNEL="内核    "
    M_MODULE_VER="模块版本"
    M_ARCH="架构    "
    M_NONE="无"
    M_COMPONENTS="组件"

    # --- customize.sh 安装期 ---
    M_INSTALL_TAGLINE="在原始 GKI 内核上补齐容器能力"
    M_ARCH_UNSUPPORTED="本模块只支持 arm64，当前架构："
    M_INSTALL_ABORTED="安装已中止"
    M_KERNEL_LINE="内核主线"
    M_KERNEL_UNSUPPORTED="未在支持列表中的内核主线"
    M_LOAD_STAGE="加载阶段: late_start（service.sh），不阻塞开机"
    M_RUNTIME_LOG="运行日志"
    M_HANG_REPORT="卡死现场"
    M_STATUS_QUERY="状态查询: KernelSU 模块页的「操作」按钮"
    M_REBOOT_AFTER="安装完成后请重启设备"
    M_DESC="在原生 GKI 内核上补齐容器能力：PID/IPC/UTS/用户命名空间、devtmpfs、macvlan、IPv6 NAT、虚拟 DRM 渲染节点、cgroup CPU/PID 限制。七个可加载模块，开机按 KMI 自动选择。"

    # --- action.sh 段标题 ---
    M_SEC_STATE="开机状态"
    M_SEC_LOAD="加载状态"
    M_SEC_EXPORT="内核导出检查"
    M_SEC_CAPS="能力验证"
    M_SEC_LOG="日志（末尾 30 行）"

    # --- action.sh 状态 ---
    M_BOOTCOUNT="开机计数"
    M_BOOTCOUNT_HINT="（>3 会自禁用）"
    M_DISABLE="disable "
    M_DISABLE_YES="存在 —— 本模块已被开机保护自动禁用"
    M_DISABLE_NO="无"
    M_HANGREPORT_HAS="有"
    M_SNAPSHOT="状态快照"
    M_LASTCRASH="上次卡死"
    M_LASTCRASH_HINT="← 是在加载它时死的"
    M_BLACKLIST="黑名单  "
    M_NOT_LOADED="未加载"

    # --- action.sh 导出检查 ---
    M_EXPORT_NONE="无法从内核版本推导 KMI，跳过"
    M_EXPORT_NOFILE="没有符号清单 ko/symcheck-%s.txt（旧版模块包？）"
    M_EXPORT_ALL_OK="本内核导出了清单里全部符号"
    M_EXPORT_MISS_ONE="%s 需要 %s —— 本内核未导出"
    M_EXPORT_MISS_HEAD="共 %s 条缺失。这是厂商内核的导出表差异，"
    M_EXPORT_MISS_TAIL="不是模块包损坏 —— 报 issue 时请把这整段贴上去。"

    # --- 能力验证 ---
    M_CAP_USERNS="user namespace"
    M_CAP_PIDMNT="PID + mount + user namespace 组合"
    M_CAP_PROC="容器内挂载 /proc"
    M_CAP_DEVTMPFS="devtmpfs（已注册，挂载后 %s 个节点）"
    M_CAP_DEVTMPFS_NO="devtmpfs 未注册"
    M_CAP_VKMS="/dev/dri/renderD128 (vkms)"
    M_CAP_VKMS_NO="/dev/dri/renderD128 不存在"

    # --- service.sh 开机日志 ---
    M_LOG_LOADING="--- 加载 ---"
    M_LOG_LSMOD="--- lsmod ---"
    M_LOG_CAPS="--- 能力验证 ---"
    M_LOG_DONE="=== 完成 ==="
    M_LOG_DONE_HINT="（快照守卫已启动，10 分钟内每 15 秒落盘一次）"
    M_LOG_BOOT_OK="=== boot-completed：本次开机成功，计数器已清零 ==="
    M_LOG_MISS_KO="缺少模块文件"
    M_LOG_VERMAGIC="的 vermagic"
    M_LOG_VERMAGIC_TAIL="与内核 %s 不匹配，跳过"
    M_LOG_KMI_AMBIG="KMI %s，目录里有多份候选，拒绝猜"
    M_LOG_MISSING_SYM="需要但本内核未导出:"
    M_LOG_MISSING_SYM_TAIL="（这是厂商内核的导出表差异，不是模块包损坏）"
    M_LOG_OPTIONAL="可选，跳过"
    ;;

ja)
    # 日语只做最小覆盖：大部分键回退英文，这里补齐最显眼的几句
    M_KERNEL="カーネル "
    M_MODULE_VER="モジュール版"
    M_ARCH="アーキ  "
    M_NONE="なし"
    M_COMPONENTS="コンポーネント"

    M_INSTALL_TAGLINE="素の GKI カーネルにコンテナ機能を追加"
    M_ARCH_UNSUPPORTED="このモジュールは arm64 専用です。現在のアーキテクチャ: "
    M_INSTALL_ABORTED="インストールを中止しました"
    M_KERNEL_LINE="カーネル系列"
    M_KERNEL_UNSUPPORTED="サポート対象外のカーネル系列"
    M_LOAD_STAGE="読み込み段階: late_start（service.sh）、起動はブロックしません"
    M_RUNTIME_LOG="実行ログ"
    M_HANG_REPORT="ハング情報"
    M_STATUS_QUERY="状態確認: KernelSU モジュール画面の「操作」ボタン"
    M_REBOOT_AFTER="インストール後に再起動してください"
    M_DESC="素の GKI カーネルにコンテナ機能を追加: PID/IPC/UTS/ユーザー名前空間、devtmpfs、macvlan、IPv6 NAT、仮想 DRM レンダーノード、cgroup CPU/PID 制限。7 つのロード可能モジュールを KMI に応じて起動時に選択。"

    M_SEC_STATE="起動状態"
    M_SEC_LOAD="読み込み状態"
    M_SEC_EXPORT="カーネルエクスポート検査"
    M_SEC_CAPS="機能検証"
    M_SEC_LOG="ログ（末尾 30 行）"

    M_BOOTCOUNT="起動回数"
    M_BOOTCOUNT_HINT="（3 回超で自動無効化）"
    M_DISABLE_YES="存在 —— 起動保護により自動無効化されています"
    M_DISABLE_NO="なし"
    M_HANGREPORT_HAS="あり"
    M_SNAPSHOT="状態スナップショット"
    M_LASTCRASH="前回のハング"
    M_LASTCRASH_HINT="← これを読み込んだ際に停止"
    M_BLACKLIST="ブラックリスト "
    M_NOT_LOADED="未読み込み"

    M_EXPORT_NONE="カーネル版から KMI を特定できず、スキップ"
    M_EXPORT_NOFILE="シンボル一覧 ko/symcheck-%s.txt がありません（旧版パッケージ？）"
    M_EXPORT_ALL_OK="このカーネルは一覧の全シンボルをエクスポートしています"
    M_EXPORT_MISS_ONE="%s が %s を要求 —— このカーネルは未エクスポート"
    M_EXPORT_MISS_HEAD="%s 件欠落。ベンダーカーネルのエクスポート表の差異であり、"
    M_EXPORT_MISS_TAIL="パッケージ破損ではありません —— issue にはこの部分を貼ってください。"

    M_CAP_USERNS="ユーザー名前空間"
    M_CAP_PIDMNT="PID + mount + ユーザー名前空間の組み合わせ"
    M_CAP_PROC="コンテナ内で /proc をマウント"
    M_CAP_DEVTMPFS="devtmpfs（登録済み、マウント後 %s ノード）"
    M_CAP_DEVTMPFS_NO="devtmpfs 未登録"
    M_CAP_VKMS="/dev/dri/renderD128 (vkms)"
    M_CAP_VKMS_NO="/dev/dri/renderD128 がありません"

    M_LOG_LOADING="--- 読み込み ---"
    M_LOG_LSMOD="--- lsmod ---"
    M_LOG_CAPS="--- 機能検証 ---"
    M_LOG_DONE="=== 完了 ==="
    M_LOG_DONE_HINT="（スナップショット監視を開始、10 分間 15 秒ごとに記録）"
    M_LOG_BOOT_OK="=== boot-completed：今回の起動は成功、カウンタをクリア ==="
    M_LOG_MISS_KO="モジュールファイルがありません"
    M_LOG_VERMAGIC="の vermagic"
    M_LOG_VERMAGIC_TAIL="がカーネル %s と一致しません、スキップ"
    M_LOG_KMI_AMBIG="KMI %s、ディレクトリに複数の候補があるため推測しません"
    M_LOG_MISSING_SYM="が必要だが本カーネルは未エクスポート:"
    M_LOG_MISSING_SYM_TAIL="（ベンダーカーネルのエクスポート表の差異であり、パッケージ破損ではありません）"
    M_LOG_OPTIONAL="任意のためスキップ"
    ;;

*)
    # 英文默认值已提到 case 之前，这里不需要再赋值
    :
    ;;
esac

# 带参数的文案：printf 一次，避免各脚本自己拼
#   msg M_CAP_DEVTMPFS 12
msg() {
    _fmt="$1"; shift
    # shellcheck disable=SC2059
    printf "$_fmt" "$@"
}