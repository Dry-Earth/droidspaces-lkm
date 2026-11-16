#!/bin/sh
# 生成 Release 正文。
#
# 格式参考 KernelSU 的 release（v3.3.1）：
#
#     vX.Y.Z                          <- 标题只有版本号
#
#     ## What's Changed
#     * 条目
#     * 条目
#
#     ## Supported kernels
#     | 表格 |
#
#     **Full Changelog**: https://.../compare/vPREV...vCUR
#
# 与原格式的差别：标题不再带项目名和 (preview)；小节标题用 "What's Changed"；
# 列表符号统一用 "*"；结尾补 compare 链接。中文段落放在英文之后（GitHub 不按
# 语言分发正文，所以两段并列，英文在前）。
#
# 用法: release_notes.sh <dist 目录> [仓库 root]
set -eu

DIST="${1:-dist}"
ROOT="${2:-.}"

REPO_SLUG="${REPO_SLUG:-misaka5202/droidspaces-lkm}"
PKG_PREFIX="${PKG_PREFIX:-droidspaces-lkm}"
MODULE_TITLE="${MODULE_TITLE:-Droidspaces LKM}"

# ---------------------------------------------------------------------------
# 版本号：从 zip 文件名里取
#
# 不从 git tag 取 —— 这个脚本 ci.yml 也会调用（没有 tag），而 zip 名字一定
# 带版本号，是这里唯一可靠的来源。
# ---------------------------------------------------------------------------
VER=""
for z in "$DIST"/"$PKG_PREFIX"-arm64-*.zip; do
    [ -f "$z" ] || continue
    VER=$(basename "$z" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$VER" ] && break
done

# ---------------------------------------------------------------------------
# 上一个版本：从 CHANGELOG 里当前版本之后的下一个 "## vX.Y.Z" 取
# ---------------------------------------------------------------------------
PREV=""
# 从 CHANGELOG.md（中文，含完整历史）取，不用 CHANGELOG.en.md ——
# 英文版只从 v0.1.23 开始写，没有更早的标题可供回溯。
if [ -n "$VER" ] && [ -f "$ROOT/docs/CHANGELOG.md" ]; then
    PREV=$(awk -v v="$VER" '
        found && /^## v[0-9]/ {
            line = $0
            sub(/^## +/, "", line)        # 去掉 "## "
            sub(/^v/, "", line)           # 去掉开头的 v
            sub(/[^0-9.].*$/, "", line)   # 截到第一个非数字/点的字符
            sub(/[.]+$/, "", line)        # 去掉尾部多余的句点
            if (line != "") { print "v" line; exit }
        }
        $0 ~ "^## " v "([[:space:]]|$)" { found = 1 }
    ' "$ROOT/docs/CHANGELOG.md")
fi

# ---------------------------------------------------------------------------
# 从 CHANGELOG 里切出指定版本条目（跳过 "## vX.Y.Z" 标题行）
# 输出时把小节标题和列表符号转成 KernelSU 风格：
#   "### 修复" / "### Fixed"  ->  "### Fixed"
#   "- 条目"                  ->  "* 条目"
# ---------------------------------------------------------------------------
list_items() {
    _f=$1; _v=$2
    [ -f "$_f" ] || return 0
    awk -v v="$_v" '
        !started && $0 ~ "^## " v "([[:space:]]|$)" { started = 1; next }
        started && /^## / { exit }
        !started { next }
        /^---[[:space:]]*$/ { next }
        /^- / { sub(/^- /, "* "); print; next }
        { print }
    ' "$_f" | cat -s
}

# 中文条目里的小节标题翻成英文，避免正文出现两套标题体系
zh_to_en_headers() {
    sed -e 's/^### 修复$/### Fixed/' \
        -e 's/^### 新增$/### Added/' \
        -e 's/^### 变更$/### Changed/' \
        -e 's/^### 版本变体$/### Version variants/' \
        -e 's/^### 验证$/### Verification/' \
        -e 's/^### 已知问题$/### Known issues/'
}

# ---------------------------------------------------------------------------
# 正文
# ---------------------------------------------------------------------------
if [ -n "$VER" ]; then
    echo "$VER"
    echo ''
    echo "## What's Changed"
    echo ''
    list_items "$ROOT/docs/CHANGELOG.en.md" "$VER"
    echo ''
else
    echo "$MODULE_TITLE"
    echo ''
fi

echo '## Supported kernels'
echo ''
echo '| File | Android / kernel |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-*-arm64*.zip; do
    [ -f "$z" ] || continue
    n=$(basename "$z")
    # 不要用 sed 剥前后缀去推 KMI —— 文件名末尾带版本号。KMI 的形态固定是
    # androidNN-X.Y，直接正则抓。
    kmi=$(echo "$n" | grep -oE 'android[0-9]+-[0-9]+\.[0-9]+' | head -1)
    [ -n "$kmi" ] || continue
    and=$(echo "$kmi" | sed -e 's/^android//' -e 's/-.*$//')
    kver=$(echo "$kmi" | sed -e 's/^android[0-9]*-//')
    echo "| \`$n\` | Android $and / $kver |"
done

echo ''
echo '| File | Note |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-arm64*.zip; do
    [ -f "$z" ] || continue
    echo "| \`$(basename "$z")\` | All kernels in one package, picks the right one at boot |"
done

echo '| `source-*.tar.gz` | Source snapshot (GPL-2.0) |'

cat <<'NOTE'

The `.ko` files are not signed. On kernels built with
`CONFIG_MODULE_SIG_FORCE=y` they cannot be inserted at all, and `insmod`
reports `module verification failed`. Check with:

```sh
zcat /proc/config.gz | grep CONFIG_MODULE_SIG_FORCE
```

If a module fails to load, press the **Action** button on the KernelSU module
page and include its output in the issue.
NOTE

# ---------------------------------------------------------------------------
# 中文
# ---------------------------------------------------------------------------
if [ -n "$VER" ]; then
    echo ''
    echo '---'
    echo ''
    echo "## 变更内容"
    echo ''
    list_items "$ROOT/docs/CHANGELOG.md" "$VER" | zh_to_en_headers
    echo ''
fi

echo ''
echo '## 支持的内核'
echo ''
echo '| 文件 | Android / 内核 |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-*-arm64*.zip; do
    [ -f "$z" ] || continue
    n=$(basename "$z")
    kmi=$(echo "$n" | grep -oE 'android[0-9]+-[0-9]+\.[0-9]+' | head -1)
    [ -n "$kmi" ] || continue
    and=$(echo "$kmi" | sed -e 's/^android//' -e 's/-.*$//')
    kver=$(echo "$kmi" | sed -e 's/^android[0-9]*-//')
    echo "| \`$n\` | Android $and / $kver |"
done

echo ''
echo '| 文件 | 说明 |'
echo '|---|---|'

for z in "$DIST"/"$PKG_PREFIX"-arm64*.zip; do
    [ -f "$z" ] || continue
    echo "| \`$(basename "$z")\` | 全 KMI 合并包，开机自动选择对应的一份 |"
done

echo '| `source-*.tar.gz` | 源码快照（GPL-2.0） |'

cat <<'NOTE'

`.ko` 未签名。内核若编译时开了 `CONFIG_MODULE_SIG_FORCE=y`，这些模块**完全装不上**，
`insmod` 会报 `module verification failed`。确认方式：

```sh
zcat /proc/config.gz | grep CONFIG_MODULE_SIG_FORCE
```

模块装不上时，请点 KernelSU 模块页的**「操作」**按钮，把输出贴进 issue。
NOTE

# ---------------------------------------------------------------------------
# 结尾：Full Changelog（KernelSU 格式）
# ---------------------------------------------------------------------------
if [ -n "$VER" ]; then
    echo ''
    if [ -n "$PREV" ]; then
        echo "**Full Changelog**: https://github.com/$REPO_SLUG/compare/$PREV...$VER"
    else
        echo "**Full Changelog**: https://github.com/$REPO_SLUG/commits/$VER"
    fi
fi
