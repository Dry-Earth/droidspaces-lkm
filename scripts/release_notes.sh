#!/bin/sh
# 生成 Release 正文 —— Keep-a-Changelog 风格，与 v0.1.27 的 release 页一致：
#
#     # Changelog
#
#     ## <X.Y.Z> - <YYYY-MM-DD>
#
#     <docs/CHANGELOG.en.md 中该版本的条目原文（### 分节）>
#
#     ---
#
#     Full history: [docs/CHANGELOG.en.md](<permalink>)
#
# 条目来自 docs/CHANGELOG.en.md 的 "## <X.Y.Z> - <date>" 节，原样输出——
# 正文即 CHANGELOG，不再维护第二套说法。
#
# 用法: release_notes.sh <dist 目录> [仓库 root]
set -eu

# 去掉条目首尾的空行（cat -s 只能压缩中间的连续空行）
trim() {
    awk 'NF && !started { started = 1 }
         started        { buf[++n] = $0 }
         NF             { last = n }
         END { for (i = 1; i <= last; i++) print buf[i] }'
}

DIST="${1:-dist}"
ROOT="${2:-.}"

REPO_SLUG="${REPO_SLUG:-misaka5202/droidspaces-lkm}"
PKG_PREFIX="${PKG_PREFIX:-droidspaces-lkm}"

# ---------------------------------------------------------------------------
# 版本号：从 zip 文件名里取
#
# 不从 git tag 取 —— zip 名字一定带版本号，是这里唯一可靠的来源。
# ---------------------------------------------------------------------------
VER=""
for z in "$DIST"/"$PKG_PREFIX"-arm64-*.zip; do
    [ -f "$z" ] || continue
    VER=$(basename "$z" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$VER" ] && break
done
[ -n "$VER" ] || { echo "::error::dist 里没有 $PKG_PREFIX-arm64-v*.zip，取不到版本号" >&2; exit 1; }

EN="$ROOT/docs/CHANGELOG.en.md"
[ -f "$EN" ] || { echo "::error::缺少 $EN" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 切当前版本条目：从 "## <X.Y.Z> - " 标题行开始，到下一个 "## " 前结束。
# 标题行本身保留——它就是 "## <版本> - <日期>" 这一节。
# ---------------------------------------------------------------------------
ENTRY=$(awk -v v="${VER#v}" '
    $0 ~ "^## " v " - " { found = 1 }
    found && /^## / && $0 !~ "^## " v " - " { exit }
    found { print }
' "$EN" | cat -s | trim)

[ -n "$ENTRY" ] || {
    echo "::error::$EN 里没有 $VER 的条目（标题形如 \"## ${VER#v} - YYYY-MM-DD\"）" >&2
    exit 1
}

echo '# Changelog'
echo
echo "$ENTRY"
echo
echo '---'
echo
echo "Full history: [docs/CHANGELOG.en.md](https://github.com/$REPO_SLUG/blob/master/docs/CHANGELOG.en.md)"
