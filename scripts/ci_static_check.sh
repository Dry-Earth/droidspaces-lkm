#!/bin/sh
# CI 静态检查：不需要设备、也不需要内核头文件就能验证的部分。
#
# 覆盖三类改动：
#   1) module/*.sh 与 scripts/*.sh 的语法（mksh/bash 差异在真实设备上才暴露，
#      这里至少保证 POSIX sh 解析通过）；
#   2) mali_nsfix 的状态参数在中英文 README 里都有文档；
#   3) gen_validation.py 能在空产物集上产出合法 JSON。
#
# 退出码非 0 即失败，供 GitHub Actions 直接调用。

set -u
fail=0

die() {
    printf 'static-check FAIL: %s\n' "$*" >&2
    fail=1
}

# 1) shell 语法。按 shebang 选解释器：module/*.sh 是 /system/bin/sh
#   （POSIX），而 scripts/build_modules.sh 用了 bash 特性，用 sh -n 会误报。
for f in module/*.sh scripts/*.sh; do
    [ -f "$f" ] || continue
    shebang=$(head -n 1 "$f" 2>/dev/null)
    shell=sh
    case "$shebang" in
        *bash*) shell=bash ;;
    esac
    command -v "$shell" >/dev/null 2>&1 || shell=sh
    if ! "$shell" -n "$f"; then
        die "shell 语法错误 ($shell): $f"
    fi
done

# 2) mali_nsfix 的参数文档齐全（含干跑相关的新参数）
for p in activate active probe_ok layout_valid driver seen hits prefix resolve_left; do
    grep -q "nshf_$p" extra/mali_nsfix/README.md          || die "README.md 未记录 nshf_$p"
    grep -q "nshf_$p" extra/mali_nsfix/README.zh-CN.md    || die "README.zh-CN.md 未记录 nshf_$p"
done

# 3) 来源与先例文件
[ -f extra/mali_nsfix/ORIGIN ] || die "缺少 extra/mali_nsfix/ORIGIN"

# 4) 验证证据生成器可运行且输出合法 JSON（空产物集也要能产出）
tmp=$(mktemp -d 2>/dev/null) || die "mktemp 不可用"
if command -v python3 >/dev/null 2>&1; then
    PY=python3
else
    PY=python
fi
"$PY" scripts/gen_validation.py --ko-dir "$tmp" --out "$tmp/v.json" >/dev/null \
    || die "gen_validation.py 运行失败"
"$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp/v.json" \
    || die "validation.json 不是合法 JSON"
rm -rf "$tmp"

# 5) doctor 与机器可读状态行的存在性
grep -q 'nshf_status' module/action.sh || die "action.sh 缺少 nshf_status 输出"
grep -q 'mali_nsfix_dryrun' module/service.sh || die "service.sh 缺少干跑开关接线"
grep -q 'load_mod_retry' module/service.sh || die "service.sh 缺少有界重试 helper"

# 6) droid_lkm_pids：kprobe pre-handler 里不允许出现会睡眠的 kernfs 查找。
#    2026-11-18 的 panic（BUG: scheduling while atomic）就是 kernfs_find_and_get
#    在原子上下文 down_read 造成的，这条静态检查防止回归。
#    只匹配代码行：注释里提到这个名字是允许的（解释为什么不能用）。
_bad_kernfs=$(grep -n 'kernfs_find_and_get' extra/cgrouplimits/pids_mod.c 2>/dev/null |
              grep -vE '^[0-9]+:[[:space:]]*(\*|/\*|//)')
[ -z "$_bad_kernfs" ] || die "pids_mod.c 又出现了 kernfs_find_and_get() 调用（kprobe 原子上下文禁止睡眠）"
grep -q 'ctl_memory_seen' extra/cgrouplimits/pids_mod.c \
    || die "pids_mod.c 缺少观测表判定 ctl_memory_seen"
grep -q 'ctl_obs_lock' extra/cgrouplimits/pids_mod.c \
    || die "pids_mod.c 缺少观测表锁 ctl_obs_lock"

# 7) 显示路线（route）链路完整：安装器、加载器、操作页、WebUI、README
for f in module/webroot/index.html module/webroot/index.js module/webroot/styles.css \
         module/webroot/locales/zh.json module/webroot/locales/en.json module/route; do
    [ -f "$f" ] || die "缺少 $f"
done
grep -q 'auto' module/route || die "module/route 默认值应为 auto"
# WebUI 结构：底栏页签（≥4，含模块页）+ 四个基础视图 + 语言菜单
for v in view-home view-route view-diag view-about; do
    grep -q "id=\"$v\"" module/webroot/index.html || die "WebUI 缺少视图 $v"
done
[ "$(grep -c 'class="tab' module/webroot/index.html)" -ge 4 ] \
    || die "WebUI 底栏不足四个页签"
grep -q 'id="lang-menu"' module/webroot/index.html \
    || die "WebUI 缺少语言菜单（md-menu）"
grep -q 'hideRouteTabIfNotMtk' module/webroot/index.js \
    || die "WebUI 缺少非 MTK 隐藏路线页签的逻辑"
grep -q 'platformIsMtk' module/webroot/index.js \
    || die "WebUI 缺少平台判定 platformIsMtk"
grep -q 'route_keytest' module/customize.sh \
    || die "customize.sh 缺少安装期音量键选择 route_keytest"
grep -q 'ROUTE=$(cat' module/service.sh \
    || die "service.sh 缺少 route 解析"
# 路由此前的字面量已移入 i18n 键（service.sh 里是 dlog "$M_VKMS_ANLAND6"），
# 所以这里验证 service.sh 真的引用了这两条键，而不是 grep 已经不存在的字面量。
grep -q 'M_VKMS_ANLAND6' module/service.sh \
    || die "service.sh 缺少 anland6 路线分支"
grep -q 'M_VKMS_FORCE\|M_VKMS_ADRENO' module/service.sh \
    || die "service.sh 缺少 desktop5 路线分支"
grep -q 'route)' module/action.sh || die "action.sh 缺少 route 子命令"
grep -q 'Droidspaces-rootfs-Desktop-builder' README.md \
    || die "README.md 缺少 5.x 懒人包链接"
grep -q 'droidspaces-anland6-rootfs' README.md \
    || die "README.md 缺少 6.x 懒人包链接"

# 8) Docker / iptables 诊断（issue #5）与 tmpfs ACL/xattr 诊断（issue #6）
#
# 两者都是**编译期内核配置**，任何内核模块都补不齐；模块侧只能如实报出来。
# 这里验证：(a) 判定代码与文案键都在；(b) 判定逻辑在两种 fixture 下给出
# 正确答案 —— 光 grep 代码形状挡不住把 =y 判成 =n 这类写反。
for k in M_CAP_NF_NFT M_CAP_NF_NFT_MOD M_CAP_NF_NFT_NO M_CAP_NF_LEGACY \
         M_CAP_NF_LEGACY_NO M_CAP_NF_BRIDGE M_CAP_NF_BRIDGE_NO M_CAP_NF_NA; do
    grep -q "\b$k=" module/i18n.sh || die "i18n.sh 缺少 $k"
    grep -q "$k" module/action.sh    || die "action.sh 未引用 $k"
done
for c in CONFIG_NF_TABLES CONFIG_BRIDGE_NETFILTER CONFIG_IP_NF_IPTABLES \
         CONFIG_NETFILTER_XTABLES_COMPAT CONFIG_IP_NF_NAT; do
    grep -q "$c" module/action.sh || die "action.sh 未检查 $c"
done
grep -q 'nft_status' module/action.sh || die "action.sh 缺少机器可读的 nft_status 行"
grep -q 'CONFIG_TMPFS_XATTR' module/action.sh || die "action.sh 未检查 CONFIG_TMPFS_XATTR"
grep -q 'M_CAP_TMPFS' module/action.sh || die "action.sh 缺少 tmpfs ACL/xattr 诊断"

# 判定逻辑真值测试：用 fixture 覆盖内核 config 路径。
# DSL_KERNEL_CONFIG 是 action.sh 里的覆盖口，CI 用它喂假 config。
_fx=$(mktemp -d 2>/dev/null) || die "mktemp 不可用"
cat > "$_fx/gki.config" <<'EOF'
CONFIG_NETFILTER_XTABLES_COMPAT=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_NAT=y
CONFIG_BRIDGE=y
CONFIG_TMPFS=y
EOF
cat > "$_fx/nft.config" <<'EOF'
CONFIG_NF_TABLES=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_NETFILTER_XTABLES_COMPAT=y
CONFIG_IP_NF_NAT=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOF

_out=$(DSL_KERNEL_CONFIG="$_fx/gki.config" sh module/action.sh 2>/dev/null)
printf '%s\n' "$_out" | grep -q 'nft_status nf_tables=no legacy=yes .*bridge_netfilter=no' \
    || die "GKI 形状的 config 判定不对（应为 nf_tables=no legacy=yes bridge_netfilter=no）"
printf '%s\n' "$_out" | grep -q 'CONFIG_TMPFS_XATTR' \
    && die "action.sh 把配置行原样打印出来了"

_out=$(DSL_KERNEL_CONFIG="$_fx/nft.config" sh module/action.sh 2>/dev/null)
printf '%s\n' "$_out" | grep -q 'nft_status nf_tables=yes legacy=yes .*bridge_netfilter=yes' \
    || die "有 nf_tables 的 config 判定不对（应为 nf_tables=yes bridge_netfilter=yes）"

# 没有 config 时必须标 NA，不能瞎猜
_out=$(DSL_KERNEL_CONFIG="$_fx/does-not-exist" sh module/action.sh 2>/dev/null)
printf '%s\n' "$_out" | grep -q 'nft_status nf_tables=unknown' \
    || die "读不到内核 config 时应报 nft_status nf_tables=unknown"
rm -rf "$_fx"

# 9) 逐模块加载开关（WebUI「模块」页 + service.sh ko_switch）
#
# 光 grep 代码形状挡不住"把 1 判成 0""畸形行把后面全带崩"这类写反。
# 这里 (a) 静态确认接线齐全；(b) 把 service.sh 的 helper 段抽出来单独 source，
# 用 fixture 跑真值测试 —— 文件缺失/显式 0|1/畸形行/旧开关兼容都要对。
for s in ko_switch DSL_KO_SWITCH ko_switch_val ko_known ko_gate; do
    grep -q "$s" module/service.sh || die "service.sh 缺少 $s"
done
for k in M_KO_OFF_SWITCH M_KO_ON_SWITCH M_KO_OFF_LEGACY M_KO_LKM4CTR_WARN \
         M_KO_OV_ROUTE M_KO_UNKNOWN M_KO_BADVAL M_KO_NOEQ; do
    grep -q "\b$k=" module/i18n.sh || die "i18n.sh 缺少 $k"
    grep -q "$k"    module/service.sh || die "service.sh 未引用 $k"
done
# WebUI 链路：视图 / 页签 / 写入命令 / 语言键
grep -q 'id="view-modules"' module/webroot/index.html || die "WebUI 缺少模块开关视图"
grep -q 'data-target="view-modules"' module/webroot/index.html || die "WebUI 缺少模块页签"
grep -q 'ko_switch' module/webroot/index.js || die "WebUI 未读写 ko_switch"
for lk in tab.modules modules.title modules.apply modules.default modules.on modules.off modules.warnLkm4ctr; do
    grep -q "\"$lk\"" module/webroot/locales/en.json || die "en.json 缺少语言键 $lk"
    grep -q "\"$lk\"" module/webroot/locales/zh.json || die "zh.json 缺少语言键 $lk"
done
# action.sh 也把开关状态摊成机器可读一行
grep -q 'ko_mod' module/action.sh || die "action.sh 缺少 ko_mod 机器可读输出"

# helper 真值测试：抽出 service.sh 的 BEGIN/END_KO_SWITCH_HELPERS 段
# 在一个隔离的 sh 里 source，注入桩 dlog，然后用 fixture 验证判定。
_koh=$(mktemp 2>/dev/null) || die "mktemp 不可用"
awk '/^# BEGIN_KO_SWITCH_HELPERS/{f=1;next} /^# END_KO_SWITCH_HELPERS/{f=0} f' \
    module/service.sh > "$_koh"
[ -s "$_koh" ] || die "抽不出 ko_switch helper（BEGIN/END 标记丢失？）"

_kot=$(mktemp -d 2>/dev/null) || die "mktemp -d 不可用"
# 桩：dlog 吞掉，M_KO_* 给占位，basename 用 coreutils
_dlog_stub='dlog(){ :; }; M_KO_OFF_SWITCH=x; M_KO_ON_SWITCH=x; M_KO_OFF_LEGACY=x; M_KO_OV_ROUTE=x; M_KO_UNKNOWN=x; M_KO_BADVAL=x; M_KO_NOEQ=x'

# 9a) 文件不存在 -> 所有模块走默认（ko_switch_val 返回空，ko_gate 返回 0=加载）
_r=$(DSL_KO_SWITCH="$_kot/absent" sh -c "$_dlog_stub; . '$_koh'; printf '[%s]' \"\$(ko_switch_val macvlan)\"; ko_gate macvlan '' >/dev/null && echo GATE=load || echo GATE=skip" 2>&1)
printf '%s\n' "$_r" | grep -q '\[\]GATE=load' \
    || die "ko_switch 文件缺失时应走默认加载（期望 []GATE=load，得到: $_r）"

# 9b) 显式 0 -> ko_gate 跳过；显式 1 -> 加载
printf '%s\n' 'macvlan=0' 'vkms=1' > "$_kot/switch"
_r=$(DSL_KO_SWITCH="$_kot/switch" sh -c "$_dlog_stub; . '$_koh'; printf 'mv=%s ' \"\$(ko_switch_val macvlan)\"; printf 'vk=%s ' \"\$(ko_switch_val vkms)\"; ko_gate macvlan '' >/dev/null && printf 'A=load ' || printf 'A=skip '; ko_gate vkms '' >/dev/null && printf 'B=load' || printf 'B=skip'" 2>&1)
printf '%s\n' "$_r" | grep -q 'mv=0 vk=1 A=skip B=load' \
    || die "显式 0/1 判定不对（期望 mv=0 vk=1 A=skip B=load，得到: $_r）"

# 9c) 畸形行：无 = 行、非法值、未知模块名 -> 被忽略，合法键仍正确
printf '%s\n' 'oops-no-equals' 'macvlan=maybe' 'frobnicate=1' 'vkms=1' > "$_kot/switch"
_r=$(DSL_KO_SWITCH="$_kot/switch" sh -c "$_dlog_stub; . '$_koh'; printf 'mv=%s vk=%s' \"\$(ko_switch_val macvlan)\" \"\$(ko_switch_val vkms)\"" 2>&1)
printf '%s\n' "$_r" | grep -q 'mv= vk=1' \
    || die "畸形行处理不对：非法 macvlan 值应忽略(空)、合法 vkms=1 应生效（期望 mv= vk=1，得到: $_r）"

# 9d) 旧 disable_* 文件兼容：ko_switch 无该键时，旧文件存在 -> 跳过；
#     ko_switch 显式 1 时，旧文件存在 -> 仍加载（ko_switch 优先）
: > "$_kot/legacy_off"
printf '%s\n' 'droid_lkm_cpu=1' > "$_kot/switch"
_r=$(DSL_KO_SWITCH="$_kot/switch" sh -c "$_dlog_stub; . '$_koh'; ko_gate droid_lkm_pids '$_kot/legacy_off' >/dev/null && printf 'P=load ' || printf 'P=skip '; ko_gate droid_lkm_cpu '$_kot/legacy_off' >/dev/null && printf 'C=load' || printf 'C=skip'" 2>&1)
printf '%s\n' "$_r" | grep -q 'P=skip C=load' \
    || die "旧开关兼容不对：缺键+旧文件应跳过(P=skip)，显式=1应覆盖旧文件(C=load)（期望 P=skip C=load，得到: $_r）"

# 9e) 注释与空行被忽略，不影响合法键
printf '%s\n' '# a comment' '' 'mali_nsfix=0' > "$_kot/switch"
_r=$(DSL_KO_SWITCH="$_kot/switch" sh -c "$_dlog_stub; . '$_koh'; printf '[%s]' \"\$(ko_switch_val mali_nsfix)\"" 2>&1)
printf '%s\n' "$_r" | grep -q '\[0\]' \
    || die "注释/空行应被忽略且不影响合法键（期望 [0]，得到: $_r）"

rm -f "$_koh"
rm -rf "$_kot"

[ "$fail" -eq 0 ] && echo "static-check: all checks passed"
exit "$fail"
