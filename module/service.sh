#!/system/bin/sh
# service.sh - late_start 阶段加载模块
#
# 按 KernelSU 文档，service.sh 在 late_start service 阶段执行，非阻塞，
# 是"跑开机脚本"的推荐阶段。本模块只往内核里 insmod，不碰系统分区，
# 因此不需要 post-fs-data.sh（那个阶段是阻塞的，能不用就不用）。
#
# 目录约定（打包时生成）：
#   ko/<模块名>-<kmi>.ko
#
# MODDIR 用规范写法取，不硬编码 /data/adb/modules/droidspaces_lkm。

# ---- 以下为各模块的加载顺序与原因 ----
# 加载顺序有讲究:
#   1) lkm4ctr       - PID/UTS/IPC namespace, Droidspaces 的硬性前提
#   2) devtmpfs_lkm  - 注册 devtmpfs (Droidspaces 靠 /proc/filesystems 判断)
#   3) ip6table_nat  - IPv6 NAT
#   4) macvlan       - 容器独立局域网 IP
#   5) vkms          - 虚拟 DRM 设备, 提供 /dev/dri/renderD128
#
# vkms 是 anland / wayland 桌面的前提:
#   Hyprland 和 KWin 的 Wayland 后端要一个能 gbm_create_device() 的
#   DRM render node。厂商内核没开 CONFIG_DRM_VGEM / CONFIG_DRM_VKMS,
#   只有 card0 (display controller), 没有 render 节点。
#
#   为什么是 vkms 而不是 vgem: Mesa 的 GBM 后端按 DRM driver 名字找 dri
#   驱动, 有 vkms_dri.so 却**没有** vgem_dri.so。用 vgem 时 Hyprland 停在
#     openRenderNode got drm device /dev/dri/renderD128
#     CRIT: Couldn't open a gbm device   (OpenGL.cpp:351)
#   vkms 是内核自带的虚拟 KMS 驱动 (card + render + CRTC + plane), 配
#   kms_swrast_dri.so 就能软件渲染出帧。
#
#   本仓库对 vkms 打了一个补丁: 上游 driver_features 只有
#   MODESET|ATOMIC|GEM, 不建 render node; 加上 DRIVER_RENDER 后才会生成
#   /dev/dri/renderD128。见 extra/vkms/Makefile 的说明。
#
#   必须在容器启动前加载, 否则 Droidspaces 扫描 /dev 时看不到它。
#
# devtmpfs_lkm 必须带 devtmpfs_probe=2:
#   默认 probe=0 会启动 kthread 并安装 device_add/device_del inline hook,
#   那套代码会改写内核只读段。实测在开机阶段用默认参数加载会导致卡开机。
#   probe=2 只注册文件系统, 不碰 hook —— 这正是 Droidspaces 需要的全部,
#   因为它只检查 /proc/filesystems 里有没有 devtmpfs。

MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
LOG="/data/local/tmp/droidspaces-lkm.log"

: > "$LOG"
echo "=== Droidspaces LKM $(date) ===" >> "$LOG"
echo "kernel:  $(uname -r)" >> "$LOG"
echo "moddir:  $MODDIR" >> "$LOG"

# 从内核版本推导 KMI 标签, 例如 android14-6.1
# 6.1.157-android14-11-o-g... -> android14-6.1
KREL=$(uname -r)
KMI=""
for tag in android12-5.10 android13-5.10 android13-5.15 android14-5.15            android14-6.1 android15-6.6 android16-6.12 android17-6.18; do
    case "$KREL" in
        *"${tag%-*}"*"-${tag#*-}"*|*"-$tag"*) KMI="$tag"; break ;;
    esac
done

# 识别失败时不要放弃，也不要把系统属性当第一依据。
#
# 内核主版本才是硬约束：6.1 只可能是 android14，6.6 只可能是 android15。
# 有些 ROM 会伪造 ro.build.version.release（本机实测报 17、sdk 37，而内核是
# 6.1），拿属性当主依据会推出 android17-6.1 这种根本不存在的组合。
#
# 所以先用内核版本定候选，只有 5.10（12 或 13）、5.15（13 或 14）这种真的
# 有两代共用的才用属性消歧。
if [ -z "$KMI" ]; then
    major=$(echo "$KREL" | grep -oE '^[0-9]+[.][0-9]+' | head -1)
    android=$(echo "$KREL" | grep -oE 'android[0-9]+' | head -1)

    if [ -z "$android" ]; then
        case "$major" in
            5.10) android="android12 android13" ;;
            5.15) android="android13 android14" ;;
            6.1)  android="android14" ;;
            6.6)  android="android15" ;;
            6.12) android="android16" ;;
            6.18) android="android17" ;;
            *)    android="" ;;
        esac

        # 有多个候选时才看系统属性；取不到就保持第一个（较老的那一代）
        if [ "$(echo $android | wc -w)" -gt 1 ]; then
            rel=$(getprop ro.build.version.release 2>/dev/null | grep -oE '^[0-9]+')
            [ -z "$rel" ] && rel=$(getprop ro.build.version.sdk 2>/dev/null)
            case "$rel" in
                31|32|12) pick=android12 ;;
                33|13)    pick=android13 ;;
                34|14)    pick=android14 ;;
                35|15)    pick=android15 ;;
                36|16)    pick=android16 ;;
                37|17)    pick=android17 ;;
                *)        pick="" ;;
            esac
            # 只接受候选集里有的那一代
            for c in $android; do
                [ "$c" = "$pick" ] && { android="$pick"; break; }
            done
        fi
        android=$(echo "$android" | cut -d" " -f1)
    fi
    [ -n "$android" ] && [ -n "$major" ] && KMI="$android-$major"
fi
echo "kmi:     ${KMI:-未识别}" >> "$LOG"

# 选 ko: 优先精确 KMI, 否则退回目录里唯一的一组
# 读 .ko 的 vermagic，和 uname -r 比"主版本.次版本"。只在无法确定 KMI
# 时用，作为最后一道防线 —— 版本对不上的模块 insmod 必然失败。
ko_vermagic_ok() {
    local ko="$1"
    local vm kmaj
    # grep -ao 在所有 Android 上都有；strings 不一定。
    vm=$(grep -ao 'vermagic=[^ ]*' "$ko" 2>/dev/null | head -1 | sed 's/^vermagic=//')
    [ -z "$vm" ] && return 1
    kmaj=$(echo "$(uname -r)" | grep -oE '^[0-9]+[.][0-9]+')
    case "$vm" in
        *" $kmaj "*|"$kmaj "*|*" $kmaj."*|"$kmaj."*) return 0 ;;
    esac
    return 1
}


find_ko() {
    local base="$1"
    local f="$MODDIR/ko/$base-$KMI.ko"
    if [ -n "$KMI" ] && [ -f "$f" ]; then echo "$f"; return 0; fi
    # 不再"随便挑一个 KMI 的 ko"。之前 KMI 没识别出来时，ls | head -1 会
    # 挑到别的 KMI，insmod 必然 unknown symbol，用户看到"所有模块都装不上"，
    # 真正原因却被掩盖了（见 issues/1）。
    #
    # 仅当这个模块在目录里只有一份、且 vermagic 与本机内核一致时才用它。
    local all
    all=$(ls "$MODDIR/ko/$base"-*.ko 2>/dev/null)
    [ -z "$all" ] && return 1
    if [ "$(echo "$all" | wc -l)" -ne 1 ]; then
        echo "[MISS] $base: KMI=${KMI:-未识别}，目录里有多份候选，拒绝猜" >> "$LOG"
        return 1
    fi
    if ! ko_vermagic_ok "$all"; then
        echo "[MISS] $base: KMI=${KMI:-未识别}，$(basename "$all") 的 vermagic 与 $(uname -r) 不符" >> "$LOG"
        return 1
    fi
    echo "$all"
    return 0
}

load_mod() {
    local base="$1" params="$2"
    local ko
    if ! ko=$(find_ko "$base"); then
        echo "[MISS] $base (KMI=${KMI:-?})" >> "$LOG"
        return 1
    fi
    local name
    name=$(basename "$ko" .ko)

    # 先验 vermagic：KMI 选错时 insmod 只会报 "unknown symbol in module"，
    # 把"模块对不上内核"这条真因埋掉（issues/1 就是这么被误判的）。
    if ! ko_vermagic_ok "$ko"; then
        local vm
        vm=$(grep -ao 'vermagic=[^ ]*' "$ko" 2>/dev/null | head -1 | sed 's/^vermagic=//')
        echo "[FAIL] $base: $(basename "$ko") 的 vermagic (${vm:-未知}) 与内核 $(uname -r) 不匹配，跳过" >> "$LOG"
        return 1
    fi

    # 判断是否已加载: 用模块名而不是文件名, 因为文件名带 KMI 后缀
    if grep -q "^${base} " /proc/modules 2>/dev/null; then
        echo "[SKIP] $base 已加载" >> "$LOG"
        return 0
    fi

    local out
    if [ -n "$params" ]; then
        out=$(insmod "$ko" $params 2>&1)
    else
        out=$(insmod "$ko" 2>&1)
    fi

    if [ $? -eq 0 ] && grep -q "^${base} " /proc/modules 2>/dev/null; then
        echo "[OK]   $base  ($(basename "$ko"))${params:+ $params}" >> "$LOG"
        return 0
    fi
    echo "[FAIL] $base: ${out:-无输出}" >> "$LOG"
    return 1
}

echo "--- 加载 ---" >> "$LOG"
load_mod lkm4ctr ""
load_mod devtmpfs_lkm "devtmpfs_probe=2"
load_mod ip6table_nat ""
load_mod macvlan ""
load_mod vkms ""

# cgroup 限流仿真（--cpus / --pids-limit）。
# 装 kprobe 并在运行时解析符号，最坏表现是加载失败；
# 放最后，失败不挡前面五个模块。
# 想临时关掉：在模块目录放 disable_pids / disable_cpu。
MODDIR="/data/adb/modules/droidspaces_lkm"
[ -f "$MODDIR/disable_pids" ] || load_mod droid_lkm_pids ""
[ -f "$MODDIR/disable_cpu" ] || load_mod droid_lkm_cpu ""

# 走到这里说明加载流程跑完了。清零开机计数器，表示本次开机是成功的。
# （只看"脚本跑完"，不逐个校验模块是否 insmod 成功：模块本身加载失败不会
# 导致 panic，不需要触发自动禁用那套保护。）
rm -f /data/adb/droidspaces_lkm.bootcount

echo "--- lsmod ---" >> "$LOG"
lsmod | grep -E '^(lkm4ctr|devtmpfs_lkm|ip6table_nat|macvlan|vkms|droid_lkm_pids|droid_lkm_cpu)' >> "$LOG" 2>/dev/null

echo "--- 能力验证 ---" >> "$LOG"
unshare -pf true 2>/dev/null \
    && echo "[OK] PID namespace" >> "$LOG" \
    || echo "[FAIL] PID namespace" >> "$LOG"
unshare -i true 2>/dev/null \
    && echo "[OK] IPC namespace" >> "$LOG" \
    || echo "[FAIL] IPC namespace" >> "$LOG"
grep -q devtmpfs /proc/filesystems 2>/dev/null \
    && echo "[OK] devtmpfs" >> "$LOG" \
    || echo "[--] devtmpfs 未注册" >> "$LOG"
grep -q "^droid_lkm_pids " /proc/modules 2>/dev/null \
    && echo "[OK] pids 控制器仿真" >> "$LOG" \
    || echo "[--] pids 控制器仿真未加载" >> "$LOG"
grep -q "^droid_lkm_cpu " /proc/modules 2>/dev/null \
    && echo "[OK] cpu.max 仿真" >> "$LOG" \
    || echo "[--] cpu.max 仿真未加载" >> "$LOG"

# vkms 提供的 render node: anland / wayland 合成器的前提
if [ -e /dev/dri/renderD128 ]; then
    echo "[OK] /dev/dri/renderD128 (vkms)" >> "$LOG"
else
    echo "[--] /dev/dri/renderD128 缺失 (anland 桌面不可用)" >> "$LOG"
fi

echo "=== 完成 ===" >> "$LOG"
exit 0
