# hummer 精确内核构建（OnePlus Ace 5 Pro / LineageOS 24）

这是 [misaka5202/droidspaces-lkm](https://github.com/misaka5202/droidspaces-lkm) 的
fork，增加了**按设备精确内核**构建的通道。上游已同步到 `89cbefc`（v0.1.29，
ko_switch + i18n + lkm4ctr-lite），合并提交 `77901a4`。

构建只使用 OTA `build-manifest.xml` 钉住的工具，不包含 DDK 容器路径；模块集合
按解包出来的原厂 config 决定，内核里已经有的能力不再重复编。

---

## 1. 已验证结果

| 项目 | 值 |
|---|---|
| 设备 | OnePlus Ace 5 Pro（`hummer`） |
| ROM | LineageOS 24.0，20261120 OTA |
| 内核 | `6.6.144-4k-g01ee97578159` |
| kernel commit | `01ee97578159bc9cb2a60f559d20510ce33add6a` |
| `droidspaces check` | **全部 ✓**（PID / IPC / userns / CPU limit / Process limit） |
| userns | 真实 `struct user_namespace`：`unshare -Ur true` = 0，`uid_map` = `0 0 65536` |
| 模块加载 | `hummer-manifest-45852211799`：8/8 加载成功，`boot-completed` 正常，无卡死 |
| App 识别 | 由 `0012` 补 `NSpid`；`/proc/<init>/status` 应出现 `NSpid: <host> 1`（待最新构建设备确认） |

发布记录（ZIP 均为 `droidspaces-lkm-hummer-arm64.zip`）：

| Release | ZIP sha256 | 说明 |
|---|---|---|
| `hummer-manifest-45852211799` | `74cc0089958e594498264c9b7d85ff5b6a7ee8b84e2f462f66f45b6877693575` | 真实 userns |
| `hummer-manifest-45861110289` | `080163934d558c17209b10cd58de7f02d195c2df47e9812ca9fe4c9e0ffe378a` | + NSpid 模拟 |
| `hummer-manifest-45862609906` | 同上 | + config-driven 模块集合（本机 config 下产物相同） |

---

## 2. 工作流使用方法

工作流文件：`.github/workflows/build-hummer-manifest.yml`
名称：**`[hummer] Build from manifest tools`**

### 2.1 触发

网页：仓库 → Actions → 左侧选 `[hummer] Build from manifest tools` → **Run workflow**。

命令行：

```sh
gh workflow run build-hummer-manifest.yml \
  -f boot_img_url=https://.../boot-20261120-finasu-v3.img \
  -f manifest_url=https://mirrorbits.lineageos.org/full/hummer/20261120/build-manifest.xml \
  -f publish_release=true
```

### 2.2 输入

| 输入 | 必须 | 说明 |
|---|:---:|---|
| `boot_img_url` | ✓ | 同一个 OTA 的 `boot.img`。KDIR 的 `.config` / release / 编译器信息都从这里解出来 |
| `manifest_url` | ✓ | 同一个 OTA 的 `build-manifest.xml`，钉住 kernel / modules / clang / build-tools / mkbootimg 的 revision |
| `publish_release` |  | `true` 时构建成功自动发 Release；否则只留 Actions artifact |

> 两个 URL 必须来自**同一次 OTA**。内核变了（`uname -r` 的 `g...` 变化）就必须
> 换 URL 重跑，否则模块 vermagic 不匹配，装机只会得到一句
> `unknown symbol in module`。

### 2.3 流水线做了什么

| 步骤 | 产物 / 作用 |
|---|---|
| 解析 manifest | `metadata.env`：kernel、modules、clang、build-tools、mkbootimg 的 revision |
| 安装宿主依赖 | 只装 LineageOS 构建文档要求的包（`build-essential`、`libssl-dev`、`python3`、`perl`、`rsync`、`zip`…） |
| 解包 boot.img | 用 manifest 里的 AOSP `unpack_bootimg.py`（不用 magiskboot），得到原厂 config 与 release |
| 拉源码 | kernel 与 kernel modules 的仓库都按 manifest revision 检出 |
| 准备工具链 | clang r596125、build-tools、kernel-build-tools、mkbootimg；缓存在 `tools/`（约 1.2 GiB） |
| 准备 pahole | manifest 里的 pahole 不可用时回退 Ubuntu `dwarves`（v1.25） |
| 应用 patch | clone `cyanmint/lkm4ctr`（`lkm4ctr` 分支），按文件名顺序 `git apply patches/*.patch` |
| 编 KDIR | 用同一套 manifest clang 在 runner 上编出与设备完全一致的 KDIR（`kernel/out`），ccache 缓存在 `.ccache` |
| 编模块 | `scripts/build_modules.sh` 按原厂 config 只编缺的模块 |
| 校验 vermagic | 每个 `out/*.ko` 必须包含 `vermagic=<设备 release>`，否则直接失败 |
| 打包 | `ci/package-hummer.py`：整份 `module/` + `ko/` + `build-info.*`，删掉 `updateJson` |
| 发布 | tag `hummer-manifest-<run_id>`，上传 zip、`SHA256SUMS`、`build-info-hummer.txt` |

冷缓存约 30 分钟（主要花在编 KDIR）；`tools/` 和 `.ccache` 命中后通常十几分钟。
缓存 key 跟 `metadata.env` 与 `build-config/stock.config` 绑定，换内核会自动失效。

### 2.4 产物怎么用

- Actions artifact：`droidspaces-lkm-hummer-manifest-<run_id>`
- Release：`hummer-manifest-<run_id>`（`publish_release=true` 时）
- `build-info-hummer.txt` 里记着 kernel commit、clang 版本、lkm4ctr commit、
  boot sha256，以及每个 payload 的 sha256 —— 排查“到底装的哪一版”先看它。

---

## 3. 模块集合：内核缺什么才补什么

`scripts/build_modules.sh` 读解包出来的原厂 config（`build-config/stock.config`），
已启用的能力直接跳过：

| 模块 | 跳过条件（原厂 config） |
|---|---|
| `lkm4ctr`（核心） | 始终构建 |
| `uart_guard`（tty 安全兜底） | 始终构建 |
| `devtmpfs_lkm` | `CONFIG_DEVTMPFS=y/m` |
| `macvlan` | `CONFIG_MACVLAN=y/m` |
| `ip6table_nat` | `CONFIG_IP6_NF_NAT` + `CONFIG_IP6_NF_TARGET_MASQUERADE` |
| `droid_lkm_pids` | `CONFIG_CGROUP_PIDS=y/m` |
| `droid_lkm_cpu` | `CONFIG_CFS_BANDWIDTH=y/m` |
| `vkms` | `CONFIG_DRM_VKMS=y/m` |

另外两个不参与完整性断言：

- `lkm4ctr-lite`：不带 vendored overlayfs 的回退版，设备上完整版装不上时
  `service.sh` 会自动回退到它（至少保住 PID/IPC/UTS namespace）。
- `mali_nsfix`：只在检测到 Mali GPU（`/dev/mali0` 或 `mali_kbase`）时加载；
  本机是 Adreno，不会加载。

完整性检查按同一份 config 计算“本次应有”的模块（`out/modules-built-<kmi>.txt`），
缺任何一个都会让这一格红；不会出现“静默少发几个模块”的包。

本机（20261120 LineageOS 内核）上述 CONFIG 全部为 `n`，所以实际仍编全套。

### 加一项新的“缺啥补啥”

1. 在 `scripts/build_modules.sh` 对应段落加：
   ```sh
   if cfg_on CONFIG_XXX; then
       log "=== xxx @ $KMI: skip (CONFIG_XXX already enabled) ==="
   else
       ... 原有构建 ...
   fi
   ```
2. 在文件末尾的 `expected=` 列表加一行：`cfg_on CONFIG_XXX || expected="$expected xxx"`。
3. 在 `module/service.sh` 里加对应的 `ko_gate` + `load_mod`。

---

## 4. 相对上游的改动

| 文件 | 作用 |
|---|---|
| `.github/workflows/build-hummer-manifest.yml` | 构建入口（manifest 工具、AOSP 解包、无 DDK） |
| `ci/build-kdir-host.sh` | 用 manifest clang 在 runner 上编精确 KDIR |
| `ci/build-hummer-modules-host.sh` | 用精确 KDIR 编模块 |
| `ci/fetch-manifest-tools.sh` | 按 manifest revision 下载工具链 |
| `ci/parse-manifest.py` | 解析 kernel / modules / clang / build-tools / mkbootimg |
| `ci/adapt-lkm4ctr.py` | 适配厂商内核的 `backing_file_open(const struct file *, …)` |
| `ci/package-hummer.py` | 打包整份 `module/`（脚本 + i18n + WebUI），删掉 `updateJson` |
| `scripts/build_modules.sh` | config-driven 模块集合、`KSRC_OVERRIDE`、`LKM4CTR_DIR` |
| `patches/0012-nspid-status.patch` | 补 `proc_pid_status` 的 NStgid/NSpid/NSpgid/NSsid |

上游 patch（`0001`–`0011`）按顺序原样应用；`0012` 必须最后应用。

### 为什么需要 0012

Droidspaces 用 `/proc/<pid>/status` 的 `NSpid` 最后一位是否为 `1` 判断容器 init
（`src/container/registry.c` 的 `is_container_init()`）。本机内核
`CONFIG_PID_NS=n`，`fs/proc/array.c` 里整段 NS 输出被编译掉 —— 即使 lkm4ctr
用的是真实 `copy_pid_ns`，App 也看不到 NSpid，于是显示“容器未运行”。

0012 用 `shadow_hook` 挂 `proc_pid_status`，按 `pid->numbers[]` 重建这段输出
（逻辑与内核一致），只对 `pid->level > ns->level` 的进程追加，宿主进程不受影响。

---

## 5. 实践经验（踩坑记录）

| 现象 | 根因 | 做法 |
|---|---|---|
| 打补丁的 boot 里找不到 `based on r…` 字符串 | patched boot 的 banner 被改过 | 从 config 的 `CONFIG_CC_VERSION_TEXT` 回退取编译器版本 |
| manifest 里的 pahole 跑不起来 | 预编译 pahole 与新 glibc 不兼容 | 回退 Ubuntu `dwarves`（v1.25），KDIR 仍能正常 `prepare` |
| CI 里 `git apply` 突然失败 | Windows 检出把 patch 变成 CRLF | 仓库加 `.gitattributes`（`*.patch -text`、`*.sh eol=lf`）；本地改完用 `git apply --check` 验证全部 patch |
| 自己新加的 patch 不生效/顺序错 | `git apply` 按文件名字典序 | 本 fork 的 patch 编号必须排在上游最后一个之后（当前 `0012`） |
| 模块装上后 `unknown symbol in module` | vermagic 或符号表不匹配（常见是 KMI 选错 / 内核已换） | 先看 `build-info-hummer.txt` 的 release；工作流有 vermagic 断言；设备上用 `strings xxx.ko \| grep vermagic` |
| 工作流编模块时报 `/tmp/lkm4ctr` 不存在 | 上游脚本硬编码了 DDK 路径 | 本 fork 改成 `LKM4CTR_DIR`（默认 `/tmp/lkm4ctr`，host 流水线指到 `$PWD/lkm4ctr`） |
| App 一直显示“容器未运行” | 内核 `CONFIG_PID_NS=n`，没有 `NSpid` | 应用 `0012-nspid-status.patch`；设备上 `grep NSpid /proc/<pid>/status` 验证 |
| `unshare -U` 成功但 `uid_map` 写不进去 | 映射必须由**父进程**写给子进程；写 gid_map 前要先 `setgroups=deny` | 用父进程写 `/proc/$pid/{uid,gid}_map`，见下方验证命令 |
| 容器里 `mount -t tmpfs` 报 `-13` | SELinux `u:r:kernel:s0` 的 `mounton` 拒绝 | 这是 SELinux 不是 userns 的问题；`droidspaces check` 仍可全绿 |
| 容器能跑但没有 `/dev/dri/renderD*` | 上游 vkms 没有 `DRIVER_RENDER` | `scripts/patch_vkms_driver_features.py` 打补丁，并做二次确认 |
| 容器里 udev 一扫 `ttyS*` 就重启 | 厂商 `uart_get_info` 没有 `tty_port` 有效性检查 | `uart_guard` 模块（默认加载） |
| 刷完模块没生效 | 旧模块还占着同名 namespace 钩子 | `touch /data/adb/modules/<旧模块>/disable` 后**重启**，再装本包 |
| 构建一直失败在解包 boot 的步骤 | AOSP `unpack_bootimg.py` 需要显式 `--boot_img` / `--out`，且 `based on` 行可能被厂商改掉 | 显式传参；编译器版本从 `CONFIG_CC_VERSION_TEXT` 回退 |
| `prepare` 阶段 bison 报找不到 `data/` | AOSP 预编译 bison 的数据目录不在默认路径 | 显式设置 `BISON_PKGDATADIR` 指向 build-tools 的 `share/bison` |
| KDIR 编好但模块编译找不到内核头 | `KSRC` 只会探测 `$KDIR` 下带 `drivers/` 的树 | host 流水线用 `KSRC_OVERRIDE` 指到 kernel 源码树 |

另外两条与设备相关的经验：

- `droidspaces` **不在默认 PATH**：用 `/data/local/Droidspaces/bin/droidspaces check`。
- 模块 ID 是 `droidspaces_lkm`，与 phDroid（`phdroid`）互斥；两者都会抢
  namespace hook，切换时先 disable 再重启。

---

## 6. 安装与验证

1. 先卸载/停用旧的 `droidspaces_lkm`、`droidspaces_hummer`、phDroid 等
   namespace 模块并**重启**。
2. KernelSU 安装 `droidspaces-lkm-hummer-arm64.zip`，重启。
3. 基础验证：

```sh
su -c 'cat /data/adb/droidspaces_lkm.log'
su -c 'lsmod | grep -E "lkm4ctr|devtmpfs_lkm|droid_lkm|uart_guard"'
su -c '/data/local/Droidspaces/bin/droidspaces check'
```

4. userns（应为真实映射）：

```sh
su -c 'unshare -Ur sh -c "id -u; cat /proc/self/uid_map"'
# 期望：0，以及 0 0 1（或父进程写入的映射范围）
```

5. App 识别容器 init：

```sh
su -c 'ps -A -o pid,comm | grep -E "init|ds-monitor"'
su -c 'grep NSpid /proc/<pid>/status'
# 期望：NSpid: <host_pid> 1
```

6. 范围映射（父进程写子进程）：

```sh
su -c 'unshare -U sleep 60 & p=$!; sleep 1; \
  echo "0 0 65536" > /proc/$p/uid_map; echo deny > /proc/$p/setgroups; \
  echo "0 0 65536" > /proc/$p/gid_map; cat /proc/$p/uid_map; kill $p'
```

7. 模拟的 cgroup 限制（`--cpus` / `--pids-limit` 需要同时给 `--memory`）：

```sh
su -c 'droidspaces --name=box --rootfs=<rootfs> --memory=512M --cpus=0.5 --pids-limit=64 start'
su -c 'cat /sys/fs/cgroup/droidspaces/box/cpu.max'
su -c 'cat /sys/fs/cgroup/droidspaces/box/pids.max'
```

---

## 7. WebUI / 模块开关

打包内容包含上游的 WebUI（`webroot/`）和 `i18n.sh`，KernelSU 里点模块的
“打开”即可使用。

逐模块开关写在 `/data/adb/modules/droidspaces_lkm/ko_switch`，每行
`<name>=<0|1>`（例如 `vkms=1`），WebUI 会读写这个文件。旧的
`disable_pids` / `disable_cpu` 仍兼容，但优先级低于 `ko_switch`。

`vkms` 默认不加载，需要 Wayland / GUI 容器时在 WebUI 里打开。

---

## 8. 维护

- **升级判断**：上游发 Release，或提交改了 `scripts/build_modules.sh`、
  `patches/*.patch`、`extra/**/*.c`、或 `cyanmint/lkm4ctr` 的 HEAD 时才需要重编；
  纯文档提交不需要。
- **同步上游**：

  ```sh
  git remote add upstream https://github.com/misaka5202/droidspaces-lkm.git
  git fetch upstream master
  git merge upstream/master
  ```

  冲突时保留 `ci/`、`scripts/build_modules.sh` 的 config 判断、`patches/0012-*`、
  hummer workflow 的本地修改，其余取上游。
- **上游重写了 `build_modules.sh` 怎么办**：以上游新文件为底，重新移植两处：
  `cfg_on` 门（5 处）和末尾的 `expected=` 列表，外加 `KSRC_OVERRIDE` 与
  `LKM4CTR_DIR`。
- **OTA**：内核 commit 不变就只换 `manifest_url`；变了就两个 URL 一起换。
- **patch 顺序**：每次新增 patch 都用 `git apply --check` 按序验证一遍全部
  patch（CI 用的就是这套顺序）。

本地验证 patch 链（模拟 CI）：

```sh
git clone --depth=1 -b lkm4ctr https://github.com/cyanmint/lkm4ctr.git /tmp/lkm4ctr
for p in patches/*.patch; do git -C /tmp/lkm4ctr apply --check "$p" || echo "FAIL $p"; git -C /tmp/lkm4ctr apply "$p"; done
```

---

## 9. 已知限制

- 只支持 `target-release` 记录的这一颗内核（当前 `6.6.144-4k-g01ee97578159`）。
- 模块 ID 是 `droidspaces_lkm`，会替换上游模块；`updateJson` 已删除，避免被
  通用 GKI 包自动覆盖。
- `service.sh` 会在开机时加载 `droid_lkm_pids` / `droid_lkm_cpu`（kprobe + 运行时
  符号解析）。若遇到卡开机，可在模块目录写 `disable_pids` / `disable_cpu`（或
  `ko_switch` 里置 0）后重启排查。
- userns 是 lkm4ctr 里 vendored 的真实 `struct user_namespace`，但内核本身没有
  `CONFIG_USER_NS=y`，`setns` 等部分路径可能不完整；不要把它当成完整安全边界，
  不要把不可信程序放进去。
- `lkm4ctr` 会改写内核入口；首次刷入请保留 fastboot / recovery 回滚手段。
