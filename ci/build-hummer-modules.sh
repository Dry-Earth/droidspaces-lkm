#!/bin/bash
# Build every droidspaces module against one exact hummer KDIR.
#
# Runs inside the DDK container.  The kernel tree is mounted at /work/kernel
# and its O= build output at /work/kernel/out; lkm4ctr is mounted at
# /tmp/lkm4ctr after the caller applied this repository's patches.
set -uo pipefail

KMI=${KMI:-android15-6.6}
KDIR=${KDIR:-/work/kernel/out}
OUT=${OUT:-/work/out}
export PATH="/work/clang-stock/bin:$PATH"
export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export KSRC_OVERRIDE=${KSRC_OVERRIDE:-/work/kernel}
export KBUILD_MODPOST_WARN=1

echo "==> clang: $(clang --version | head -n1)"
test -s "$KDIR/Module.symvers" || { echo "::error::missing $KDIR/Module.symvers"; exit 1; }
test -d "$KSRC_OVERRIDE/drivers" || { echo "::error::missing kernel source $KSRC_OVERRIDE"; exit 1; }
test -d /tmp/lkm4ctr/vendor || { echo "::error::missing /tmp/lkm4ctr/vendor"; exit 1; }

mkdir -p "$OUT"

echo "==> adapt lkm4ctr to the target kernel ABI"
python3 /work/ci/adapt-lkm4ctr.py "$KSRC_OVERRIDE" /tmp/lkm4ctr

bash /work/scripts/build_modules.sh "$KMI" "$KDIR" /work "$OUT"
rc=$?

echo "==> build_modules exit=$rc"
ls -lh "$OUT" 2>/dev/null || true

# Keep going so the workflow can package and report which payloads exist.
# ci/package-hummer.py refuses to produce a zip without lkm4ctr.
exit 0
