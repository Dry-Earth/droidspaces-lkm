#!/bin/bash
# Build every module on the runner with the exact KDIR and manifest tools.
set -uo pipefail

ROOT=${ROOT:-$PWD}
TOOLS=${TOOLS:-$ROOT/tools}
KMI=${KMI:-android15-6.6}
KDIR=${KDIR:-$ROOT/kernel/out}
OUT=${OUT:-$ROOT/out}

export PATH="$TOOLS/clang/bin:$TOOLS/build-tools/bin:$TOOLS/kernel-build-tools/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLS/build-tools/lib64:$TOOLS/kernel-build-tools/lib64:${LD_LIBRARY_PATH:-}"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export KSRC_OVERRIDE=${KSRC_OVERRIDE:-$ROOT/kernel}
export LKM4CTR_DIR=${LKM4CTR_DIR:-$ROOT/lkm4ctr}
export KBUILD_MODPOST_WARN=1

echo "==> clang: $(clang --version | head -n1)"
test -s "$KDIR/Module.symvers"
test -d "$KSRC_OVERRIDE/drivers"
test -d "$LKM4CTR_DIR/vendor"

mkdir -p "$OUT"

python3 "$ROOT/ci/adapt-lkm4ctr.py" "$KSRC_OVERRIDE" "$LKM4CTR_DIR"

bash "$ROOT/scripts/build_modules.sh" "$KMI" "$KDIR" "$ROOT" "$OUT"
rc=$?
echo "==> build_modules exit=$rc"
ls -lh "$OUT" 2>/dev/null || true
exit 0
