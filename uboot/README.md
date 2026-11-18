# Recovery U-Boot for the Classe 300X (i.MX6 Solo / "Mamoj")

Two small files you load into the unit's RAM over USB. They let you run a
`ums` (USB mass-storage) U-Boot so the eMMC appears as a disk on your computer.
Nothing here is written to the device's flash — the stock bootloader is never
touched.

| File | Stage | Loaded by | SHA-256 |
|---|---|---|---|
| `u-boot-with-spl.imx` | 1 | i.MX6 boot ROM (SDP) | `ce887498…cdb444` |
| `u-boot.uim` | 2 | the SPL (SDP) | `df512aaf…9df0423` |

Full hashes are in `SHA256SUMS`.

## What these actually are

Plain **mainline U-Boot v2018.07**, `imx6dl_mamoj_defconfig`. The 300X board is
the Amarula "Mamoj", which has been in upstream U-Boot since v2018.07 — so you
are not reverse-engineering a bootloader, you are building a stock one for a
supported board. On top of pristine v2018.07 there are exactly two changes, both
in `c300x-mamoj.patch`:

1. **`no-1-8-v` on the eMMC node** — keeps the SD/MMC controller at 3.3 V
   signalling so this board's eMMC enumerates reliably under U-Boot.
2. **a dtc pre-processing fix** (`fix_dtc_include.sh` + a one-line
   `scripts/Makefile.lib` hook) — lets this 2018 tree build with a modern CPP.
   Build-system only; it does not change the bootloader's behaviour.

The relevant config (`CONFIG_SPL_USB_SDP_SUPPORT=y`) is what makes the SPL
re-enter SDP and wait for stage 2, which is why you load two files.

## How hard is it to build?

Not hard. `./build-uboot.sh` clones v2018.07, applies the patch, builds, and
wraps stage 2 — one command, a few minutes, on any machine with an
`arm-linux-gnueabihf-` toolchain. The only non-obvious parts (the `no-1-8-v`
eMMC property and the dtc fix) are already captured in the patch.

```sh
./build-uboot.sh          # outputs u-boot-with-spl.imx and u-boot.uim here
```

A byte-exact match to the published hashes is not guaranteed across toolchains,
but the images must work identically. Flash-test any build before sharing it.

## Is it OK to distribute the binaries?

Yes. U-Boot is **GPL-2.0+**. You may redistribute the compiled images as long as
you also make the corresponding source available — which is just "mainline
U-Boot v2018.07 plus `c300x-mamoj.patch`", both provided here. There is no
BTicino, Legrand or NXP proprietary code in these images; the i.MX6 boot ROM
that loads stage 1 stays in the chip and is not redistributed. Keep this README,
the patch and `build-uboot.sh` alongside the binaries to stay compliant.

## Files

- `u-boot-with-spl.imx`, `u-boot.uim` — the images (stage 1, stage 2)
- `SHA256SUMS` — checksums
- `c300x-mamoj.patch` — the two source changes vs. pristine v2018.07
- `fix_dtc_include.sh` — helper invoked by the patched `scripts/Makefile.lib`
- `build-uboot.sh` — reproducible build from mainline
