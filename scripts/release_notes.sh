#!/bin/sh
# 生成 Release 说明：只列支持的 kernel，功能说明在仓库首页 README。
# 用法: release_notes.sh <dist 目录>
#
# 输出会直接成为 GitHub Release 的正文。GitHub 不按用户语言分发正文，
# 所以英文和中文两段并列输出 —— 英文在前（默认），中文在后。
set -eu

DIST="${1:-dist}"

# ---------------------------------------------------------------------------
# English
# ---------------------------------------------------------------------------
echo '### Supported kernels'
echo ''
echo '| File | Android / kernel |'
echo '|---|---|'

for z in "$DIST"/droidspaces-lkm-*-arm64*.zip; do
    [ -f "$z" ] || continue
    n=$(basename "$z")
    # 不要用 sed 剥前后缀去推 KMI —— 文件名末尾带版本号
    # （droidspaces-lkm-android14-6.1-arm64-v0.1.22-test.13.zip），
    # 剥 "-arm64.zip$" 匹配不上，会得到一串垃圾。
    # KMI 的形态是固定的 androidNN-X.Y，直接正则抓。
    kmi=$(echo "$n" | grep -oE 'android[0-9]+-[0-9]+\.[0-9]+' | head -1)
    [ -n "$kmi" ] || continue
    and=$(echo "$kmi" | sed -e 's/^android//' -e 's/-.*$//')
    kver=$(echo "$kmi" | sed -e 's/^android[0-9]*-//')
    echo "| \`$n\` | Android $and / $kver |"
done

echo ''
echo '| File | Note |'
echo '|---|---|'

for z in "$DIST"/droidspaces-lkm-arm64*.zip; do
    [ -f "$z" ] || continue
    echo "| \`$(basename "$z")\` | All kernels in one package, picks the right one at boot |"
done

echo '| `source-*.tar.gz` | Source snapshot (GPL-2.0) |'

# ---------------------------------------------------------------------------
# 中文
# ---------------------------------------------------------------------------
echo ''
echo '---'
echo ''
echo '### 支持的内核'
echo ''
echo '| 文件 | Android / 内核 |'
echo '|---|---|'

for z in "$DIST"/droidspaces-lkm-*-arm64*.zip; do
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

for z in "$DIST"/droidspaces-lkm-arm64*.zip; do
    [ -f "$z" ] || continue
    echo "| \`$(basename "$z")\` | 全 KMI 合并包，开机自动选择对应的一份 |"
done

echo '| `source-*.tar.gz` | 源码快照（GPL-2.0） |'

cat <<'NOTE'

---

The `.ko` files are not signed. On kernels built with
`CONFIG_MODULE_SIG_FORCE=y` they cannot be inserted at all, and `insmod`
reports `module verification failed`. Check with:

```sh
zcat /proc/config.gz | grep CONFIG_MODULE_SIG_FORCE
```

If a module fails to load, press the **Action** button on the KernelSU module
page and include its output in the issue. It lists every module's load state and
reports which kernel symbols this kernel does not export.
NOTE

cat <<'NOTE'

`.ko` 未签名。内核若编译时开了 `CONFIG_MODULE_SIG_FORCE=y`，这些模块**完全装不上**，
`insmod` 会报 `module verification failed`。确认方式：

```sh
zcat /proc/config.gz | grep CONFIG_MODULE_SIG_FORCE
```

模块装不上时，请点 KernelSU 模块页的**「操作」**按钮，把输出贴进 issue。它会列出
每个模块的加载状态，并报出本内核没有导出哪些符号。
NOTE
