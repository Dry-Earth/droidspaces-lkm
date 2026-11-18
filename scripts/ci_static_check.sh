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

[ "$fail" -eq 0 ] && echo "static-check: all checks passed"
exit "$fail"
