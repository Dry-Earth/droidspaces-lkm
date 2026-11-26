## v0.1.29

### 新增

**WebUI「模块」页：逐个 `.ko` 选择开机是否加载。** 底栏新增第五个页签
（主页 / 切换路线 / 模块 / 诊断 / 关于）。每个模块三档——**默认**（跟随内置
路线判定，与没有改动等价）、**开**（强制加载，覆盖路线，例如在 anland6 下加载
vkms）、**关**（永不加载，覆盖路线与旧的 `enable_*` 文件）。应用时写入
`module/ko_switch`（每行一条 `name=0|1`，选「默认」的不落盘），重启生效。

`service.sh` 的读取优先级：`ko_switch` 显式值 > 旧的单文件开关
（`disable_pids` / `disable_cpu` / `disable_uart_guard` / `disable_mali`）>
路线判定与默认。文件缺失 / 为空 / 全畸形都安全回落到默认，单行坏数据（未知
模块名、值不是 0/1、缺 `=`）只记一条警告并忽略，绝不影响其它模块。关掉
`lkm4ctr` 会在页面和开机日志里显著警告（它提供容器必需的命名空间）。
`action.sh doctor` 为每个模块补一行机器可读的 `ko_mod <name> switch=…
loaded=…`。

### 修复

**「操作」按钮的诊断不再被 Android 的 `printf` 参数上限打断。** Android 上的
`printf` 是外部命令（toybox），单个参数受 `MAX_ARG_STRLEN`（128KB）限制；v0.1.28
把整份约 260KB 的内核 config 塞进一个变量再交给 `printf`，直接 `Argument list too
long`，导致 tmpfs ACL/xattr 与 netfilter 两块判定拿到空输入、报错误结论（例如在
`CONFIG_IP_NF_NAT=y` 的内核上报 `ipv4_nat=no`）。现在所有 config 读取统一走管道。

**mali_nsfix 探针与布局校验不再恒报 FAIL。** `nshf_probe_ok` / `nshf_layout_valid`
是 bool 模块参数，sysfs 渲染成 `Y`/`N`，而 `nshf_active` 是 int 渲染成 `1`/`0`；
判定原来只认 `1`，把明明通过的 bool 校验报成 `[FAIL]`。现在 `1`/`Y`/`y` 都接受。

### 文档与说明

- README §1.2（中英文）：逐模块加载开关、`ko_switch` 文件格式与优先级规则。
- WebUI 五页签描述、目录结构、安全说明（WebUI 现在只写 `route` 与 `ko_switch`
  两个配置文件）同步更新。

---

## 0.1.29 - 2026-11-21

### Added

**A Modules tab in the WebUI, to choose per `.ko` whether it loads at boot.**
The bottom bar grows a fifth tab (Home / Route / Modules / Diagnostics /
About). Each module has three settings — **Default** (follow the built-in route
logic; equivalent to making no change), **On** (force-load, overriding the
route, e.g. loading vkms under anland6), **Off** (never load, overriding the
route and any legacy `enable_*` file). Applying writes `module/ko_switch`
(one `name=0|1` line per explicitly-changed module; Default writes nothing),
effective after reboot.

`service.sh` reads it in this precedence: an explicit `ko_switch` value > the
legacy single-file switches (`disable_pids` / `disable_cpu` /
`disable_uart_guard` / `disable_mali`) > the route logic and each module's
default. A missing, empty or fully malformed file falls through safely to the
defaults; one bad line (unknown name, value other than 0/1, missing `=`) is
logged as a warning and ignored, never affecting other modules. Turning off
`lkm4ctr` warns prominently in the page and the boot log (it provides the
container namespaces). `action.sh doctor` adds a machine-readable
`ko_mod <name> switch=… loaded=…` line per module.

### Fixed

**The Action button diagnostics are no longer broken by Android's `printf`
argument limit.** On Android `printf` is an external command (toybox) whose
single argument is capped by `MAX_ARG_STRLEN` (128KB). v0.1.28 stuffed the whole
~260KB kernel config into a variable and passed it to `printf`, which failed
with `Argument list too long`; the tmpfs ACL/xattr and netfilter checks then got
empty input and reported wrong verdicts (e.g. `ipv4_nat=no` on a kernel with
`CONFIG_IP_NF_NAT=y`). All config reads now go through a pipe.

**The mali_nsfix probe and layout checks no longer always report FAIL.**
`nshf_probe_ok` / `nshf_layout_valid` are bool module params, so sysfs renders
them as `Y`/`N`, while `nshf_active` is an int rendered as `1`/`0`; matching only
`1` reported the passing bool checks as `[FAIL]`. `1`/`Y`/`y` are all accepted
now.

### Documentation

- README §1.2 (en + zh): the per-module load switches, the `ko_switch` file
  format and precedence.
- The WebUI five-tab description, the directory tree and the security note (the
  WebUI now writes only two config files, `route` and `ko_switch`) are updated.
