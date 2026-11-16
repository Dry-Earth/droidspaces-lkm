#!/bin/sh
# 生成 Release 说明：只列支持的 kernel，功能说明在仓库首页 README。
# 用法: release_notes.sh <dist 目录>
set -eu

DIST="${1:-dist}"

echo 'Supported kernels'
echo ''
echo '| File | Android / kernel |'
echo '|---|---|'

for z in "$DIST"/droidspaces-lkm-*-arm64*.zip; do
    [ -f "$z" ] || continue
    n=$(basename "$z")
    # 不要用 sed 剥前后缀去推 KMI —— 文件名末尾现在带版本号
    # （droidspaces-lkm-android14-6.1-arm64-v0.1.22-test.13.zip），
    # 剥 "-arm64.zip$" 匹配不上，会得到一串垃圾。
    # KMI 的形态是固定的 androidNN-X.Y，直接正则抓。
    kmi=$(echo "$n" | grep -oE 'android[0-9]+-[0-9]+\.[0-9]+' | head -1)
    [ -n "$kmi" ] || continue
    # android14-6.1 -> 14 / 6.1
    and=$(echo "$kmi" | sed -e 's/^android//' -e 's/-.*$//')
    kver=$(echo "$kmi" | sed -e 's/^android[0-9]*-//')
    echo "| \`$n\` | Android $and / $kver |"
done

echo ''
echo '| File | Note |'
echo '|---|---|'

# 合并包的名字里带版本，别硬编码。glob 一下按实际产物写。
for z in "$DIST"/droidspaces-lkm-arm64*.zip; do
    [ -f "$z" ] || continue
    echo "| \`$(basename "$z")\` | All kernels in one package, picks the right one at boot |"
done

echo '| `source-*.tar.gz` | Source snapshot (GPL-2.0) |'

# 重要：说明当前默认后端，避免用户以为出了问题
cat <<'NOTE'

NOTE