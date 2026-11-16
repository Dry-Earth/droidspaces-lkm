#!/usr/bin/env python3
"""
i18n.py - Python 辅助脚本的文案目录

与 i18n.sh 分开：shell 脚本 source 不了 Python 模块，Python 也 source 不了
shell 目录，但两者判定语言的规则必须一致，否则同一台机器上两套脚本会显示
不同语言。

判定顺序（与 i18n.sh 相同）：
  LKM4CTR_LANG（显式指定，优先） -> LC_ALL -> LANG -> 英文

约束与模块侧相同：标记与数据不翻译（[OK] / [FAIL] / 路径 / 符号名），
只翻译描述。
"""
import os

__all__ = ["LANG", "t"]


def _detect() -> str:
    forced = os.environ.get("LKM4CTR_LANG")
    if forced:
        return forced
    loc = os.environ.get("LC_ALL") or os.environ.get("LANG") or ""
    if loc.startswith("zh") or "CN" in loc or "Hans" in loc or "Hant" in loc:
        return "zh"
    return "en"


LANG = _detect()

_MSG = {
    # ---- patch_macvlan.py ----
    "macvlan_rewrites": {
        "en": "  macvlan.c rewrites:",
        "zh": "  macvlan.c 改写：",
    },
    "macvlan_no_change": {
        "en": "    (no change; likely already rewritten)",
        "zh": "    (无改动，可能已经改过)",
    },
    # ---- patch_vkms_debugfs.py ----
    "file_missing": {
        "en": "  {name}: file not found, skipped",
        "zh": "  {name}: 文件不存在，跳过",
    },
    "already_patched": {
        "en": "  {name}: already patched",
        "zh": "  {name}: 已打过补丁",
    },
    "sym_unused": {
        "en": "  {name}: {sym} not referenced, nothing to do",
        "zh": "  {name}: 不使用 {sym}，无需处理",
    },
    "crc_no_callsite": {
        "en": "  {name}: references {sym} but no call site found",
        "zh": "  {name}: 引用了 {sym} 但找不到调用点",
    },
    "crc_removed": {
        "en": "  {name}: CRC reporting removed",
        "zh": "  {name}: CRC 上报已移除",
    },
    "dbg_shape_mismatch": {
        "en": "  {name}: references {sym} but the call-site shape does not match",
        "zh": "  {name}: 引用了 {sym} 但调用点形状不匹配",
    },
    "dbg_removed": {
        "en": "  {name}: debugfs registration removed",
        "zh": "  {name}: debugfs 注册已移除",
    },
    "dir_missing": {
        "en": "  directory not found: {path}",
        "zh": "  目录不存在: {path}",
    },
}


def t(key: str, **kw) -> str:
    """取当前语言的文案。缺键回退英文，再缺就返回键名本身。"""
    entry = _MSG.get(key)
    if not entry:
        return key
    fmt = entry.get(LANG) or entry.get("en") or key
    try:
        return fmt.format(**kw)
    except (KeyError, IndexError):
        return fmt