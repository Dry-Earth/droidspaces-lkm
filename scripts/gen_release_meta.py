#!/usr/bin/env python3
"""gen_release_meta.py - 发布后自动生成 update.json 与 CHANGELOG-latest.md

为什么需要
==========
KernelSU 的更新弹窗读两样东西：

  1. module.prop 里的 updateJson URL -> 那个 JSON 的 versionCode / zipUrl
  2. 同一个 JSON 的 changelog URL     -> 那段文本

手工维护这两处出过两次错：

  * versionCode 位数不一致。build.yml 用 `date +%Y%m%d%H%M` 写进包里（12 位，
    如 202611170004），而 update.json 里手写的是 10 位（2026111700）。数值比较
    20 亿 < 2026 亿，KernelSU 判定「已安装版本更新」，永远不提示。
  * changelog 指向整个 CHANGELOG.md（64 KB，含全部历史版本），弹窗里是一堵墙。

这个脚本把两者都从**构建产物**里取，不再手写：

  versionCode  <- dist/version-code.txt（build.yml 打包时写入，与包内完全一致）
  version      <- tag
  zipUrl       <- 由 tag 拼出（资产名固定在 build.yml 里）
  changelog    <- 从 CHANGELOG.md / CHANGELOG.en.md 切出 tag 对应那一段

用法
====
    python3 scripts/gen_release_meta.py --version v0.1.23 --dist dist

在仓库根目录运行。会就地改写 update.json 和 docs/CHANGELOG-latest.md。
"""

import argparse
import json
import re
import sys
from pathlib import Path

REPO = "misaka5202/droidspaces-lkm"
BRANCH = "master"
PACKAGE_PREFIX = "droidspaces-lkm-arm64"


def extract_entry(changelog: Path, version: str) -> str:
    """从 CHANGELOG 里切出 `## <version>` 到下一个 `## ` 之前的内容。"""
    if not changelog.exists():
        return ""
    text = changelog.read_text(encoding="utf-8", errors="replace")
    lines = text.split("\n")

    # 标题形状有两种，两份 changelog 各用一种：
    #   docs/CHANGELOG.md     -> "## v0.1.28"        （带 v）
    #   docs/CHANGELOG.en.md  -> "## 0.1.28 - 2026-11-20"（不带 v，带日期）
    #
    # 原来只按传入的 version 原样匹配，于是 --version v0.1.28 在英文那份上
    # 永远匹配不到 —— update.json 指向的 CHANGELOG-latest.md 会静默丢掉
    # 整段英文，KernelSU 更新弹窗只剩中文。带不带 v 都要试。
    bare = version[1:] if version.startswith("v") else version
    patterns = [rf"^##\s+{re.escape(v)}(\s|$|—|-)"
                for v in dict.fromkeys([version, bare, "v" + bare])]

    start = None
    for i, line in enumerate(lines):
        if any(re.match(p, line) for p in patterns):
            start = i
            break
    if start is None:
        return ""

    end = len(lines)
    for i in range(start + 1, len(lines)):
        if lines[i].startswith("## "):
            end = i
            break

    entry = "\n".join(lines[start:end]).rstrip()
    # 去掉结尾的分隔线和“完整记录见 ...”之类的指路语
    entry = re.sub(r"\n---\s*\n.*$", "", entry, flags=re.S)
    return entry.rstrip()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--version", required=True,
                    help="发布 tag，例如 v0.1.23")
    ap.add_argument("--dist", type=Path, default=Path("dist"),
                    help="构建产物目录，需含 version-code.txt")
    ap.add_argument("--repo-root", type=Path, default=Path("."))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    root = args.repo_root.resolve()
    version = args.version

    # ---- versionCode：必须与包内那个完全一致 ----
    vc_file = args.dist / "version-code.txt"
    if not vc_file.exists():
        sys.exit(f"  找不到 {vc_file}。build.yml 打包时应写入它；"
                 f"没有这个文件就无法保证 update.json 与包内 versionCode 一致。")
    raw = vc_file.read_text(encoding="utf-8", errors="replace").strip()
    if not re.fullmatch(r"\d{8,14}", raw):
        sys.exit(f"  {vc_file} 内容不是纯数字时间戳: {raw!r}")
    version_code = int(raw)

    # KernelSU 的 Module.kt 把 versionCode 声明成 Kotlin Int，Downloader.kt
    # 用 .toInt() 解析。超过 Integer.MAX_VALUE 时 .toInt() 抛
    # NumberFormatException，更新检查整个失败 —— 表现为「永远收不到更新」。
    # zram-lkm 用 8 位（20261119）所以正常；本仓库曾用 12 位
    # （202611170004）所以从来没工作过。
    INT32_MAX = 2**31 - 1
    if version_code > INT32_MAX:
        sys.exit(f"  versionCode {raw} = {version_code:,} 超出 int32 "
                 f"(Integer.MAX_VALUE = {INT32_MAX:,})。"
                 f"KernelSU 的 .toInt() 会抛 NumberFormatException，"
                 f"更新检查会完全失败。build.yml 应生成 YYYYMMDDnn 形式。")
    if version_code <= 0:
        sys.exit(f"  versionCode 必须为正数，实际 {version_code}")

    # ---- changelog：中英合并 ----
    zh = extract_entry(root / "docs" / "CHANGELOG.md", version)
    en = extract_entry(root / "docs" / "CHANGELOG.en.md", version)

    if not zh and not en:
        sys.exit(f"  CHANGELOG.md 和 CHANGELOG.en.md 里都找不到 {version} 的条目。"
                 f"发版前先补 changelog。")

    parts = []
    if zh:
        parts.append(zh)
    if en:
        parts.append("---\n\n" + en)
    latest = "\n\n".join(parts) + "\n"

    # ---- update.json ----
    manifest = {
        "version": version,
        "versionCode": version_code,
        "zipUrl": f"https://github.com/{REPO}/releases/download/{version}/"
                  f"{PACKAGE_PREFIX}-{version}.zip",
        "changelog": f"https://raw.githubusercontent.com/{REPO}/{BRANCH}/"
                     f"docs/CHANGELOG-latest.md",
    }

    latest_path = root / "docs" / "CHANGELOG-latest.md"
    manifest_path = root / "update.json"

    print(f"  version      = {version}")
    print(f"  versionCode  = {version_code}")
    print(f"  zipUrl       = {manifest['zipUrl']}")
    print(f"  changelog    = {manifest['changelog']}")
    print(f"  CHANGELOG-latest.md  {len(latest.encode())} 字节  "
          f"(中文 {'有' if zh else '无'} / 英文 {'有' if en else '无'})")

    if args.dry_run:
        print("  --dry-run，不写文件")
        return 0

    latest_path.write_text(latest, encoding="utf-8", newline="\n")
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8", newline="\n")
    print(f"  已写入 {latest_path.name} 和 {manifest_path.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
