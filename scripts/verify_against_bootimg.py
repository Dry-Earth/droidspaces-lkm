#!/usr/bin/env python3
"""verify_against_bootimg.py - 用用户的 boot.img 验证模块能不能装上

背景
====
issue #2 的报告者说 v0.1.22「Looks like not working」，但只给了 action log
（里面通常看不出缺哪个符号）。他又提供了 boot.img —— 那里面有这台内核的
完整导出表，直接比对就知道缺什么。

这个脚本把那次手工分析固化下来：

    boot.img -> kernel -> __ksymtab_strings -> 导出符号集合
                                              |
    每个 .ko 的 nm -u  ---------------------> 缺哪些符号

用法
====
    # 只提取导出表
    python3 scripts/verify_against_bootimg.py --bootimg boot.img --dump exports.txt

    # 验证一批 .ko
    python3 scripts/verify_against_bootimg.py --bootimg boot.img --kos out/ko-android14-6.1

    # 已经提取过导出表时跳过 boot.img 解析
    python3 scripts/verify_against_bootimg.py --exports exports.txt --kos out/ko-xxx

要点
====
* 只认 __ksymtab_strings，不是 kallsyms。后者含**全部**符号（包括未导出的），
  拿它比对会误判「这个符号存在」。

* kallsyms_names 比 __ksymtab_strings 更密，所以不能简单取「最密集窗口」。
  按密度从高到低逐个试，只有 sanity check 通过的才算。

* sanity check：_printk 必须在（注意不是 printk —— 那是宏），
  kallsyms_lookup_name 必须不在。不通过就拒绝输出，错误的结论比没有结论更糟。

已知局限
========
* 只处理未压缩或 gzip 压缩的 Image。xz/zstd 会明确报错而不是猜。
"""

import argparse
import gzip
import struct
import subprocess
import sys
from pathlib import Path

PAGE_SIZES = (4096, 2048, 16384)
ARM64_NOP = b"\x1f\x20\x03\xd5"
NUL = bytes([0])

MUST_BE_EXPORTED = ("_printk", "kfree", "memset", "memcpy", "schedule", "register_kprobe")
MUST_NOT_BE_EXPORTED = ("kallsyms_lookup_name",)


def is_ident(s):
    return 3 < len(s) < 60 and all(48 <= c <= 122 or c == 95 for c in s)


def extract_kernel(bootimg):
    data = bootimg.read_bytes()
    if data[:8] != b"ANDROID!":
        sys.exit("%s: 不是 Android bootimg（magic 不对）" % bootimg)
    kernel_size = struct.unpack("<I", data[8:12])[0]
    header_size = struct.unpack("<I", data[20:24])[0]
    header_ver = struct.unpack("<I", data[40:44])[0]
    print("  bootimg: kernel_size=%d header_size=%d v%d" % (kernel_size, header_size, header_ver))
    for page in PAGE_SIZES:
        off = (header_size + page - 1) // page * page
        head = data[off:off + 4]
        if head == ARM64_NOP[:4]:
            print("  kernel @ %#x（页 %d，未压缩 ARM64）" % (off, page))
            return data[off:off + kernel_size]
        if head[:2] == b"\x1f\x8b":
            print("  kernel @ %#x（页 %d，gzip）" % (off, page))
            return gzip.decompress(data[off:off + kernel_size])
        if head[:4] in (b"\xfd7zXZ", b"\x28\xb5\x2f"):
            sys.exit("  kernel @ %#x 是 xz/zstd，本脚本不处理（请先解压）" % off)
    sys.exit("  找不到可识别的 kernel 载荷")


def find_exports(img):
    win = 0x10000
    dens = []
    for off in range(0, len(img) - win, win):
        seg = img[off:off + win]
        dens.append((off, sum(1 for t in seg.split(NUL) if is_ident(t))))
    dens.sort(key=lambda x: -x[1])
    if not dens:
        sys.exit("  Image 太小")

    def expand(center):
        lo = hi = center
        while lo > 0:
            seg = img[lo - win:lo]
            if sum(1 for t in seg.split(NUL) if is_ident(t)) < 100:
                break
            lo -= win
        while hi < len(img) - win:
            seg = img[hi:hi + win]
            if sum(1 for t in seg.split(NUL) if is_ident(t)) < 100:
                break
            hi += win
        return lo, hi

    def names_in(lo, hi):
        out = set()
        for t in img[lo:hi].split(NUL):
            if 1 < len(t) < 100 and all(32 <= c < 127 for c in t):
                out.add(t.decode("ascii"))
        return out

    tried = 0
    for center, _d in dens[:40]:
        lo, hi = expand(center)
        exported = names_in(lo, hi)
        tried += 1
        bad = [t for t in MUST_BE_EXPORTED if t not in exported]
        wrong = [t for t in MUST_NOT_BE_EXPORTED if t in exported]
        if bad or wrong:
            if tried <= 3:
                why = []
                if bad:
                    why.append("缺 " + str(bad[:2]))
                if wrong:
                    why.append("多出 " + str(wrong[:2]))
                print("  跳过 %#x-%#x（%d 个符号）: %s" % (lo, hi, len(exported), "; ".join(why)))
            continue
        print("  __ksymtab_strings 区间 %#x-%#x，%d 个符号" % (lo, hi, len(exported)))
        print("  OK sanity check 通过（_printk/kfree 在，kallsyms_lookup_name 不在）")
        return exported

    sys.exit("  试了 %d 个候选区间都不满足 sanity check —— 拒绝给出可能错误的结论" % tried)



def _kmi_of(name):
    """从目录名里抠出 androidNN-X.Y。"""
    import re as _re
    m = _re.search(r"(android\d+-\d+\.\d+)", name)
    return m.group(1) if m else None


def nm_undefined(ko):
    for tool in ("nm", "llvm-nm"):
        try:
            out = subprocess.run([tool, "-u", str(ko)], capture_output=True, text=True)
        except FileNotFoundError:
            continue
        if out.returncode != 0:
            continue
        syms = []
        for line in out.stdout.split("\n"):
            parts = line.split()
            if len(parts) >= 2 and parts[0] == "U":
                syms.append(parts[1])
        return syms
    sys.exit("  找不到可用的 nm/llvm-nm")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bootimg", type=Path)
    ap.add_argument("--exports", type=Path)
    ap.add_argument("--dump", type=Path)
    ap.add_argument("--kos", type=Path, action="append")
    ap.add_argument("--kmi", help="这台内核的 KMI，例如 android14-6.1；"
                                  "给了就检查 .ko 目录是否匹配，不匹配会警告"
                                  "（否则 5.10 的模块对 6.1 内核会报一堆假缺失）")
    args = ap.parse_args()

    if not args.bootimg and not args.exports:
        ap.error("至少给 --bootimg 或 --exports")

    if args.exports:
        print("  读导出表: %s" % args.exports)
        exported = set(args.exports.read_text(encoding="utf-8").split("\n")) - {""}
        print("  %d 个符号" % len(exported))
    else:
        print("  解析 %s" % args.bootimg)
        img = extract_kernel(args.bootimg)
        exported = find_exports(img)
        if args.dump:
            args.dump.write_text("\n".join(sorted(exported)), encoding="utf-8")
            print("  导出表已写入 %s" % args.dump)

    if not args.kos:
        return 0

    kver_hint = args.kmi

    # 模块文件名带 KMI（androidNN-X.Y）；如果和这台内核的 KMI 不一致，
    # 得到的「缺失」全是假阳性 —— 5.10 的模块本来就不可能匹配 6.1 的内核。
    # 这里从 bootimg 的 kernel 里推断不出 KMI，所以只在目录名带 KMI 时提示。
    total = 0
    skipped = 0
    print()
    for d in args.kos:
        print("  === %s ===" % d.name)
        for ko in sorted(d.glob("*.ko")):
            # 每个 .ko 的文件名带自己的 KMI。用别的 KMI 的模块去比对这台内核，
            # 得到的「缺失」全是版本不匹配的假阳性 —— 必须跳过而不是误报。
            ko_kmi = _kmi_of(ko.name)
            if kver_hint and ko_kmi and ko_kmi != kver_hint:
                skipped += 1
                print("    --  %-46s （%s，和内核 %s 不匹配，跳过）" %
                      (ko.name, ko_kmi, kver_hint))
                continue
            und = [s for s in nm_undefined(ko) if not s.startswith("vns_")]
            missing = [s for s in und if s not in exported]
            total += len(missing)
            print("    %s %-46s %4d 未定义 / %d 缺" %
                  ("OK " if not missing else "BAD", ko.name, len(und), len(missing)))
            for m in missing:
                print("         %s" % m)

    print()
    if skipped:
        print("  跳过 %d 个 KMI 不匹配的模块（比对它们只会得到假阳性）" % skipped)
    if total:
        print("  %d 个符号缺失 —— 这些模块在这台内核上装不上" % total)
        return 1
    print("  OK 全部同 KMI 的模块都能在这台内核上装上")
    return 0


if __name__ == "__main__":
    sys.exit(main())
