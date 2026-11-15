// SPDX-License-Identifier: GPL-2.0-only
/*
 * uart_guard - 阻止读取坏掉的 tty_port 把内核打挂
 *
 * 问题
 * ----
 * 串口的 sysfs 属性（port / type / console 等）都走同一个路径：
 *
 *   port_show()/type_show()            drivers/tty/serial/serial_core.c
 *     -> uart_get_info(dev_get_drvdata(dev), &tmp)
 *          -> mutex_lock(&port->mutex);      <-- 没有任何有效性检查
 *
 * uart_get_info() 假设 drvdata 一定是一个可用的 struct tty_port。上游到现在
 * （mainline 也一样）都没有检查这一点。当某个 tty 的 tty_port 处于不完整的
 * 生命周期状态时，读它的属性就是一次内核内存访问越界：
 *
 *   实测（6.1.157 / MT6989，ttyS3 = 蓝牙串口 11004000.serial，
 *        被 platform:btmtk_uart.0 消费）：
 *     Unable to handle kernel NULL pointer dereference at 0x54
 *     __mutex_lock+0xd8 <- mutex_lock <- uart_get_info <- type_show
 *   读 port 属性同样崩，ttyS0/S1/S2 则正常。
 *
 * 因为它是**读一个 sysfs 文件**就触发的，容器里的 udev（枚举 /sys/class/tty
 * 并逐个读取属性）会稳定把它打出来 —— 宿主内核 panic、整机重启。
 *
 * 做法
 * ----
 * 在 uart_get_info() 入口挂 kprobe，先做三项检查，任一项不过就直接返回
 * -ENODEV，根本不进入函数体：
 *
 *   1. port 为 NULL
 *   2. port 不是合法的内核线性映射地址
 *   3. port->mutex 的 owner 字段里带着一个不是内核指针的"任务指针"
 *
 * 第 3 条针对的正是实测到的形态：mutex 内存里 owner 只剩标志位、没有有效
 * task_struct 指针（例如 owner == 8），于是 __mutex_lock 把它当成
 * task_struct* 去读 -> 0x54 崩溃。一个正常初始化的 mutex，owner 要么是 0
 * （未加锁），要么是真实的内核指针。
 *
 * 这样 hook 一个点就覆盖了 port_show / type_show / 其它所有调用者，而且
 * 只在读这几个属性时触发，频率极低。
 *
 * 注意：这是**兜底**，不是修复根因。根因在串口驱动与蓝牙驱动的 tty_port
 * 生命周期上；本模块只保证"读到它不会把整机打挂"。
 */

#include <linux/kernel.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/sched.h>
#include <linux/tty.h>
#include <linux/vmalloc.h>

/* mutex owner 低位是标志位（WAITERS/HANDOFF/PICKUP），掩掉后是 task_struct* */
#define UART_GUARD_OWNER_FLAGS	0x7UL

static int uart_guard_skipped;
module_param_named(skipped, uart_guard_skipped, int, 0444);
MODULE_PARM_DESC(skipped, "how many uart_get_info() calls were refused (read-only)");
MODULE_PARM_DESC(debug, "unused");

static bool uart_guard_bad_port(struct tty_port *port)
{
	unsigned long owner, task;

	if (!port)
		return true;

	/* tty_port 是 kmalloc 出来的，必须在直接映射区里 */
	if (!virt_addr_valid((void *)port))
		return true;

	/*
	 * 读 owner 之前先确认 port 本身可寻址；上面已经通过 virt_addr_valid()。
	 * 这里只读 8 字节，不会因为 port 指向已释放内存就崩（该页仍然映射）。
	 */
	owner = atomic_long_read(&port->mutex.owner);
	task = owner & ~UART_GUARD_OWNER_FLAGS;

	if (task && !virt_addr_valid((void *)task))
		return true;

	return false;
}

static int uart_guard_pre(struct kprobe *p, struct pt_regs *regs)
{
	struct tty_port *port = (struct tty_port *)regs->regs[0];

	if (!uart_guard_bad_port(port))
		return 0;

	/*
	 * 跳过被探测的函数：把 PC 设成返回地址、x0 设成返回值，
	 * 等价于"uart_get_info() 立刻返回 -ENODEV"。
	 * 此时函数序言还没执行，直接返回是安全的。
	 */
	pr_warn_ratelimited("[uart_guard] refused uart_get_info(port=%px): bad tty_port state\n",
			    port);
	WRITE_ONCE(uart_guard_skipped, uart_guard_skipped + 1);
	regs->pc = regs->regs[30];	/* LR = 调用者的返回地址 */
	regs->regs[0] = (unsigned long)(long)-ENODEV;
	return 1;
}

static struct kprobe uart_guard_kp = {
	.symbol_name	= "uart_get_info",
	.pre_handler	= uart_guard_pre,
};

/*
 * console_show() 是唯一**不走** uart_get_info 的属性：它自己
 * mutex_lock(&port->mutex)，所以只钩 uart_get_info 覆盖不到它。
 *
 *   console_show(dev):
 *       port = dev_get_drvdata(dev);      <- arg0 是 struct device *
 *       mutex_lock(&port->mutex);         <- 同一个坏 mutex，同一处崩溃
 *
 * 它的第一个参数是 device 而不是 tty_port，所以单独取 drvdata 再走同一套校验。
 */
static int uart_guard_console_pre(struct kprobe *p, struct pt_regs *regs)
{
	struct device *dev = (struct device *)regs->regs[0];
	struct tty_port *port = dev ? dev_get_drvdata(dev) : NULL;

	if (!uart_guard_bad_port(port))
		return 0;

	pr_warn_ratelimited("[uart_guard] refused console_show(dev=%px port=%px): bad tty_port state\n",
			    dev, port);
	WRITE_ONCE(uart_guard_skipped, uart_guard_skipped + 1);
	regs->pc = regs->regs[30];
	regs->regs[0] = (unsigned long)(long)-ENODEV;
	return 1;
}

static struct kprobe uart_guard_console_kp = {
	.symbol_name	= "console_show",
	.pre_handler	= uart_guard_console_pre,
};

static int __init uart_guard_init(void)
{
	int ret;

	ret = register_kprobe(&uart_guard_kp);
	if (ret) {
		pr_err("[uart_guard] register_kprobe(uart_get_info) failed: %d\n", ret);
		return ret;
	}

	pr_info("[uart_guard] guarding uart_get_info at %px\n",
		uart_guard_kp.addr);

	/*
	 * console_show 钩不上不是致命错误：其余 13 个属性仍被保护，
	 * 只漏掉 console 这一个，记一条警告即可。
	 */
	ret = register_kprobe(&uart_guard_console_kp);
	if (ret)
		pr_warn("[uart_guard] register_kprobe(console_show) failed: %d "
			"(console attribute stays unguarded)\n", ret);
	else
		pr_info("[uart_guard] guarding console_show at %px\n",
			uart_guard_console_kp.addr);

	return 0;
}

static void __exit uart_guard_exit(void)
{
	unregister_kprobe(&uart_guard_console_kp);
	unregister_kprobe(&uart_guard_kp);
}

module_init(uart_guard_init);
module_exit(uart_guard_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Refuse uart_get_info() on tty_ports whose mutex state is corrupt (prevents sysfs-read panic)");
MODULE_AUTHOR("misaka5202");