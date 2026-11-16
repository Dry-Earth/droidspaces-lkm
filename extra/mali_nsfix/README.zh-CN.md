# mali_nsfix

[English](README.md)

重定向 Mali `kbase` 驱动发起的 `find_get_pid()` 调用，使 GPU context 能在 PID
命名空间内创建，无需重新构建厂商模块。

## 问题

`kbase_create_context()`（`drivers/gpu/arm/midgard/context/mali_kbase_context.c`）执行：

```c
kctx->tgid  = current->tgid;              /* 初始 PID 命名空间的值 */
rcu_read_lock();
pid_struct  = find_get_pid(kctx->tgid);   /* 在 current 的命名空间中查找 */
if (pid_struct) {
    task = pid_task(pid_struct, PIDTYPE_PID);
    if (task) { get_task_struct(task); kctx->task = task; }
    else     { err = -ESRCH; }
    put_pid(pid_struct);
} else {
    dev_err(dev, "Failed to get pid pointer for %s/%d", current->comm, current->pid);
    err = -ESRCH;
}
rcu_read_unlock();
if (unlikely(err))
    return NULL;
```

`task_struct->tgid` 始终是初始命名空间中的值，而 `find_get_pid()` 经由
`find_vpid()` 解析，查找的是调用者当前的活动命名空间。对容器进程而言两者不一致，
查找失败，`kbase_create_context()` 返回 `NULL`，`kbase_file_create_kctx()` 将其
映射为 `-ENOMEM`——因此用户态看不到 `-ESRCH`，唯一线索是上面那行 `dmesg`。

Android 自身进程不受影响：对它们而言两个值是同一个任务。

## 修法

在 `find_get_pid()` 上挂 kprobe。当调用者的返回地址位于名称以 `mali_kbase`
开头的模块内时，将调用重定向到
`get_task_pid(current->group_leader, PIDTYPE_PID)`。

替换函数返回的任务与厂商补丁用 `current->group_leader` 取得的是同一个，其获取的
引用由驱动自身的 `put_pid()` 平衡。由于宿主进程本就会解析到其 group leader，
对 kbase 调用者无条件重定向无需命名空间判断：在宿主上是空操作，在容器内即修复。

调用者归属判定使用 `within_module()`，这是 `module.h` 中的 `static inline`，
在编译期解析 `struct module` 布局。不需要符号查找，也不依赖厂商模块自身的符号。

## 为什么不重新构建 `mali_kbase.ko`

该路径需要厂商驱动源码、与运行内核匹配的符号 CRC，以及在 `vendor_dlkm` 中替换
模块或 `rmmod` 掉一个 Android 正在使用的驱动。后者会在下一次 GPU fence 处 panic，
因为旧模块卸载时硬件合成器仍可能持有 fence。kprobe 不需要其中任何一项，且能跨
OTA 存活。

## 实测

OPPO PHZ110，MediaTek MT6989，`mali_kbase_mt6989_r44`，Android 17，内核
6.1.157，Droidspaces 7.2.0。在容器内运行 `test/kbase_ctx_test.c`：

| 状态 | VERSION_CHECK | SET_FLAGS | `dmesg` |
|---|---|---|---|
| 模块未加载 | 0，API 1.0 | **-1，`errno=12`（ENOMEM）** | `Failed to get pid pointer for ctx/14508` |
| 模块已加载 | 0，API 1.0 | **0，context 创建成功** | 无输出 |

模块加载状态下连续运行五次：5/5 成功，无 `Failed to get pid pointer` 行。
亦以 uid 1000 而非 root 验证通过。

## ioctl 编号

此构建上 `VERSION_CHECK` 为 `0xC0048034`，而非 `0xC0048000`（`_IOWR(0x80, 0, 4)`）。
nr 为 0 的形式返回 `-EPERM`——驱动将该槽位保留给另一个变体。`SET_FLAGS` 为
`0x40048001`，需要一个指向 `u32` 的有效指针；传 `NULL` 得到 `-EFAULT`。

## 范围

本模块只解除 GPU context 创建这一处阻塞。用户态仍需将厂商驱动载入容器并提供
render node；那属于 libhybris 路径，与本模块无关。

## 构建

与 `extra/` 下其他模块一样，在 DDK 内核树中树外构建：

```sh
make -C "$KDIR" M="$PWD" modules
```

## 测试

```sh
# 容器内
gcc -O2 -static -o kbase_ctx_test test/kbase_ctx_test.c
./kbase_ctx_test

# 宿主机，分别在有/无模块时运行
rmmod mali_nsfix && droidspaces --name=Debian run -- /kbase_ctx_test
insmod mali_nsfix.ko && droidspaces --name=Debian run -- /kbase_ctx_test
```