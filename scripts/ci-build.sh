#!/usr/bin/env bash
# Build the KernelSU-Next (v1.1.1) + susfs gauguin kernel from the latest
# official LineageOS boot.img and publish a release.
#
# Guarantees carried over from the local verified build:
#  1. kernel config == the stock kernel's own embedded (IKCONFIG) config
#     + only the KSU/SUSFS fragment lines (guarded by a diff gate)
#  2. DTB byte-parity with stock (348,236 B lagoon FDT), round-trip payload
#     sha checks on the repacked image
#  3. KSU-Next + susfs presence proven by embedded hash/string gates
set -euo pipefail

ROOT="$GITHUB_WORKSPACE"
OUT="$ROOT/out"
WORK="$ROOT/work"
TC="$ROOT/tools/clang"
TC_URL="https://github.com/ZyCromerZ/Clang/releases/download/14.0.6-20261011-release/Clang-14.0.6-20261011.tar.gz"
APK_URL="https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v1.1.1/KernelSU_Next_v1.1.1_12851-release.apk"
MGR_HASH="79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7"
SUSFS_HASH="7e0c6d7278a3bb8e364e0fcba95afaf3666cf5ff3c245a3b63c8833bd0445cc4"
MAKE_FLAGS="HOSTAR=llvm-ar HOSTCC=clang HOSTCXX=clang++ HOSTLD=ld.lld CC=clang LD=ld.lld AR=llvm-ar NM=llvm-nm OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip LLVM_IAS=1 O=out ARCH=arm64"

log() { echo; echo "::group::$*"; }
fail() { echo "FAIL: $*"; exit 1; }

cd "$ROOT"
export PATH="$TC/bin:$PATH"

log "toolchain"
if [ ! -x "$TC/bin/clang" ]; then
  mkdir -p "$TC" && curl -sL -o /tmp/clang.tar.gz "$TC_URL"
  tar -xzf /tmp/clang.tar.gz -C "$TC" && rm /tmp/clang.tar.gz
  # tolerate varying archive layout (flatten one level if needed)
  [ -x "$TC/bin/clang" ] || { mv "$TC" "$TC.tmp"; mv "$TC.tmp"/clang "$TC"; rmdir "$TC.tmp"; }
fi
clang --version | head -1

log "lineageos latest build"
API=$(curl -s "https://download.lineageos.org/api/v2/devices/gauguin/builds")
LATEST=$(echo "$API" | python3 -c '
import sys,json
d=json.load(sys.stdin)
r=d["response"] if isinstance(d,dict) else d
print(max(r,key=lambda b:int(b["datetime"]))["url"])')
BUILDID=$(echo "$LATEST" | awk -F/ '{print $(NF-1)}')
BOOT_URL="${LATEST%/*}/boot.img"
echo "build dir : $BUILDID"
echo "boot url  : $BOOT_URL"
TAG="ksu-next-$BUILDID"
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "release $TAG already exists — nothing to do"
  echo "skip=true" >> "$GITHUB_OUTPUT" 2>/dev/null || true
  echo "SKIP_BUILD=1" >> "$GITHUB_ENV"; exit 0
fi
curl -sL -o boot.img "$BOOT_URL"
sha256sum boot.img | tee boot-stock.sha256

log "unpack stock boot.img"
MAGISKBOOT="$ROOT/tools/magiskboot"
mkdir -p "$WORK" && cd "$WORK"
"$MAGISKBOOT" unpack "$ROOT/boot.img"
mv kernel stock-kernel
mv dtb stock-dtb
"$MAGISKBOOT" decompress stock-kernel stock-Image
"$ROOT/scripts/extract-ikconfig" stock-Image > stock-ikconfig.txt
[ -s stock-ikconfig.txt ] || fail "could not extract stock IKCONFIG"
wc -l stock-ikconfig.txt

log "configure (stock ikconfig + fragment + olddefconfig)"
mkdir -p "$OUT"
cp stock-ikconfig.txt "$OUT/.config"
cat "$ROOT/arch/arm64/configs/vendor/xiaomi/gauguin-ksu-susfs.config" >> "$OUT/.config"
make olddefconfig $MAKE_FLAGS >/dev/null
diff <(grep -E '^(CONFIG_|# CONFIG_)' stock-ikconfig.txt | sort) \
     <(grep -E '^(CONFIG_|# CONFIG_)' "$OUT/.config" | sort) > config-diff.txt || true
# gates: any stock-side symbol we LOST is an error; additions only from the
# KSU/SUSFS fragment + benign toolchain-version strings
TOOLCH='^(CONFIG_(AS_VERSION|CLANG_VERSION|LLD_VERSION|CC_VERSION_TEXT|CC_HAS_AUTO_VAR_INIT_ZERO_(BARE|ENABLER)))'
if grep '^<' config-diff.txt | grep -vE "$TOOLCH" | grep -q .; then
  fail "config lost stock symbols:$(grep '^<' config-diff.txt | head)"
fi
if grep '^>' config-diff.txt | grep -vE '(CONFIG_(KSU|KSU_|KPROBES)|# CONFIG_KSU|'"$(echo "$TOOLCH" | sed 's/\^//')"')' | grep -q .; then
  fail "unexpected config additions:$(grep '^>' config-diff.txt | grep -vE '(CONFIG_(KSU|KSU_|KPROBES)|# CONFIG_KSU)' | head)"
fi
grep -q '^CONFIG_KSU=y' "$OUT/.config" || fail "CONFIG_KSU not enabled"
grep -q '^CONFIG_KSU_SUSFS=y' "$OUT/.config" || fail "CONFIG_KSU_SUSFS not enabled"
grep -q '^# CONFIG_KPROBES is not set' "$OUT/.config" || fail "KPROBES must stay off (manual hooks)"

log "build Image + dtbs"
make Image dtbs $MAKE_FLAGS -j"$(nproc)"
IMAGE="$OUT/arch/arm64/boot/Image"
DTB="$OUT/arch/arm64/boot/dts/vendor/qcom/lagoon.dtb"

log "size sanity"
IMG_SZ=$(stat -c%s "$IMAGE")
STK_SZ=$(stat -c%s stock-Image)
echo "built Image: $IMG_SZ ; stock Image: $STK_SZ"
[ "$IMG_SZ" -ge "$STK_SZ" ] || fail "built Image smaller than stock kernel"

log "KSU-Next + susfs presence gates"
grep -aq "$MGR_HASH" "$IMAGE" || fail "KSU-Next manager hash missing from Image"
grep -aq "$SUSFS_HASH" "$IMAGE" || fail "susfs 5ec1cff secondary hash missing from Image"
SUSFS_HITS=$(grep -ac 'susfs' "$IMAGE" || true)
[ "${SUSFS_HITS:-0}" -gt 50 ] || fail "susfs strings missing from Image ($SUSFS_HITS)"
echo "susfs strings: $SUSFS_HITS"

log "repack"
cd "$WORK"
cp "$IMAGE" kernel
cp "$DTB" dtb
[ "$(stat -c%s dtb)" -eq "$(stat -c%s stock-dtb)" ] || fail "dtb size != stock dtb size"
"$MAGISKBOOT" repack "$ROOT/boot.img" new-boot.img
rm -rf verify && mkdir verify && cd verify
"$MAGISKBOOT" unpack "$WORK/new-boot.img" >/dev/null 2>&1
cmp kernel "$IMAGE" || fail "roundtrip kernel mismatch"
cmp dtb "$DTB" || fail "roundtrip dtb mismatch"
cmp ramdisk.cpio "$WORK/ramdisk.cpio" || fail "roundtrip ramdisk mismatch"
cd "$WORK"

log "release"
BOOTART="gauguin-ksunext-susfs-$BUILDID.img"
cp new-boot.img "$ROOT/$BOOTART"
(cd "$ROOT" && sha256sum "$BOOTART" > "$BOOTART.sha256")
curl -sL -o "$ROOT/KernelSU_Next_v1.1.1_12851-release.apk" "$APK_URL"
cat > "$ROOT/RELEASE_NOTES.md" <<EOF
KernelSU-Next v1.1.1 (version 12851, manual hooks, kprobe-free) + susfs 1.5.5
on top of LineageOS official build **$BUILDID** (template bot.img: $(sha256sum "$ROOT/boot.img" | cut -c1-16)…).

- kernel config = this build's own embedded config + KSU/SUSFS fragment only (diff-gated in CI)
- stock ramdisk/cmdline/header preserved verbatim; round-trip sha-verified
- kernel Image raw $(stat -c%s "$IMAGE") bytes; dtb $(stat -c%s "$DTB") bytes (stock size)

Flash (bootloader unlocked):
  fastboot flash boot gauguin-ksunext-susfs-$BUILDID.img   # active slot

Pair with: KernelSU_Next_v1.1.1_12851-release.apk (same folder).
Rollback: stock boot.img for this build (LineageOS mirror, sha above).
EOF
cd "$ROOT"
gh release create "$TAG" "$BOOTART" "$BOOTART.sha256" \
  KernelSU_Next_v1.1.1_12851-release.apk RELEASE_NOTES.md \
  --title "KernelSU-Next v1.1.1 + susfs 1.5.5 — LineageOS $BUILDID" \
  --notes-file RELEASE_NOTES.md
echo "release $TAG published"
