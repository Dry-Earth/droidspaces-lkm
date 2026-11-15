#!/usr/bin/env python3
"""把 vkms 对 DEBUG_FS 专属 drm 符号的依赖去掉。

为什么需要
----------
`drivers/gpu/drm/Makefile` 里：

    drm-$(CONFIG_DEBUG_FS) += drm_debugfs.o drm_debugfs_crc.o

也就是说 `drm_debugfs_create_files()` 和 `drm_crtc_add_crc_entry()` **只在
CONFIG_DEBUG_FS=y 的内核里存在**。GKI 的 gki_defconfig 没有显式打开 DEBUG_FS
（它没有默认值），所以相当一部分真机是 n —— 那些内核里这两个符号压根不存在。

vkms 用到两处：

    vkms_drv.c:112        drm_debugfs_create_files(...)     debugfs 配置展示
    vkms_composer.c:249   drm_crtc_add_crc_entry(...)       CRC 上报

于是 vkms 在这些内核上 insmod 直接报
    Unknown symbol drm_crtc_add_crc_entry
永远装不上——不是加载时序问题（DRM 在 GKI 里是 =y，编进内核），是符号不存在。

做法
----
两处都是**纯调试功能**：一个是 debugfs 里展示 vkms 配置，一个是给 igt 之类
的工具上报 CRC。容器要的是 /dev/dri/renderD128 这个 render node，
和它们无关。

所以构建时把这两处调用去掉：

  - CRC：保留循环计数（避免未使用变量告警），去掉上报调用
  - debugfs：函数体改成空（保留函数本身，vkms_config_debugfs_init 仍被
    drm_minor 的 debugfs 回调引用，删函数会引发未定义引用）

这样 vkms 在 DEBUG_FS 开或关的内核上都能加载。代价是调试功能没了，渲染不受影响。
"""

import sys
import pathlib

COMPOSER = "vkms_composer.c"
DRV = "vkms_drv.c"


def patch_composer(root: pathlib.Path) -> bool:
    p = root / COMPOSER
    if not p.exists():
        print(f"  {COMPOSER}: 不存在")
        return False
    s = p.read_text(encoding="utf-8", errors="replace")
    if "VKMS_CRC_DISABLED" in s:
        print(f"  {COMPOSER}: 已打过补丁")
        return True

    old = """	while (frame_start <= frame_end)
		drm_crtc_add_crc_entry(crtc, true, frame_start++, &crc32);"""
    new = """	/*
	 * [VKMS_CRC_DISABLED] drm_crtc_add_crc_entry() 由 drm_debugfs_crc.o
	 * 提供，那个文件只在 CONFIG_DEBUG_FS=y 时编译。真机常为 n，符号
	 * 不存在会让整个 vkms 装不上。CRC 只给调试工具用，这里去掉上报，
	 * 保留计数让变量仍被使用。
	 */
	while (frame_start <= frame_end)
		frame_start++;"""
    if old not in s:
        print(f"  {COMPOSER}: 未找到 CRC 调用点")
        return False

    s = s.replace(old, new, 1)
    p.write_text(s, encoding="utf-8", newline="\n")
    print(f"  {COMPOSER}: CRC 上报已移除")
    return True


def patch_drv(root: pathlib.Path) -> bool:
    p = root / DRV
    if not p.exists():
        print(f"  {DRV}: 不存在")
        return False
    s = p.read_text(encoding="utf-8", errors="replace")
    if "VKMS_DEBUGFS_DISABLED" in s:
        print(f"  {DRV}: 已打过补丁")
        return True

    old = """	drm_debugfs_create_files(vkms_config_debugfs_list, ARRAY_SIZE(vkms_config_debugfs_list),
				 minor->debugfs_root, minor);"""
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
        print(f"  {DRV}: 未找到 debugfs 调用点")
        return False

    s = s.replace(old, new, 1)
    p.write_text(s, encoding="utf-8", newline="\n")
    print(f"  {DRV}: debugfs 注册已移除")
    return True


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    ok1 = patch_composer(root)
    ok2 = patch_drv(root)
    return 0 if (ok1 and ok2) else 1


if __name__ == "__main__":
    sys.exit(main())