#!/bin/bash
# Build the exact KDIR on the runner itself, using only manifest-pinned tools.
set -euxo pipefail

ROOT=${ROOT:-$PWD}
TOOLS=${TOOLS:-$ROOT/tools}
export PATH="$TOOLS/clang/bin:$TOOLS/build-tools/bin:$TOOLS/kernel-build-tools/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLS/build-tools/lib64:$TOOLS/kernel-build-tools/lib64:${LD_LIBRARY_PATH:-}"
export BISON_PKGDATADIR="$TOOLS/build-tools/common/bison"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-

EXPECTED_CLANG=${EXPECTED_CLANG:-r596125}
clang --version | head -n1
clang --version | grep -q "$EXPECTED_CLANG" || {
	echo "::error::clang does not match $EXPECTED_CLANG"
	exit 1
}

cd "$ROOT"
[ -e sm8750 ] || ln -s kernel sm8750
cd kernel
mkdir -p out

if [ -s "$ROOT/build-config/stock.config" ]; then
	echo "==> baseline config: extracted from boot.img"
	cp "$ROOT/build-config/stock.config" out/.config
else
	echo "::error::missing build-config/stock.config"
	exit 1
fi
echo "==> baseline config: $(grep -c '^CONFIG_' out/.config) lines"

make O=out olddefconfig
grep -E '^CONFIG_(LOCALVERSION|CFI_CLANG|MODVERSIONS|MODULES|SMP|PREEMPT)' out/.config || true

make O=out -j"$(nproc)" KERNELRELEASE="$EXPECTED_RELEASE" CC="ccache clang" Image modules

test -s out/Module.symvers
test -s out/System.map
test -s out/arch/arm64/boot/Image
grep -q "$EXPECTED_RELEASE" out/include/generated/utsrelease.h
grep -a -q "Linux version $EXPECTED_RELEASE" out/arch/arm64/boot/Image
echo "==> KDIR ready: $ROOT/kernel/out"
