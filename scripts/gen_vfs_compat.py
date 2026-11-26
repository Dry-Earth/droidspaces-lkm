#!/usr/bin/env python3
"""gen_vfs_compat.py - 从 BTF 自动生成符号转发层

背景
====
厂商 GKI 内核会裁掉一部分 EXPORT_SYMBOL，模块静态链接那些函数就装不上。
已有的手工方案（在 glue/ 里逐个写 extern 指针 + 同名转发函数）能工作，但

  * 每遇到一个新符号就要手写一份
  * 手写容易把签名写错（实测踩过：ihold 返回 void 写成了 struct inode *，
    current_umask 返回 int 写成了 umode_t）
  * 不同厂商裁的符号不同，手写清单永远追不上

这个脚本把这件事变成机械操作：给它一份符号名，它从内核 BTF 里取出准确的
原型，生成转发层源码。

用法
====
    # 从 BTF 生成（推荐：BTF 有完整原型）
    python3 gen_vfs_compat.py --btf /sys/kernel/btf/vmlinux \\
        --symbols crypto_register_scomp LZ4_compress_HC \\
        --out glue/gen_vfs_compat.c

    # 从 .ko 的未定义符号自动取（配合白名单过滤）
    python3 gen_vfs_compat.py --btf vmlinux.btf \\
        --from-ko out/mymod.ko --out glue/gen_vfs_compat.c

    # 只列出 BTF 里有/没有的符号，不生成代码
    python3 gen_vfs_compat.py --btf vmlinux.btf --symbols foo bar --check

输出
====
生成的 .c 包含：
  1. 被引用类型的完整定义（从 BTF 生成，不依赖内核头文件）
  2. 每个符号一个函数指针
  3. 每个符号一个同名转发函数（不是 #define —— 宏会改变调用点周围的展开）
  4. vns_gen_symbols[] 解析表，交给调用方用 kallsyms 填充

解析表里每项是 {name, &pointer}，调用方遍历它即可。
"""
import argparse
import struct
import sys

# ---------------------------------------------------------------------------
# BTF 常量
# ---------------------------------------------------------------------------
BTF_KIND_INT = 1
BTF_KIND_PTR = 2
BTF_KIND_ARRAY = 3
BTF_KIND_STRUCT = 4
BTF_KIND_UNION = 5
BTF_KIND_ENUM = 6
BTF_KIND_FWD = 7
BTF_KIND_TYPEDEF = 8
BTF_KIND_VOLATILE = 9
BTF_KIND_CONST = 10
BTF_KIND_RESTRICT = 11
BTF_KIND_FUNC = 12
BTF_KIND_FUNC_PROTO = 13
BTF_KIND_VAR = 14
BTF_KIND_DATASEC = 15
BTF_KIND_FLOAT = 16
BTF_KIND_DECL_TAG = 17
BTF_KIND_TYPE_TAG = 18
BTF_KIND_ENUM64 = 19

# 这些类型不能靠前置声明解决，必须给出完整定义（按值传递/返回）
# 结构体按值传递时也需要完整定义，但 KTF 里这类很少见；先只处理标量
BUILTIN = {
    0: "void", 1: "void",
    # 整数由 BTF_KIND_INT 自身描述，不用表
}


def _is_scalar(btf, tid):
    """返回类型是否可以用 (T)0 强转（标量）。结构体/联合体/数组不行。"""
    seen = 0
    while tid and tid < len(btf.types) and btf.types[tid] and seen < 32:
        t = btf.types[tid]
        k = t["kind"]
        if k == BTF_KIND_INT or k == BTF_KIND_FLOAT:
            return True
        if k == BTF_KIND_PTR:
            return True
        if k == BTF_KIND_ENUM or k == BTF_KIND_ENUM64:
            return True
        if k == BTF_KIND_STRUCT or k == BTF_KIND_UNION:
            return False
        if k == BTF_KIND_ARRAY:
            return False
        if k in (BTF_KIND_TYPEDEF, BTF_KIND_CONST, BTF_KIND_VOLATILE,
                 BTF_KIND_RESTRICT, BTF_KIND_TYPE_TAG):
            tid = t["type"]
            seen += 1
            continue
        return True
    return True


class BTF:
    def __init__(self, path):
        data = open(path, "rb").read()
        magic, ver, flags, hdr_len, type_off, type_len, str_off, str_len = \
            struct.unpack_from("<HBBIIIII", data, 0)
        if magic != 0xEB9F:
            raise SystemExit(f"{path}: bad BTF magic {magic:#x}")

        base = hdr_len
        ts = base + type_off
        ss = base + str_off
        se = ss + str_len

        def get_str(off):
            if off == 0:
                return ""
            a = ss + off
            b = data.index(b"\0", a)
            return data[a:b].decode("utf-8", "replace")

        self.types = [None]
        pos = ts
        end = ts + type_len
        while pos < end:
            name_off, info, sot = struct.unpack_from("<III", data, pos)
            kind = (info >> 24) & 0x1F
            vlen = info & 0xFFFF
            kflag = (info >> 31) & 1
            name = get_str(name_off)
            pos += 12

            extra = 0
            if kind == BTF_KIND_INT:
                extra = 4
            elif kind == BTF_KIND_ARRAY:
                extra = 12
            elif kind in (BTF_KIND_STRUCT, BTF_KIND_UNION):
                extra = 12 * vlen
            elif kind == BTF_KIND_ENUM:
                extra = 8 * vlen
            elif kind == BTF_KIND_ENUM64:
                extra = 12 * vlen
            elif kind == BTF_KIND_FUNC_PROTO:
                extra = 8 * vlen
            elif kind == BTF_KIND_VAR:
                extra = 4
            elif kind == BTF_KIND_DATASEC:
                extra = 12 * vlen
            elif kind == BTF_KIND_DECL_TAG:
                extra = 4

            params = []
            if kind == BTF_KIND_FUNC_PROTO:
                for i in range(vlen):
                    pno, pt = struct.unpack_from("<II", data, pos + i * 8)
                    params.append((get_str(pno), pt))

            members = []
            if kind in (BTF_KIND_STRUCT, BTF_KIND_UNION):
                for i in range(vlen):
                    mno, mt, moff = struct.unpack_from("<III", data, pos + i * 12)
                    members.append((get_str(mno), mt, moff))

            arr = None
            if kind == BTF_KIND_ARRAY:
                arr = struct.unpack_from("<III", data, pos)

            self.types.append({
                "kind": kind, "name": name, "type": sot, "size": sot,
                "vlen": vlen, "kflag": kflag, "params": params,
                "members": members, "arr": arr,
            })
            pos += extra

        self._get_str = get_str
        self.funcs = {}
        for tid, t in enumerate(self.types):
            if t and t["kind"] == BTF_KIND_FUNC:
                self.funcs[t["name"]] = tid

    # -- 类型打印 ----------------------------------------------------------
    def tname(self, tid, decl=""):
        """把 type id 渲染成 C 声明片段，decl 是要声明的变量名。

        返回值形如 "int" / "struct foo *" / "void (*)(int, char *)"。
        decl 不为空时嵌进去，比如 tname(ptr_to_int, "x") -> "int *x"。
        """
        if tid == 0 or tid >= len(self.types) or self.types[tid] is None:
            return f"void {decl}".strip()

        t = self.types[tid]
        k = t["kind"]

        if k == BTF_KIND_INT:
            return f"{t['name'] or 'int'} {decl}".strip()
        if k == BTF_KIND_FLOAT:
            return f"{t['name'] or 'double'} {decl}".strip()
        if k == BTF_KIND_PTR:
            inner = self.tname(t["type"], f"*{decl}" if decl else "*")
            return inner
        if k == BTF_KIND_CONST:
            return "const " + self.tname(t["type"], decl)
        if k == BTF_KIND_VOLATILE:
            return "volatile " + self.tname(t["type"], decl)
        if k == BTF_KIND_RESTRICT:
            return self.tname(t["type"], decl)
        if k == BTF_KIND_TYPE_TAG:
            # BTF 的 type tag 是 __user / __iomem 这类注解，不改 ABI，
            # 也不改 C 声明 —— 直接穿透到内层类型。
            return self.tname(t["type"], decl)
        if k == BTF_KIND_TYPEDEF:
            base = t["name"]
            return f"{base} {decl}".strip()
        if k == BTF_KIND_STRUCT:
            return f"struct {t['name']} {decl}".strip()
        if k == BTF_KIND_UNION:
            return f"union {t['name']} {decl}".strip()
        if k == BTF_KIND_ENUM:
            return f"enum {t['name']} {decl}".strip()
        if k == BTF_KIND_FWD:
            return f"struct {t['name']} {decl}".strip()
        if k == BTF_KIND_ARRAY:
            et, idx, nelem = t["arr"]
            inner = self.tname(et, f"{decl}[{nelem}]" if decl else "[]")
            return inner
        if k == BTF_KIND_FUNC_PROTO:
            ret = self.tname(t["type"], "")
            args = []
            for pname, ptype in t["params"]:
                args.append(self.tname(ptype, pname or ""))
            argstr = ", ".join(a for a in args if a) or "void"
            if decl:
                return f"{ret} (*{decl})({argstr})"
            return f"{ret} (*)({argstr})"
        if k == BTF_KIND_FUNC:
            return self.tname(t["type"], decl)

        return f"void /*kind {k}*/ {decl}".strip()

    # -- 收集引用到的类型，决定要不要前置声明 -------------------------------
    def referenced_types(self, tid, acc=None):
        if acc is None:
            acc = set()
        if tid == 0 or tid >= len(self.types) or self.types[tid] is None:
            return acc
        t = self.types[tid]
        k = t["kind"]
        if k in (BTF_KIND_STRUCT, BTF_KIND_UNION, BTF_KIND_FWD, BTF_KIND_ENUM):
            if t["name"]:
                acc.add((k, t["name"]))
            return acc
        if k == BTF_KIND_PTR:
            return self.referenced_types(t["type"], acc)
        if k in (BTF_KIND_CONST, BTF_KIND_VOLATILE, BTF_KIND_RESTRICT,
                 BTF_KIND_TYPEDEF, BTF_KIND_TYPE_TAG):
            return self.referenced_types(t["type"], acc)
        if k == BTF_KIND_ARRAY:
            return self.referenced_types(t["arr"][0], acc)
        if k == BTF_KIND_FUNC_PROTO:
            self.referenced_types(t["type"], acc)
            for _, pt in t["params"]:
                self.referenced_types(pt, acc)
            return acc
        if k == BTF_KIND_FUNC:
            return self.referenced_types(t["type"], acc)
        return acc

    def func_signature(self, name):
        """返回 (ret_type_id, [(pname, ptype), ...])，找不到返回 None。"""
        tid = self.funcs.get(name)
        if not tid:
            return None
        f = self.types[tid]
        proto = self.types[f["type"]]
        if not proto or proto["kind"] != BTF_KIND_FUNC_PROTO:
            return None
        return proto["type"], proto["params"]


def gen(btf, symbols, header_comment):
    lines = []
    W = lines.append

    W("/* SPDX-License-Identifier: GPL-2.0-only */")
    W("/*")
    for l in header_comment.split("\n"):
        W(" * " + l if l else " *")
    W(" *")
    W(" * GENERATED by gen_vfs_compat.py from BTF -- do not edit by hand.")
    W(" */")
    W("#ifndef _VNS_GEN_VFS_COMPAT_H")
    W("#define _VNS_GEN_VFS_COMPAT_H")
    W("")
    W("/*")
    W(" * 本文件要在内核构建环境里编译：ssize_t / loff_t / dev_t / gfp_t /")
    W(" * umode_t / pid_t 这些基础 typedef 由 <linux/types.h> 及 <linux/kernel.h>")
    W(" * 提供。宿主机 gcc 单测时需要自己补。")
    W(" */")
    W("#include <linux/types.h>")
    W("#include <linux/kernel.h>")
    W("#include <linux/string.h>")
    W("")
    W("#ifndef __nocfi")
    W("#define __nocfi")
    W("#endif")
    W("")

    # 前置声明所有引用到的 struct/union/enum
    fwd = set()
    sigs = {}
    missing = []
    for s in symbols:
        sig = btf.func_signature(s)
        if not sig:
            missing.append(s)
            continue
        sigs[s] = sig
        ret, params = sig
        btf.referenced_types(ret, fwd)
        for _, pt in params:
            btf.referenced_types(pt, fwd)

    if fwd:
        W("/* forward declarations for the types below */")
        for k, n in sorted(fwd):
            tag = {4: "struct", 5: "union", 6: "enum", 7: "struct"}[k]
            W(f"{tag} {n};")
        W("")

    # 指针 + 同名转发函数
    table = []
    needs = set()
    for s in symbols:
        if s not in sigs:
            continue
        ret, params = sigs[s]
        argdecls = []
        argnames = []
        for i, (pname, ptype) in enumerate(params):
            nm = pname or f"a{i}"
            argdecls.append(btf.tname(ptype, nm))
            argnames.append(nm)
        argstr = ", ".join(a for a in argdecls if a) or "void"
        argcall = ", ".join(argnames)
        retdecl = btf.tname(ret, "")

        scalar = _is_scalar(btf, ret)
        W(f"/* {s} */")
        W(f"extern {retdecl} (*vns_p_{s})({argstr});")
        W(f"__nocfi {retdecl} {s}({argstr})")
        W("{")
        if retdecl == "void":
            W(f"\tif (vns_p_{s})")
            W(f"\t\tvns_p_{s}({argcall});")
        elif scalar:
            W(f"\tif (!vns_p_{s})")
            W(f"\t\treturn ({retdecl})0;")
            W(f"\treturn vns_p_{s}({argcall});")
        else:
            # 结构体/联合体按值返回：不能用 (T)0 强转，用 C99 复合字面量
            W(f"\tif (!vns_p_{s})")
            W(f"\t\treturn ({retdecl}){{0}};")
            W(f"\treturn vns_p_{s}({argcall});")
        W("}")
        W("")
        table.append(s)

        # 按值返回或按值传参的 typedef：调用方必须自己提供定义
        for _tid, what in [(ret, "returns")] + [(pt, "takes") for _, pt in params]:
            if _tid and _tid < len(btf.types) and btf.types[_tid] \
               and btf.types[_tid]["kind"] == BTF_KIND_TYPEDEF:
                agg = btf.types[_tid]
                needs.add((agg["name"], s, what))

    if needs:
        W("/*")
        W(" * 下面这些 typedef 按值参与函数签名，本文件只做前置声明。")
        W(" * 调用方必须自己包含提供其定义的头文件（例如 zstd 需要")
        W(" * <linux/zstd.h>），否则编译不过。")
        W(" */")
        for tyname, sym, what in sorted(needs):
            W(f"/*   {tyname}: used by {sym} ({what} it by value) */")
        W("")

    # 解析表
    W("/* 解析表：调用方用 kallsyms 逐个填 vns_p_* 指针 */")
    W("struct vns_gen_sym {")
    W("\tconst char *name;")
    W("\tvoid *slot;")
    W("};")
    W("")
    W("static const struct vns_gen_sym vns_gen_symbols[] = {")
    for s in table:
        W(f'\t{{ "{s}", (void *)&vns_p_{s} }},')
    W("};")
    W(f"#define VNS_GEN_SYMBOL_COUNT {len(table)}")
    W("")
    W("#endif /* _VNS_GEN_VFS_COMPAT_H */")

    return "\n".join(lines), sigs, missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--btf", required=True, help="vmlinux BTF 路径")
    ap.add_argument("--symbols", nargs="*", default=[],
                    help="要生成转发的符号名")
    ap.add_argument("--from-ko", help="从这个 .ko 的未定义符号列表取（需要 nm）")
    ap.add_argument("--out", help="输出 .c 路径；省略则打印到 stdout")
    ap.add_argument("--check", action="store_true",
                    help="只检查符号在 BTF 里有没有，不生成")
    ap.add_argument("--exclude", nargs="*", default=[],
                    help="从 --from-ko 里排除的符号")
    args = ap.parse_args()

    btf = BTF(args.btf)
    print(f"  BTF: {len(btf.types) - 1} 个 type, {len(btf.funcs)} 个函数",
          file=sys.stderr)

    symbols = list(args.symbols)
    if args.from_ko:
        import subprocess
        r = subprocess.run(["nm", "-u", args.from_ko],
                           capture_output=True, text=True)
        got = [ln.split()[-1] for ln in r.stdout.splitlines() if ln.split()]
        symbols += got
        print(f"  {args.from_ko}: {len(got)} 个未定义符号", file=sys.stderr)

    if args.exclude:
        ex = set(args.exclude)
        symbols = [s for s in symbols if s not in ex]

    symbols = list(dict.fromkeys(symbols))  # 去重保序
    if not symbols:
        raise SystemExit("没有符号可处理")

    code, sigs, missing = gen(
        btf, symbols,
        "自动生成的符号转发层。\n"
        "每个符号一个函数指针 + 一个同名转发函数，\n"
        "由 vns_gen_symbols[] 交给 kallsyms 解析。")

    print(f"  可生成: {len(sigs)}   BTF 里没有: {len(missing)}", file=sys.stderr)
    if missing:
        print("  BTF 里没有（需要手工处理）:", file=sys.stderr)
        for m in missing:
            print(f"    - {m}", file=sys.stderr)

    if args.check:
        for s in symbols:
            mark = "✅" if s in sigs else "❌"
            print(f"    {mark} {s}")
        return 0 if not missing else 1

    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as f:
            f.write(code + "\n")
        print(f"  -> {args.out}", file=sys.stderr)
    else:
        print(code)

    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())