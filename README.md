# Rockchip Backup & Restore Wizard

An interactive bash script for backing up and restoring eMMC partitions on
Rockchip RV1106-based devices (e.g. Anycubic Kobra X / K4P) via USB MASKROM
mode. The script reads the device's `env` partition at runtime to discover the
partition layout, so it adapts automatically to any board configuration.

## Quick Start

```bash
# Back up all partitions from a device in MASKROM mode
./rockchip_backup_restore_wizard.sh backup -d ~/kobra_backup all

# Restore just the app partition from a previous backup
./rockchip_backup_restore_wizard.sh restore -d ~/kobra_backup app

# Interactive mode — prompts you to select partitions
./rockchip_backup_restore_wizard.sh backup
./rockchip_backup_restore_wizard.sh restore
```

## Prerequisites

### Hardware

- A Rockchip RV1106-based device (e.g. Anycubic Kobra X / K4P)
- USB data cable (charge-only cables won't work)
- Physical access to the MASKROM button on the board

### Software

| Tool | Source |
|------|--------|
| **xrock** | [github.com/xboot/xrock](https://github.com/xboot/xrock) |
| **bash** >= 4.0 | Needed for associative arrays |
| **strings** | Part of `binutils` (pre-installed on macOS and most Linux) |
| **bc** | Used for byte formatting |

#### Installing xrock

[xrock](https://github.com/xboot/xrock) is an open-source (MIT) command-line
tool for communicating with Rockchip SoCs in MASKROM and loader modes.

**Linux:**

```bash
sudo apt install libusb-1.0-0-dev
git clone https://github.com/xboot/xrock.git
cd xrock && make
sudo make install
```

**macOS:**

```bash
brew install libusb
git clone https://github.com/xboot/xrock.git
cd xrock && make
sudo cp xrock /usr/local/bin/
```

Verify with `xrock version` — it should print an error about no devices found,
which means xrock itself is working fine. The script auto-detects xrock in your
`PATH` or at `/usr/local/bin/xrock` and `/opt/homebrew/bin/xrock`, or you can
pass `-x /path/to/xrock`.

### Loader Binaries

Place these in the same directory as the script:

| File | Purpose |
|------|---------|
| `rv1106_download_loader.bin` | Combined DDR init + USB plug loader (**primary**). Any `.bin` loader can be substituted via `-l`. |
| `rv1106_ddr_*.bin` | DDR init blob (**fallback** if the download loader fails) |
| `rv1106_usbplug_*.bin` | USB plug firmware (used with the DDR blob as a two-stage fallback) |

These are available from the [Rockchip rkbin repository](https://github.com/rockchip-linux/rkbin/tree/master/bin/rv11)
under `bin/rv11/` — use the latest versions. They can also be found in the
LuckFox Pico SDK (`tools/` directory) or bundled with some vendor firmware
packages.

Run `./installer.sh` to fetch the DDR + USB plug fallback pair automatically:

```bash
./installer.sh          # downloads into the script directory
./installer.sh -d DIR   # downloads into DIR instead
./installer.sh -f       # re-download even if the files already exist
```

`rv1106_download_loader.bin` isn't published as a standalone file upstream
(it's built by merging DDR+HPMCU+SPL blobs with rkbin's `boot_merger` tool),
so `installer.sh` doesn't fetch it — the repo already ships one, and the
fallback pair above is what `installer.sh` gets you if you need to replace it.

The script tries the download loader first, then automatically falls back to
`xrock maskrom <ddr> <usbplug> --rc4-off`.

## Usage

```
rockchip_backup_restore_wizard.sh <backup|restore> [OPTIONS] [PARTITION...]
```

| Option | Description | Default |
|--------|-------------|---------|
| `-d DIR` | Directory for partition images (save to / load from) | Script directory |
| `-l FILE` | Loader binary for MASKROM download mode | `rv1106_download_loader.bin` |
| `-x PATH` | Path to xrock binary | Auto-detected |
| `-h` | Show help | — |

### Backup

Reads partitions from a device in MASKROM mode and saves them as raw images.
The `env` partition is always saved first — the script needs it to locate
everything else.

```bash
./rockchip_backup_restore_wizard.sh backup                    # interactive
./rockchip_backup_restore_wizard.sh backup app data           # specific partitions
./rockchip_backup_restore_wizard.sh backup -d ~/backups all   # everything
```

### Restore

Writes partition images back to a device in MASKROM mode. Available images are
shown color-coded (green = found, yellow = missing), and writing requires
typing `YES` to confirm. If no local `env` image is found, the script will
offer to read it directly from the device.

```bash
./rockchip_backup_restore_wizard.sh restore                        # interactive
./rockchip_backup_restore_wizard.sh restore -d ~/backups app data  # specific partitions
./rockchip_backup_restore_wizard.sh restore -d ~/backups all       # everything
```

## Walkthrough

### 1. Enter MASKROM mode

1. Power off the device.
2. Hold the MASKROM/BOOT button (on the Kobra X, accessible with the bottom
   cover removed).
3. Connect the USB cable and power on while holding the button for 2-3 seconds.
4. Release.

Verify: `xrock version` should print the chip ID (e.g. "RV1106").

> When no valid bootloader is found (or the MASKROM pin is held low), the SoC's
> boot ROM enters MASKROM mode — a minimal USB state where the host uploads DDR
> init and USB plug firmware to gain flash access. See the
> [Rockchip Boot Option wiki](https://opensource.rock-chips.com/wiki_Boot_option).

### 2. Back up

```bash
./rockchip_backup_restore_wizard.sh backup -d ~/kobra_backup all
```

Example output:

```
============================================================
  RV1106 Partition Backup
============================================================

[+] Preflight OK
[+] Download mode entered via rv1106_download_loader.bin
[+] Reading env partition (32K) to discover partition table...
[i]   mmcblk0:32K(env),512K@32K(idblock),512K(uboot_a),...,512M(app),6600M(data)

[i] Parsed partition layout:
  NAME         SIZE       SECTOR       SECTOR (hex)
  env          32K        0            0x00000000
  idblock      512K       64           0x00000040
  ...
  app          512M       1576960      0x00181000
  data         6600M      2625536      0x00281000

[+] [1/13] Backing up idblock...
[+] idblock read successfully (512K)
...
[+] [13/13] Backing up data...
[!] data is 6600M — this may take several minutes...
[+] data read successfully (6.4G)

============================================================
  BACKUP COMPLETE — 14 partition(s) saved
============================================================
```

### 3. Restore

```bash
./rockchip_backup_restore_wizard.sh restore -d ~/kobra_backup app data
```

The script parses `env` for partition offsets, shows image availability, asks
for `YES` confirmation, writes the selected partitions, and resets the device.

## Directory Layout

After a full backup:

```
├── rockchip_backup_restore_wizard.sh
├── rv1106_download_loader.bin
├── rv1106_ddr_*.bin
├── rv1106_usbplug_*.bin
├── env
├── idblock
├── uboot_a
├── uboot_b
├── boot_a / boot_b
├── system_a / system_b
├── oem_a / oem_b
├── userdata
├── app                                 # ~512M
└── data                                # ~6.6G
```

Images are named exactly as their partition name in the `blkdevparts=` string
(no `.img` extension). The script also accepts `<name>.img` during restore.

## How It Works

### MASKROM Mode

Rockchip SoCs have a factory-burned boot ROM that checks for bootable code on
eMMC, SPI flash, and SD in a fixed order. If nothing valid is found — or the
MASKROM pin is held low — it enters **MASKROM mode**: a minimal USB peripheral
state where the host can upload initialization code and read/write flash.

```
Boot ROM (on-chip) → Pre-bootloader (SPL @ 0x40) → U-Boot → Kernel → Rootfs
```

Pressing the MASKROM button prevents the ROM from finding the pre-bootloader,
so it waits for USB input. This script uploads the loader to bridge that gap.

### The env Partition

The first 32K of eMMC contains U-Boot environment variables as null-terminated
`key=value` pairs. The critical one is `blkdevparts=`, which defines the full
partition table:

```
blkdevparts=mmcblk0:32K(env),512K@32K(idblock),512K(uboot_a),512K(uboot_b),
256K(misc),32K(boot_a),32K(boot_b),48M(system_a),48M(system_b),32M(oem_a),
32M(oem_b),256K(userdata),512M(app),6600M(data)
```

Format: `SIZE[@OFFSET](NAME)` — sizes use K/M/G suffixes, and the optional
`@OFFSET` sets an absolute byte position (otherwise partitions are placed
sequentially). This string is passed to the Linux kernel as a boot parameter.
See the [kernel docs](https://www.kernel.org/doc/html/latest/block/cmdline-partition.html).

### Partition Table Parsing

The script extracts `blkdevparts=` from the env image with `strings | grep`,
then walks each entry to build three lookup tables: partition names (ordered),
sector offsets, and human-readable sizes. All xrock operations use 512-byte
sector addressing (`sector = byte_offset / 512`).

### Download Mode Handshake

Entering download mode is a two-step process:

1. **DDR init** — the boot ROM can't access DDR until initialization code runs,
   so the loader programs the DDR controller with board-specific timing.
2. **USB plug** — once DDR is available, USB plug firmware is loaded to give
   the host read/write access to flash.

```bash
# Primary method
xrock download rv1106_download_loader.bin

# Fallback: two-file method
xrock maskrom rv1106_ddr_*.bin rv1106_usbplug_*.bin --rc4-off
```

The `--rc4-off` flag disables RC4 encryption on the USB transport, required for
some SoC revisions including the RV1106G3.

## Partition Layout Reference

Typical layout for an RV1106-based printer (Anycubic Kobra X / K4P):

| # | Partition | Size | Filesystem | Notes |
|---|-----------|------|------------|-------|
| 1 | `env` | 32K | Raw | Boot environment, partition table |
| 2 | `idblock` | 512K | Raw | Pre-bootloader (SPL), starts at @32K |
| 3 | `uboot_a` | 512K | Raw | U-Boot (A slot) |
| 4 | `uboot_b` | 512K | Raw | U-Boot (B slot) |
| 5 | `misc` | 256K | Raw | A/B boot control metadata |
| 6 | `boot_a` | 32K | DTB | Device Tree Blob (A slot) |
| 7 | `boot_b` | 32K | DTB | Device Tree Blob (B slot) |
| 8 | `system_a` | 48M | Squashfs | Root filesystem (A slot, read-only) |
| 9 | `system_b` | 48M | Squashfs | Root filesystem (B slot, read-only) |
| 10 | `oem_a` | 32M | Squashfs | OEM overlay (A slot, read-only) |
| 11 | `oem_b` | 32M | Squashfs | OEM overlay (B slot, read-only) |
| 12 | `userdata` | 256K | ext4 | Small user data partition |
| 13 | `app` | 512M | ext4 | Application binaries, configs, libs |
| 14 | `data` | 6600M | ext2 | Gcodes, logs, timelapse, settings |

The device uses A/B partitioning for OTA failover — `system`, `oem`, `uboot`,
and `boot` each have two slots, with `misc` tracking the active one. The
squashfs partitions are read-only; `app`, `data`, and `userdata` are writable.

## xrock Command Reference

| Command | Description |
|---------|-------------|
| `xrock ready` | Check if a device is connected |
| `xrock download <loader>` | Upload loader to enter download mode |
| `xrock maskrom <ddr> <usbplug> [--rc4-off]` | Two-stage MASKROM init |
| `xrock flash read <sector> <count> <file>` | Read sectors to file |
| `xrock flash write <sector> <file>` | Write file to flash |
| `xrock flash erase <sector> <count>` | Erase sectors |
| `xrock reset` | Reset device (normal boot) |
| `xrock reset maskrom` | Reset into MASKROM mode |
| `xrock version` | Print chip ID |

[github.com/xboot/xrock](https://github.com/xboot/xrock) — MIT licensed,
supports RV1106, RK3399, RK3588, RK3568, and many others.

Rockchip's official [`upgrade_tool`](https://opensource.rock-chips.com/wiki_Upgradetool)
provides similar functionality but is closed-source and uses a different command
interface. This script uses xrock for its direct sector-level access and
cross-platform support.

## Troubleshooting

**No device detected**
- Power off the device *before* entering MASKROM mode.
- Hold the MASKROM button *before* powering on.
- Use a data cable, not a charge-only cable.
- On Linux, you may need a udev rule:
  ```
  # /etc/udev/rules.d/51-rockchip.rules
  SUBSYSTEM=="usb", ATTR{idVendor}=="2207", MODE="0666", GROUP="plugdev"
  ```

**Loader failed**
- The loader may not match your SoC revision — the script falls back to the
  two-file method automatically.
- Try a different loader with `-l /path/to/loader.bin`.

**Device not ready after download mode**
- The 2-second post-load delay may not be enough. Run the script again — the
  device may already be in download mode.
- Avoid USB hubs; connect directly to a port on the computer.

**No `blkdevparts=` found in env**
- The env partition may be corrupted. Try reading more with
  `xrock flash read 0 128 env`.
- Verify the device uses the standard Rockchip env format.

**Slow transfers**
- The `data` partition (6.6G) takes 10-20 minutes over USB 2.0. This is a raw
  sector copy with no compression.

**Wrong data restored**
- The `env` image used for parsing must come from the same device (or one with
  an identical layout). Don't mix images across devices.

## Safety

- **Back up before restoring.** Writes are not reversible. Wrong image + wrong
  partition = unbootable device.
- **The `env` partition is critical** — it holds the partition table and boot
  config. The script saves it automatically during backup.
- **A/B partitions:** Writing one slot is fine (the device boots from the active
  slot), but restore both for a complete recovery.
- **`data` uses ext2** (no journal) and may be marked unclean. Backup captures
  the raw state as-is.
- **Restore requires typing `YES`.** Intentional — it's destructive.
- **`set -euo pipefail`** — any failure aborts immediately to prevent partial
  writes.

## References

- [Rockchip Boot Option Wiki](https://opensource.rock-chips.com/wiki_Boot_option) — boot sequence, MASKROM mode, ROM boot flow
- [Rockchip rkbin](https://github.com/rockchip-linux/rkbin) — DDR blobs, USB plug firmware, loaders (`bin/rv11/` for RV1106)
- [xrock](https://github.com/xboot/xrock) — open-source Rockchip USB flash tool (MIT)
- [upgrade_tool Wiki](https://opensource.rock-chips.com/wiki_Upgradetool) — Rockchip's official flash utility
- [rkdeveloptool](https://opensource.rock-chips.com/wiki_Rkdeveloptool) — alternative open-source flash tool
- [Kernel blkdevparts](https://www.kernel.org/doc/html/latest/block/cmdline-partition.html) — `blkdevparts=` parameter format
- [LuckFox Pico Wiki](https://wiki.luckfox.com/Luckfox-Pico/Luckfox-Pico-Ultra-W/) — LuckFox Pico Ultra W (same RV1106G3 SoC)
- [Anycubic Kobra 3 eMMC dump](https://github.com/Bushmills/Anycubic-Kobra-3-rooted/discussions/5#discussioncomment-11033503) — USB dump method without soldering
