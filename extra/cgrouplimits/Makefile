# droid_lkm_pids.ko / droid_lkm_cpu.ko — 仿真 pids / cpu.max 控制器
#
# pids 移植自 ai-luo2006/droidspaces-6.12-pmb110 的 Plan B；
# cpu 为自研时间片限流（cpu.max + 采样 + SIGSTOP/SIGCONT）。
#
# 构建全部：
#   make -C <KDIR> M=<这里> modules
# 只编一个（CI 逐个出货用，避免另一个失败连带整条构建）：
#   make -C <KDIR> M=<这里> MODULE=droid_lkm_pids modules
#
# 两个模块各自都链入一份 KallRecon（运行时解析未导出符号），
# 所以不能合并成一个 .ko —— 它们要能独立 insmod / rmmod。

# 两个模块共用的 KallRecon 对象。立即展开，必须定义在使用之前。
KR_OBJS := kallrecon/core.o kallrecon/access.o kallrecon/discover.o kallrecon/symbol.o kallrecon/slide.o \
	kallrecon/fastboot.o kallrecon/hint.o kallrecon/variant.o kallrecon/anchor.o

# hk 引擎：给热路径探针提供 inline 路由。cgroup_can_fork 每次 fork 都命中，
# kprobe 每次陷异常约 1-3us，inline 是一条 b 指令。引擎内部的
# register_kprobe 走 hk_resolve，不产生静态依赖。
HFILES := hk/hk.o hk/hk_ptr.o hk/hk_patch.o hk/hk_inline.o \
	  hk/hk_kprobe.o hk/hk_kretprobe.o hk/hk_ksym.o hk/hk_cfi.o \
	  hk/hk_redir.o hk/hk_sighook.o hk/hk_flush.o

# 默认两个都编；CI 传 MODULE=<name> 只编一个
MODULE ?= all

# 只有 pids 链 hk 引擎：inline 路由只服务 cgroup_can_fork（pids 的执行层）。
# cpu 只有 cgroup_rmdir 一个冷路径探针，不背这几百 KB。
ifeq ($(MODULE),droid_lkm_pids)
obj-m := droid_lkm_pids.o
droid_lkm_pids-y := pids_mod.o common.o $(HFILES) $(KR_OBJS)
else ifeq ($(MODULE),droid_lkm_cpu)
obj-m := droid_lkm_cpu.o
droid_lkm_cpu-y := cpu_mod.o common.o $(KR_OBJS)
else
obj-m := droid_lkm_pids.o droid_lkm_cpu.o
droid_lkm_pids-y := pids_mod.o common.o $(HFILES) $(KR_OBJS)
droid_lkm_cpu-y  := cpu_mod.o  common.o $(KR_OBJS)
endif

ccflags-y += -I$(src) -I$(src)/hk -I$(src)/kallrecon
ccflags-y += -Wno-declaration-after-statement -Wno-unused-variable \
	-Wno-unused-function -Wno-strict-prototypes -Wno-gcc-compat \
	-Wno-incompatible-function-pointer-types
