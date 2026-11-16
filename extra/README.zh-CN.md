# `extra/` — 可加载模块

[English](README.md)

由 `scripts/build_modules.sh` 针对各受支持 KMI 构建的树外模块。均不需要重编内核
或刷写 boot 镜像。

| 目录 | 产物 | 用途 |
|---|---|---|
| `cgrouplimits/` | `droid_lkm_pids.ko`、`droid_lkm_cpu.ko` | 在 `CONFIG_CGROUP_PIDS=n` / `CONFIG_CFS_BANDWIDTH=n` 的内核上仿真 pids 控制器与 `cpu.max` |
| `devtmpfs/` | `devtmpfs_lkm.ko` | `drivers/base/devtmpfs.c` 的移植，用于 `CONFIG_DEVTMPFS=n` 的内核 |
| `mali_nsfix/` | `mali_nsfix.ko` | 重定向 Mali `kbase` 驱动的 `find_get_pid()`，使 GPU context 可在 PID 命名空间内创建 |
| `net_ip6nat/` | `ip6table_nat.ko` | 供容器网络使用的 IPv6 NAT |
| `uart_guard/` | `uart_guard.ko` | 保护串口 sysfs 读取，避免访问未初始化的 `tty_port` |

## 未导出内核符号的处理

其中若干模块需要厂商内核可能未导出的内核函数。当前使用四种不同手段，具体采用哪
一种取决于符号本身与内核配置。

| 手段 | 使用者 | 说明 |
|---|---|---|
| `KallRecon`（`kr/`）按名查询 kallsyms 表 | `devtmpfs`、`cgrouplimits` | 适用于存在但缺少 `EXPORT_SYMBOL` 的符号。`devtmpfs_lkm` 需要 18 个此类符号。 |
| 通过模块参数传入加载时从 `/proc/kallsyms` 读出的地址 | `net_ip6nat` | KASLR 使地址每次开机变化，无法固化。涉及 9 个函数。 |
| 定义同名转发函数，内部跳转到运行时解析的地址 | `lkm4ctr`（上游补丁 `0009`） | 使所有调用方——包括内核头文件内联展开产生的调用——都链接到本地定义，从而不产生静态导入。 |
| 构建期源码改写 | `macvlan` | `scripts/patch_macvlan.py` 移除三个语义上可替换的符号依赖。 |

任何经间接调用跳转到解析地址的函数必须标注 `__nocfi`，否则
`CONFIG_CFI_CLANG=y` 的内核会在调用点触发陷阱。

`scripts/build_modules.sh` 在生成 `.ko` 的同时输出 `symcheck-<kmi>.txt`，列出每个
模块导入的全部未定义符号，使设备可对照自身导出表自检，无需依赖 `dmesg`。

## 各模块文档

- [`cgrouplimits/README.zh-CN.md`](cgrouplimits/README.zh-CN.md)（[English](cgrouplimits/README.md)）
- [`mali_nsfix/README.zh-CN.md`](mali_nsfix/README.zh-CN.md)（[English](mali_nsfix/README.md)）

`devtmpfs/`、`net_ip6nat/`、`uart_guard/` 的说明位于各自源码头部注释。