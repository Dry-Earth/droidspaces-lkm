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
M_LITE_FALLBACK="lkm4ctr failed to load, falling back to the lite build (no vendored overlayfs)"
M_LITE_OK="lite build loaded; overlay uses the kernel's own implementation"
M_LITE_FAIL="the lite build failed too -- the symbol gap is beyond what can be degraded"
M_LITE_ABSENT="no lite build available to fall back to"
M_MODULE_VER="Version "
M_ARCH="Arch    "
M_NONE="none"
M_COMPONENTS="Components"
M_INSTALL_TAGLINE="Container capabilities for stock GKI kernels"
M_ARCH_UNSUPPORTED="This module is arm64-only. Current architecture: "
M_INSTALL_ABORTED="Installation aborted"
M_KERNEL_LINE="Kernel series"
M_KERNEL_UNSUPPORTED="Kernel series not in the supported list"
M_KMI_UNKNOWN="Could not read the device's factory API level; install the package that matches the device."
M_KMI_MISMATCH_HEAD="This package is for a different Android generation than the device."
M_KMI_MISMATCH="package=%s device=%s"
M_KMI_MISMATCH_TAIL="A wrong-generation package still loads (vermagic only checks 5.10/5.15) and can hang the kernel. Download the package named for the device's generation."
M_LOAD_STAGE="Load stage: late_start (service.sh), does not block boot"
M_RUNTIME_LOG="Runtime log"
M_HANG_REPORT="Hang report"
M_STATUS_QUERY="Status: the Action button on the KernelSU module page"
M_REBOOT_AFTER="Reboot the device after installation"
M_DESC="Stock GKI: PID/IPC/UTS/user ns, devtmpfs, macvlan, IPv6 NAT, vkms, cgroup cpu.max/pids emu."
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
M_CAP_PIDMNT="PID + mount namespace combo"
M_CAP_PROC="mount /proc inside container"
M_CAP_DEVTMPFS="devtmpfs (registered, %s nodes after mount)"
M_CAP_DEVTMPFS_NO="devtmpfs not registered"
M_CAP_TMPFS="tmpfs ACL/xattr (container setfacl/setcap)"
M_CAP_TMPFS_NO="tmpfs ACL/xattr missing (setfacl/setcap in containers fail)"
M_CAP_TMPFS_NA="tmpfs ACL/xattr: /proc/config.gz unavailable"
M_CAP_VKMS="/dev/dri/renderD128 (vkms)"
M_CAP_VKMS_NO="/dev/dri/renderD128 absent"
M_DISP_MALI0="/dev/mali0 present (mapped by Droidspaces --hw-access)"
M_DISP_MALI0_NO="no /dev/mali0 on this device"
M_DISP_KBASE="mali_kbase driver loaded"
M_DISP_KBASE_NO="mali_kbase not loaded"
M_VKMS_HINT="Anland 6.x/waylandbridge does not need it; 5.x or self-composited desktops do (create enable_vkms)"
    M_CAP_MALI="Mali GPU context (mali_nsfix loaded)"
    M_CAP_MALI_NO="Mali GPU context — mali_nsfix not loaded; eglInitialize will fail with 0x3001"
    M_CAP_MALI_NA="not a Mali device"
    M_SKIP_VKMS="vkms: /dev/dri/renderD128 already present, skipped"
    M_SKIP_VKMS_MALI="vkms: Mali GPU present, compositor uses /dev/mali0 directly"
    M_SKIP_VKMS_OFF="vkms: not loaded by default; create enable_vkms in the module directory to load it"
    M_SKIP_MALI_FALLBACK="vkms: no render node on a non-Mali platform, loaded as fallback"
    M_SKIP_MALI="mali_nsfix: no Mali GPU on this device, skipped"
    M_SKIP_MALI_DISABLE="mali_nsfix: disable_mali is set in the module directory, skipped"
    M_MALI_DRYRUN_OK="kprobe not armed; read nshf_active / nshf_probe_ok / nshf_layout_valid under /sys/module/mali_nsfix/parameters/"
    M_MALI_NOT_ARMED="(dry-run or probe failed)"
    M_PLATFORM="platform"
    M_SEC_MALI="Mali GPU context (mali_nsfix)"
    M_MALI_NA="not a Mali device"
    M_MALI_NOT_LOADED="mali_nsfix not loaded on a Mali device"
    M_MALI_ACTIVE="kprobe armed"
    M_MALI_DRY="loaded but unarmed (dry-run or probe failed)"
    M_MALI_PROBE_OK="find_get_pid probe OK"
    M_MALI_PROBE_NO="find_get_pid probe unavailable on this kernel"
    M_MALI_LAYOUT_BAD="struct module layout check FAILED -- would misattribute callers, not armed"
    M_MALI_DRIVER="driver"
    M_MALI_COUNT="intercepted %s, redirected %s"
M_ROUTE_KEEP="keep previous route: %s"
M_ROUTE_NEED="No valid display route config found. Please choose:"
M_ROUTE_OPT6="VolUp = Anland 6.x (/dev/mali0 + mali_nsfix, no vkms)"
M_ROUTE_OPT5="VolDown = Standard desktop 5.x (needs vkms render node)"
M_ROUTE_WAIT="Press a volume key within 8s..."
M_ROUTE_NO_KEY="No volume key detected; using auto. Change it later in the module WebUI."
M_ROUTE_SET="route set to %s (takes effect after reboot)"
M_ROUTE_QUALCOMM="route=auto (default for Qualcomm)"
M_ROUTE_WEBUI="Change the route any time in this module's WebUI page."
M_PACKAGES="One-click packs:"
M_ROUTE_NOW="current route"
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
    M_LITE_FALLBACK="lkm4ctr 加载失败，回退到精简版（不带 vendored overlayfs）"
    M_LITE_OK="已加载精简版；overlay 使用内核自带实现"
    M_LITE_FAIL="精简版也加载失败 —— 符号缺口超出可降级范围"
    M_LITE_ABSENT="没有精简版可回退"
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
    M_KMI_UNKNOWN="读不到设备出厂 API level；请安装与设备匹配的那个包。"
    M_KMI_MISMATCH_HEAD="这个包不是本机 Android 代际的模块。"
    M_KMI_MISMATCH="包=%s 设备=%s"
    M_KMI_MISMATCH_TAIL="装错代不会报错（vermagic 只比到 5.10/5.15），但可能在 namespace 路径上卡死。请改下载与设备代际同名的包。"
    M_LOAD_STAGE="加载阶段: late_start（service.sh），不阻塞开机"
    M_RUNTIME_LOG="运行日志"
    M_HANG_REPORT="卡死现场"
    M_STATUS_QUERY="状态查询: KernelSU 模块页的「操作」按钮"
    M_REBOOT_AFTER="安装完成后请重启设备"
    M_DESC="原生 GKI 容器支持：PID/IPC/UTS/user ns、devtmpfs、macvlan、IPv6 NAT、vkms、cgroup cpu.max/pids 仿真。"

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
    M_CAP_PIDMNT="PID + mount 命名空间组合"
    M_CAP_PROC="容器内挂载 /proc"
    M_CAP_DEVTMPFS="devtmpfs（已注册，挂载后 %s 个节点）"
    M_CAP_DEVTMPFS_NO="devtmpfs 未注册"
    M_CAP_TMPFS="tmpfs ACL/xattr（容器内 setfacl/setcap 可用）"
    M_CAP_TMPFS_NO="tmpfs 无 ACL/xattr（容器内 setfacl/setcap 会失败）"
    M_CAP_TMPFS_NA="tmpfs ACL/xattr：读不到 /proc/config.gz"
    M_CAP_VKMS="/dev/dri/renderD128 (vkms)"
    M_CAP_VKMS_NO="/dev/dri/renderD128 不存在"
    M_DISP_MALI0="/dev/mali0 存在（由 Droidspaces --hw-access 映射）"
    M_DISP_MALI0_NO="本设备没有 /dev/mali0"
    M_DISP_KBASE="mali_kbase 驱动已加载"
    M_DISP_KBASE_NO="mali_kbase 未加载"
    M_VKMS_HINT="Anland 6.x/waylandbridge 不需要；5.x 或自带合成器的桌面需要（创建 enable_vkms）"
    M_CAP_MALI="Mali GPU context（mali_nsfix 已加载）"
    M_CAP_MALI_NO="Mali GPU context —— mali_nsfix 未加载，eglInitialize 会返回 0x3001"
    M_CAP_MALI_NA="非 Mali 设备"
    M_SKIP_VKMS="vkms: /dev/dri/renderD128 已存在，跳过"
    M_SKIP_VKMS_MALI="vkms: 存在 Mali GPU，合成器直接用 /dev/mali0"
    M_SKIP_VKMS_OFF="vkms: 默认不加载；需要时在模块目录创建 enable_vkms"
    M_SKIP_MALI_FALLBACK="vkms: 非 Mali 平台缺 render node，作为兜底加载"
    M_SKIP_MALI="mali_nsfix: 本设备没有 Mali GPU，跳过"
    M_SKIP_MALI_DISABLE="mali_nsfix: 模块目录里存在 disable_mali，跳过"
    M_MALI_DRYRUN_OK="未挂钩；判据看 /sys/module/mali_nsfix/parameters/ 下的 nshf_active / nshf_probe_ok / nshf_layout_valid"
    M_MALI_NOT_ARMED="（干跑或探针失败）"
    M_PLATFORM="平台"
    M_SEC_MALI="Mali GPU context（mali_nsfix）"
    M_MALI_NA="非 Mali 设备"
    M_MALI_NOT_LOADED="Mali 设备上 mali_nsfix 未加载"
    M_MALI_ACTIVE="kprobe 已挂"
    M_MALI_DRY="已加载但未挂钩（干跑或探针失败）"
    M_MALI_PROBE_OK="find_get_pid 探针可用"
    M_MALI_PROBE_NO="当前内核上 find_get_pid 探针不可用"
    M_MALI_LAYOUT_BAD="struct module 布局校验失败 —— 会认错调用者，未挂钩"
    M_MALI_DRIVER="驱动"
    M_MALI_COUNT="拦截 %s 次，重定向 %s 次"
    M_ROUTE_KEEP="保留原路线：%s"
    M_ROUTE_NEED="未找到有效的显示路线配置，请选择："
    M_ROUTE_OPT6="音量上 = Anland 6.x（/dev/mali0 + mali_nsfix，不需 vkms）"
    M_ROUTE_OPT5="音量下 = 标准桌面 5.x（需 vkms render node）"
    M_ROUTE_WAIT="8 秒内请按音量键…"
    M_ROUTE_NO_KEY="未读到音量键，已用 auto；装完可在模块页 WebUI 修改"
    M_ROUTE_SET="route 已设为 %s（重启后生效）"
    M_ROUTE_QUALCOMM="route=auto（高通平台默认）"
    M_ROUTE_WEBUI="随时可在本模块 WebUI 页面切换路线。"
    M_PACKAGES="懒人包："
    M_ROUTE_NOW="当前路线"

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
    M_LITE_FALLBACK="lkm4ctr の読み込みに失敗しました。軽量版（vendored overlayfs なし）にフォールバックします"
    M_LITE_OK="軽量版を読み込みました。overlay はカーネル標準実装を使います"
    M_LITE_FAIL="軽量版も失敗しました。シンボル不足が縮退可能な範囲を超えています"
    M_LITE_ABSENT="フォールバックできる軽量版がありません"
    M_MODULE_VER="モジュール版"
    M_ARCH="アーキ  "
    M_NONE="なし"
    M_COMPONENTS="コンポーネント"

    M_INSTALL_TAGLINE="素の GKI カーネルにコンテナ機能を追加"
    M_ARCH_UNSUPPORTED="このモジュールは arm64 専用です。現在のアーキテクチャ: "
    M_INSTALL_ABORTED="インストールを中止しました"
    M_KERNEL_LINE="カーネル系列"
    M_KERNEL_UNSUPPORTED="サポート対象外のカーネル系列"
    M_KMI_UNKNOWN="端末の出荷時 API level を取得できません。端末に合ったパッケージを入れてください。"
    M_KMI_MISMATCH_HEAD="このパッケージは端末の Android 世代とは別物です。"
    M_KMI_MISMATCH="パッケージ=%s 端末=%s"
    M_KMI_MISMATCH_TAIL="世代違いのパッケージも読み込めてしまい（vermagic は 5.10/5.15 まで）、カーネルがハングすることがあります。端末の世代と同じ名前のパッケージを入れてください。"
    M_LOAD_STAGE="読み込み段階: late_start（service.sh）、起動はブロックしません"
    M_RUNTIME_LOG="実行ログ"
    M_HANG_REPORT="ハング情報"
    M_STATUS_QUERY="状態確認: KernelSU モジュール画面の「操作」ボタン"
    M_REBOOT_AFTER="インストール後に再起動してください"
    M_DESC="素の GKI にコンテナ機能: PID/IPC/UTS/user ns、devtmpfs、macvlan、IPv6 NAT、vkms、cgroup cpu.max/pids エミュ。"

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
    M_CAP_PIDMNT="PID + mount 名前空間の組み合わせ"
    M_CAP_PROC="コンテナ内で /proc をマウント"
    M_CAP_DEVTMPFS="devtmpfs（登録済み、マウント後 %s ノード）"
    M_CAP_DEVTMPFS_NO="devtmpfs 未登録"
    M_CAP_TMPFS="tmpfs ACL/xattr（コンテナ内 setfacl/setcap 可）"
    M_CAP_TMPFS_NO="tmpfs に ACL/xattr なし（コンテナ内 setfacl/setcap は失敗）"
    M_CAP_TMPFS_NA="tmpfs ACL/xattr: /proc/config.gz を読めません"
    M_CAP_VKMS="/dev/dri/renderD128 (vkms)"
    M_CAP_VKMS_NO="/dev/dri/renderD128 がありません"
    M_CAP_MALI="Mali GPU コンテキスト（mali_nsfix 読み込み済み）"
    M_CAP_MALI_NO="Mali GPU コンテキスト —— mali_nsfix 未読み込み、eglInitialize は 0x3001 で失敗します"
    M_CAP_MALI_NA="Mali 非搭載"
    M_SKIP_VKMS="vkms: /dev/dri/renderD128 は既に存在、スキップ"
    M_SKIP_VKMS_MALI="vkms: Mali GPU があるため合成器は /dev/mali0 を直接使う"
    M_SKIP_VKMS_OFF="vkms: 既定では読み込みません。モジュールディレクトリに enable_vkms を作ると有効になります"
    M_SKIP_MALI_FALLBACK="vkms: 非 Mali プラットフォームで render node が無いためフォールバックとして読み込み"
    M_SKIP_MALI="mali_nsfix: このデバイスに Mali GPU はありません、スキップ"
    M_PLATFORM="プラットフォーム"

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
    # 模板里出现 %n 会让 printf 往栈上写整数（格式串漏洞里唯一真正危险的
    # 指示符）。当前模板都是仓库内的静态文案，%n 进不来；这里加一道拒绝是
    # 纵深防御，防止将来有人往 i18n 里塞带 %n 的串、或把外部内容误当模板传
    # 进来时变成内存写。其余 %s/%d 都只读参数，安全。
    case "$_fmt" in
        *%n*) printf '%s\n' "$_fmt"; return ;;
    esac
    # shellcheck disable=SC2059
    printf "$_fmt" "$@"
}