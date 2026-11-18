#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""生成 validation.json —— 产物自证文件。

每个 .ko 记录模块名、KMI、SHA256、大小、vermagic；另记录产出它的 commit
与源码树指纹。目的：用户/维护者拿到一个包，不用翻 git 就能核对
「这个二进制是不是那份源码跑出来的」，也方便 CI 把验证证据留档。

设计借鉴 Shikochin/Droidspaces-LKM 的 validation.json（该仓库把来源与
验证证据一起放进发布 ZIP）。这里保持纯离线：只读文件和 git，不联网。

用法:
    python3 scripts/gen_validation.py --ko-dir <dir> --out validation.json \
            [--commit <sha>] [--source-root <dir>]
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys

SCHEMA = 1
SOURCE_DIRS = ("extra", "module", "scripts", "patches")
KO_RE = re.compile(r"^(?P<mod>.+)-(?P<kmi>android\d+-[\w.\-]+)\.ko$")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def vermagic_of(path):
    """从 .ko 里抠出 vermagic=...，设备侧脚本也是这么做的。"""
    try:
        with open(path, "rb") as f:
            data = f.read(1 << 20)
    except OSError:
        return ""
    m = re.search(rb"vermagic=([^\x00\s]+)", data)
    return m.group(1).decode("utf-8", "replace") if m else ""


def source_fingerprints(root):
    """关键源码目录的整体哈希 + 文件数。

    只取仓库内实际参与构建的部分（extra/module/scripts/patches）。
    逐文件路径 + 内容哈希再汇总，任何一处改动都会体现在 fingerprint 上。
    """
    out = {}
    for name in SOURCE_DIRS:
        d = os.path.join(root, name)
        if not os.path.isdir(d):
            continue
        entries = []
        for dirpath, dirnames, filenames in os.walk(d):
            dirnames[:] = [x for x in dirnames if x != "__pycache__"]
            for fn in sorted(filenames):
                p = os.path.join(dirpath, fn)
                rel = os.path.relpath(p, d).replace(os.sep, "/")
                entries.append((rel, sha256_file(p)))
        h = hashlib.sha256()
        for rel, digest in sorted(entries):
            h.update(rel.encode())
            h.update(bytes.fromhex(digest))
        out[name] = {"files": len(entries), "sha256": h.hexdigest()}
    return out


def git_commit(root):
    try:
        r = subprocess.run(
            ["git", "-C", root, "rev-parse", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
        if r.returncode == 0:
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ko-dir", required=True, help="放 .ko 的目录（可含多个 KMI）")
    ap.add_argument("--out", required=True, help="validation.json 输出路径")
    ap.add_argument("--commit", default="", help="产出对应的 commit；留空则从 git 推断")
    ap.add_argument("--source-root", default=os.getcwd(), help="仓库根，用于源码指纹")
    args = ap.parse_args()

    if not os.path.isdir(args.ko_dir):
        print(f"::error::ko 目录不存在: {args.ko_dir}", file=sys.stderr)
        return 2

    commit = args.commit or git_commit(args.source_root)
    artifacts = []
    for name in sorted(os.listdir(args.ko_dir)):
        if not name.endswith(".ko"):
            continue
        path = os.path.join(args.ko_dir, name)
        if not os.path.isfile(path):
            continue
        m = KO_RE.match(name)
        if m:
            mod, kmi = m.group("mod"), m.group("kmi")
        else:
            mod, kmi = name[:-3], "unknown"
        artifacts.append({
            "file": name,
            "module": mod,
            "kmi": kmi,
            "size": os.path.getsize(path),
            "sha256": sha256_file(path),
            "vermagic": vermagic_of(path),
        })

    if not artifacts:
        print("::warning::目录里没有 .ko，validation.json 只记录来源信息")

    doc = {
        "schema": SCHEMA,
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "commit": commit,
        "artifacts": artifacts,
        "sources": source_fingerprints(args.source_root),
    }

    out_dir = os.path.dirname(os.path.abspath(args.out))
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    tmp = args.out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, args.out)

    print(f"validation.json: {len(artifacts)} 个产物, commit={commit or 'unknown'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
