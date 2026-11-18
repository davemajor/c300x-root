#!/bin/bash
# Reproducible build of the C300X recovery U-Boot from pristine mainline sources.
#
# This produces the two files you load over USB (SDP) to get a `ums` disk-mode
# U-Boot running in the unit's RAM. It touches nothing on the device.
#
# What it builds:
#   u-boot-with-spl.imx   stage 1: SPL + U-Boot, loaded by the i.MX6 boot ROM over SDP
#   u-boot.uim            stage 2: full U-Boot, loaded by the SPL over SDP
#
# It is plain mainline U-Boot v2018.07 for the "Mamoj" board (imx6dl_mamoj,
# upstream since v2018.07) plus two small changes, both in c300x-mamoj.patch:
#   1. `no-1-8-v` on the eMMC node  -> keep 3.3 V signalling so this board's
#      eMMC enumerates reliably under U-Boot.
#   2. a dtc pre-processing fix     -> lets this old tree build with a modern CPP.
# No BTicino/Legrand code is involved. See README.md for the licensing note.
#
# Requirements: git, an arm-linux-gnueabihf- cross toolchain, make, bison, flex,
# libssl-dev, device-tree-compiler. Tested on Debian with gcc 14.
#
#   ./build-uboot.sh [workdir]        (default workdir: ./build)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/build}"
CROSS="${CROSS_COMPILE:-arm-linux-gnueabihf-}"
TEXT_BASE=0x17800000          # CONFIG_SYS_TEXT_BASE for imx6dl_mamoj

command -v "${CROSS}gcc" >/dev/null || { echo "missing ${CROSS}gcc cross toolchain"; exit 1; }

mkdir -p "$WORK"; cd "$WORK"
if [ ! -d u-boot ]; then
  git clone --depth 1 --branch v2018.07 https://source.denx.de/u-boot/u-boot.git
fi
cd u-boot
git checkout -- . ; git clean -fdq        # pristine v2018.07
git apply "$HERE/c300x-mamoj.patch"
install -m 0755 "$HERE/fix_dtc_include.sh" scripts/fix_dtc_include.sh

make mrproper
make imx6dl_mamoj_defconfig
make CC="${CROSS}gcc -mfloat-abi=soft" CROSS_COMPILE="$CROSS" HOSTCFLAGS="-fcommon" \
     -j"$(nproc)" u-boot-with-spl.imx

# stage 2 image (legacy mkimage "firmware" wrap of u-boot.bin)
tools/mkimage -A arm -T firmware -C none -a "$TEXT_BASE" -e "$TEXT_BASE" \
     -n "C300X mamoj u-boot" -d u-boot.bin u-boot.uim

cp -f u-boot-with-spl.imx u-boot.uim "$HERE/"
cd "$HERE"
echo "== built =="
( shasum -a 256 u-boot-with-spl.imx u-boot.uim 2>/dev/null || sha256sum u-boot-with-spl.imx u-boot.uim )
echo "Compare against SHA256SUMS (a byte-exact match is not guaranteed across"
echo "toolchains, but the images must work identically). Flash-test before sharing."
