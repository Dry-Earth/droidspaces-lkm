#!/usr/bin/env python3
"""把 vkms 对 DEBUG_FS 专属 drm 符号的依赖去掉。

为什么需要
----------
`drivers/gpu/drm/Makefile` 里：

    drm-$(CONFIG_DEBUG_FS) += drm_debugfs.o drm_debugfs_crc.o

也就是说 `drm_debugfs_create_files()` 和 `drm_crtc_add_crc_entry()` **只在
CONFIG_DEBUG_FS=y 的内核里存在**。GKI 的 gki_defconfig 没有显式打开 DEBUG_FS
（它没有默认值），所以相当一部分真机是 n —— 那些内核里这两个符号压根不存在，
vkms 直接 "Unknown symbol" 装不上。GKI 的 CONFIG_DRM=y 是编进内核的，所以
这和 drm 加载时序无关。

不同内核版本的 vkms 用的地方不一样：

    5.10     vkms_composer.c 里 CRC 上报一处；没有 debugfs 配置展示
    5.15+    vkms_composer.c 里 CRC 上报 + vkms_drv.c 里 debugfs 配置展示

所以每个补丁点都按"**这个版本用不用这个符号**"来判断：
  - 文件里没有这个符号        -> 无事可做，算成功
  - 有符号且调用点形状匹配    -> 替换掉
  - 有符号但形状不匹配        -> 失败（返回非 0，让构建脚本跳过出货）
    这一条很重要：宁可不出货，也不要出一个"编过了但装不上"的 vkms。

两处都是纯调试功能：CRC 是给 igt 之类的工具用的，debugfs 是把 vkms 配置
打到 debugfs 里。容器要的是 /dev/dri/renderD128 这个 render node，和它们无关。

第三处（drmm_crtc_init_with_planes）
-----------------------------------
6.12 的小米系内核（issue #3 K90PM / #4 一加15）没导出这个符号，vkms 直接装不上。
换成 `drm_crtc_init_with_planes`：

  * 两者签名**完全相同**（都是 variadic：... funcs, const char *name, ...），
    上游 6.12 的 drm_crtc.c 里两个都是 EXPORT_SYMBOL，是 drop-in 替换；
  * 语义差异只有清理方式 —— drmm_ 版注册 devres 自动清理，非 drmm 版依赖
    调用方。而 vkms 的 CRTC 挂在 drm_mode_config 的 crtc_list 上，
    drm_mode_config_cleanup() 会统一调 drm_crtc_cleanup()，所以不会泄漏；
  * 厂商裁的通常是较新的 drmm_ 那个，老的非 drmm 版基本都还导着。
"""

import sys as _sys
from pathlib import Path as _Path
_sys.path.insert(0, str(_Path(__file__).resolve().parent))
from i18n import t  # noqa: E402

import re
import sys
import pathlib

COMPOSER = "vkms_composer.c"
DRV = "vkms_drv.c"

CRC_SYM = "drm_crtc_add_crc_entry"
DBG_SYM = "drm_debugfs_create_files"


def patch_composer(root: pathlib.Path) -> bool:
    p = root / COMPOSER
    if not p.exists():
        print(t("file_missing", name=COMPOSER))
        return True

    s = p.read_text(encoding="utf-8", errors="replace")
    if "VKMS_CRC_DISABLED" in s:
        print(t("already_patched", name=COMPOSER))
        return True
    if CRC_SYM not in s:
        print(t("sym_unused", name=COMPOSER, sym=CRC_SYM))
        return True

    old = ("\twhile (frame_start <= frame_end)\n"
           f"\t\t{CRC_SYM}(crtc, true, frame_start++, &crc32);")
    new = """	/*
	 * [VKMS_CRC_DISABLED] drm_crtc_add_crc_entry() 由 drm_debugfs_crc.o
	 * 提供，那个文件只在 CONFIG_DEBUG_FS=y 时编译。真机常为 n，符号
	 * 不存在会让整个 vkms 装不上。CRC 只给调试工具用，这里去掉上报，
	 * 保留计数让变量仍被使用。
	 */
	while (frame_start <= frame_end)
		frame_start++;"""

    if old not in s:
        # 兜底：把包含该符号的那一行整行换成计数自增，缩进沿用原行
        pat = re.compile(r"^(\s*)" + re.escape(CRC_SYM) + r"\(.*$", re.M)
        m = pat.search(s)
        if not m:
            print(t("crc_no_callsite", name=COMPOSER, sym=CRC_SYM))
            return False
        s = pat.sub(
            lambda mm: (mm.group(1) + "/* [VKMS_CRC_DISABLED] 见 patch_vkms_debugfs.py */\n"
                        + mm.group(1) + "frame_start++;"), s, count=1)
    else:
        s = s.replace(old, new, 1)

    p.write_text(s, encoding="utf-8", newline="\n")
    print(t("crc_removed", name=COMPOSER))
    return True


def patch_drv(root: pathlib.Path) -> bool:
    p = root / DRV
    if not p.exists():
        print(t("file_missing", name=DRV))
        return True

    s = p.read_text(encoding="utf-8", errors="replace")
    if "VKMS_DEBUGFS_DISABLED" in s:
        print(t("already_patched", name=DRV))
        return True
    if DBG_SYM not in s:
        print(t("sym_unused", name=DRV, sym=DBG_SYM))
        return True

    old = (f"\tdrm_debugfs_create_files(vkms_config_debugfs_list, ARRAY_SIZE(vkms_config_debugfs_list),\n"
           "\t\t\t\t minor->debugfs_root, minor);")
    new = """	/*
	 * [VKMS_DEBUGFS_DISABLED] drm_debugfs_create_files() 同样由
	 * drm_debugfs.o 提供，只在 CONFIG_DEBUG_FS=y 时编译。去掉调用，
	 * 保留函数本身（它仍被 drm_minor 的 debugfs 回调指针引用）。
	 *
	 * 列表本身保留一个引用，否则 vkms_config_debugfs_list 变成未使用的
	 * static 常量，-Wunused-const-variable 会告警。
	 */
	(void)minor;
	(void)vkms_config_debugfs_list;"""

    if old not in s:
        print(t("dbg_shape_mismatch", name=DRV, sym=DBG_SYM))
        return False

    s = s.replace(old, new, 1)
    p.write_text(s, encoding="utf-8", newline="\n")
    print(t("dbg_removed", name=DRV))
    return True


CRTC_SYM_DRMM = "drmm_crtc_init_with_planes"
CRTC_SYM_PLAIN = "drm_crtc_init_with_planes"
CRTC_FILE = "vkms_crtc.c"


def patch_crtc(root: pathlib.Path) -> bool:
    """把 drmm_crtc_init_with_planes 换成 drm_crtc_init_with_planes。

    两者签名相同（都是 variadic），上游都 EXPORT_SYMBOL，所以是纯改名。
    厂商内核常只裁较新的 drmm_ 版本。
    """
    p = root / CRTC_FILE
    if not p.exists():
        print(t("file_missing", name=CRTC_FILE))
        return True

    s = p.read_text(encoding="utf-8", errors="replace")
    if "VKMS_CRTC_NODRMM" in s:
        print(t("already_patched", name=CRTC_FILE))
        return True
    if CRTC_SYM_DRMM not in s:
        print(t("sym_unused", name=CRTC_FILE, sym=CRTC_SYM_DRMM))
        return True

    n = s.count(CRTC_SYM_DRMM + "(")
    if n == 0:
        print(t("sym_unused", name=CRTC_FILE, sym=CRTC_SYM_DRMM))
        return True

    # 注释独占一行放在调用语句之前（不要插在 "ret = " 和函数名之间，
    # 那样虽然合法但把赋值拆成两行，很难读）。
    out = []
    for line in s.split("\n"):
        if CRTC_SYM_DRMM + "(" in line:
            indent = line[:len(line) - len(line.lstrip())]
            out.append(indent + "/* [VKMS_CRTC_NODRMM] 厂商内核可能未导出 drmm_ 版；")
            out.append(indent + " * 两者签名相同（都 variadic），改用非 drmm 版。 */")
            out.append(line.replace(CRTC_SYM_DRMM + "(", CRTC_SYM_PLAIN + "("))
        else:
            out.append(line)
    s = "\n".join(out)

    p.write_text(s, encoding="utf-8", newline="\n")
    print(f"    {CRTC_FILE}: {CRTC_SYM_DRMM} -> {CRTC_SYM_PLAIN} ({n} 处)")
    return True


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    if not root.is_dir():
        print(t("dir_missing", path=root))
        return 1
    ok1 = patch_composer(root)
    ok2 = patch_drv(root)
    ok3 = patch_crtc(root)
    return 0 if (ok1 and ok2 and ok3) else 1


if __name__ == "__main__":
    sys.exit(main())