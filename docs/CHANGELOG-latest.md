## v0.1.26

### 修复

**修掉 `unshare()` 必现的 CFI 失败（issue #1 的「一跑 droidspaces check 就卡死」）。**

`patches/0003` 给 `vns_copy_cgroup_ns()` 加了对运行期解析指针
`vns_copy_cgroup_ns_fn`（真实 `copy_cgroup_ns`）的间接调用，但漏了 `__nocfi`。
官方 GKI 与厂商内核都是 `CONFIG_CFI_CLANG=y`，于是**任何 `unshare()`** 都会在
`create_new_namespaces → vns_copy_cgroup_ns` 处 kCFI 校验失败：

```
Kernel panic - not syncing: CFI failure (target: copy_cgroup_ns+0x0/0x608)
  vns_copy_cgroup_ns+0x44/0x118 [lkm4ctr]
  create_new_namespaces+0x254/0x548 [lkm4ctr]
  vendor_kernel_hook_unshare+0x188/0x2e4 [lkm4ctr]
```

`droidspaces check` 的第一个 MUST HAVE 探针就是
`fork() + unshare(CLONE_NEWPID)`，所以一跑就死。本版本给该函数补上
`__nocfi`（与上游对 `vns_copy_mnt_ns_fn`、`vns_real_copy_pid_ns_fn` 等
同类调用的处理一致）。

**单 KMI 包安装期校验 5.10/5.15 代际。** `customize.sh` 用出厂
`ro.board.first_api_level` 与包名里的 `androidNN` 比对，不一致直接中止；
`service.sh` 的独子回退补同一道校验；README 补双代际说明。
（这是防呆，不是上面那个卡死的原因。）

### 验证

- 全 KMI 矩阵编译通过（`ci.yml` `full_matrix=true`，7/7）。
- 官方未修改的 GKI android12-5.10 镜像 + QEMU：修复前必现上述 panic，
  修复后 mount / pid / user 命名空间探针全部通过、干净关机。
- 真机回归待报告者确认（自定义内核的 `.config` 与 DDK 一致）。

---

## v0.1.26

### Fixed

**Fixed the unconditional CFI failure on `unshare()` (issue #1: "running
`droidspaces check` hangs the phone").**

`patches/0003` added an indirect call through the runtime-resolved pointer
`vns_copy_cgroup_ns_fn` (the real `copy_cgroup_ns`) in `vns_copy_cgroup_ns()`,
but omitted `__nocfi`. Official GKI and vendor kernels both build with
`CONFIG_CFI_CLANG=y`, so **every `unshare()`** failed kCFI at
`create_new_namespaces → vns_copy_cgroup_ns`:

```
Kernel panic - not syncing: CFI failure (target: copy_cgroup_ns+0x0/0x608)
  vns_copy_cgroup_ns+0x44/0x118 [lkm4ctr]
  create_new_namespaces+0x254/0x548 [lkm4ctr]
  vendor_kernel_hook_unshare+0x188/0x2e4 [lkm4ctr]
```

The first MUST HAVE probe of `droidspaces check` is
`fork() + unshare(CLONE_NEWPID)`, so it died immediately. This release adds the
missing `__nocfi`, matching how upstream treats the same class of call
(`vns_copy_mnt_ns_fn`, `vns_real_copy_pid_ns_fn`, ...).

**Per-KMI packages now check the 5.10/5.15 generation at install time.**
`customize.sh` compares `ro.board.first_api_level` with the `androidNN` in the
package name and aborts on a mismatch; `service.sh`'s single-file fallback got
the same check; the README documents the two-generation caveat. (This is
defensive; it is not the cause of the hang above.)

### Verified

- Full KMI matrix builds green (`ci.yml`, `full_matrix=true`, 7/7).
- Official unmodified GKI android12-5.10 Image under QEMU: the panic above is
  reproducible before the fix; after the fix the mount / pid / user namespace
  probes all pass and the guest powers off cleanly.
- On-device regression pending from the reporter (the custom kernel's
  `.config` matches the DDK).
