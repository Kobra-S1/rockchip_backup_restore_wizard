#!/bin/bash
# rockchip_backup_restore_wizard.sh — Backup & restore RV1106 partitions via MASKROM mode
#
# Reads the device's env partition to discover the partition table, then
# lets you choose which partitions to backup or restore.
#
# Prerequisites:
#   - Device connected via USB in MASKROM mode (hold boot button, plug in)
#   - xrock installed and in PATH (https://github.com/xboot/xrock)
#   - Loader binary: rv1106_download_loader.bin (or rv1106_ddr + rv1106_usbplug)
#   - For restore: raw partition images named to match partition names
#
# Usage:
#   ./rockchip_backup_restore_wizard.sh backup  [OPTIONS] [PARTITION...]
#   ./rockchip_backup_restore_wizard.sh restore [OPTIONS] [PARTITION...]

set -euo pipefail

# ── Globals ───────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR"       # image directory (input for restore, output for backup)
XROCK=""                     # resolved below
DEVICE_CONNECTED=0           # 1 once download mode entered
RAW_FULL_BACKUP=0            # 1 to perform full raw eMMC dump and exit
RAW_FULL_RESTORE=0           # 1 to restore full raw eMMC image and exit

# Partition table — populated by parse_partition_table()
PARTITION_NAMES=()
declare -A PARTITION_SECTORS  # name → start sector
declare -A PARTITION_SIZES    # name → size string (e.g. "512M")
declare -A PARTITION_RESOLVED_BYTES  # name → computed bytes for dynamic size entries

SELECTED_LIST=()              # partitions chosen for backup/restore
declare -A IMAGE_PATHS        # (restore) name → resolved image file path

# Loader binaries — co-located with the script
DOWNLOAD_BIN="$SCRIPT_DIR/rv1106_download_loader.bin"
DDR_BIN="$(ls "$SCRIPT_DIR"/rv1106_ddr_*.bin 2>/dev/null | head -1 || true)"
USBPLUG_BIN="$(ls "$SCRIPT_DIR"/rv1106_usbplug_*.bin 2>/dev/null | head -1 || true)"

# ── Colors / logging ─────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
info() { echo -e "${CYAN}[i]${NC} $*"; }

# ── Shared functions ─────────────────────────────────────────────────────────

# Prompt user for a file/executable path. Returns 0 if resolved, 1 if skipped.
# Usage: prompt_for_file VARNAME "description" [--exec]
prompt_for_file() {
    local varname="$1"
    local desc="$2"
    local need_exec="${3:-}"

    while true; do
        echo ""
        read -rp "Enter path to $desc (or 'q' to quit): " user_path
        if [ "$user_path" = "q" ] || [ "$user_path" = "Q" ]; then
            return 1
        fi
        # Strip trailing whitespace and expand ~
        user_path="${user_path%"${user_path##*[![:space:]]}"}"
        eval user_path="$user_path" 2>/dev/null || true

        if [ -z "$user_path" ]; then
            warn "No path entered"
            continue
        fi

        if [ "$need_exec" = "--exec" ]; then
            if [ -x "$user_path" ]; then
                eval "$varname=\"$user_path\""
                log "Using $desc: $user_path"
                return 0
            else
                warn "Not found or not executable: $user_path"
            fi
        else
            if [ -f "$user_path" ]; then
                eval "$varname=\"$user_path\""
                log "Using $desc: $user_path"
                return 0
            else
                warn "File not found: $user_path"
            fi
        fi
    done
}

# Convert a size string (e.g. "32K", "512M", "6600M") to bytes
size_to_bytes() {
    local s="$1"

    # Rockchip partition tables may use '-' to mean "use remaining space".
    # Return -1 as a sentinel for unknown/remaining size.
    if [ "$s" = "-" ]; then
        echo "-1"
        return
    fi

    local num="${s%[KkMmGg]}"
    local suffix="${s: -1}"

    case "$suffix" in
        K|k) echo $((num * 1024)) ;;
        M|m) echo $((num * 1024 * 1024)) ;;
        G|g) echo $((num * 1024 * 1024 * 1024)) ;;
        [0-9]) echo "$s" ;;  # bare number = bytes
        *) err "Unknown size suffix in '$s'"; exit 1 ;;
    esac
}

# Resolve a partition's size to bytes.
# Returns -1 when the partition uses '-' and has not been resolved yet.
partition_size_bytes() {
    local name="$1"
    local raw="${PARTITION_SIZES[$name]}"

    if [ "$raw" = "-" ]; then
        if [ -n "${PARTITION_RESOLVED_BYTES[$name]+x}" ]; then
            echo "${PARTITION_RESOLVED_BYTES[$name]}"
        else
            echo "-1"
        fi
        return
    fi

    size_to_bytes "$raw"
}

# Query flash capacity from xrock and return bytes, or -1 on failure.
get_flash_capacity_bytes() {
    local flash_info cap_mb
    flash_info=$("$XROCK" flash 2>/dev/null || true)
    cap_mb=$(printf '%s\n' "$flash_info" | sed -n 's/.*Capacity:[[:space:]]*\([0-9][0-9]*\)MB.*/\1/p' | head -1)

    if [ -z "$cap_mb" ]; then
        echo "-1"
        return
    fi

    echo $((cap_mb * 1024 * 1024))
}

# If the final partition size is '-', resolve it to remaining flash bytes.
resolve_last_remaining_partition_size() {
    if [ ${#PARTITION_NAMES[@]} -eq 0 ]; then
        return
    fi

    local last_index=$(( ${#PARTITION_NAMES[@]} - 1 ))
    local last_name="${PARTITION_NAMES[$last_index]}"

    if [ "${PARTITION_SIZES[$last_name]}" != "-" ]; then
        return
    fi

    local flash_bytes
    flash_bytes=$(get_flash_capacity_bytes)
    if [ "$flash_bytes" -le 0 ]; then
        warn "Could not read flash capacity from xrock; '$last_name' remains unresolved ('-')."
        return
    fi

    local start_sector="${PARTITION_SECTORS[$last_name]}"
    local start_bytes=$((start_sector * 512))
    local remaining=$((flash_bytes - start_bytes))

    if [ "$remaining" -le 0 ]; then
        warn "Computed non-positive remaining size for '$last_name'; leaving unresolved."
        return
    fi

    # Round down to full sectors for flash read/write operations.
    remaining=$(((remaining / 512) * 512))
    PARTITION_RESOLVED_BYTES["$last_name"]="$remaining"
    log "Resolved '$last_name' from '-' to $(human_size "$remaining") based on flash capacity"
}

# Return the maximum writable sectors for a partition.
# Uses next partition start for non-final entries; for final entries, uses the
# parsed size (including resolved '-' when available). Returns -1 if unknown.
partition_max_sectors() {
    local name="$1"
    local idx=-1

    for i in "${!PARTITION_NAMES[@]}"; do
        if [ "${PARTITION_NAMES[$i]}" = "$name" ]; then
            idx="$i"
            break
        fi
    done

    if [ "$idx" -lt 0 ]; then
        echo "-1"
        return
    fi

    local start_sector="${PARTITION_SECTORS[$name]}"
    local last_index=$(( ${#PARTITION_NAMES[@]} - 1 ))

    if [ "$idx" -lt "$last_index" ]; then
        local next_name="${PARTITION_NAMES[$((idx + 1))]}"
        local next_sector="${PARTITION_SECTORS[$next_name]}"
        echo $((next_sector - start_sector))
        return
    fi

    local part_bytes
    part_bytes=$(partition_size_bytes "$name")
    if [ "$part_bytes" -lt 0 ]; then
        echo "-1"
        return
    fi

    echo $((part_bytes / 512))
}

# Validate that selected restore images fit in their destination partitions.
validate_restore_image_sizes() {
    local name img img_bytes img_sectors max_sectors max_bytes

    for name in "${SELECTED_LIST[@]}"; do
        img="${IMAGE_PATHS[$name]}"
        img_bytes=$(wc -c < "$img")

        if [ "$img_bytes" -le 0 ]; then
            err "Image for '$name' is empty: $img"
            exit 1
        fi

        if [ $((img_bytes % 512)) -ne 0 ]; then
            err "Image for '$name' is not 512-byte aligned: $img"
            err "Size is $img_bytes bytes; expected a multiple of 512 for flash write."
            exit 1
        fi

        img_sectors=$((img_bytes / 512))
        max_sectors=$(partition_max_sectors "$name")

        if [ "$max_sectors" -lt 0 ]; then
            warn "Could not verify partition limit for '$name'; proceeding with image size checks disabled for this partition."
            continue
        fi

        if [ "$img_sectors" -gt "$max_sectors" ]; then
            max_bytes=$((max_sectors * 512))
            err "Image for '$name' is too large for destination partition"
            err "Image: $(human_size "$img_bytes") ($img_sectors sectors), partition max: $(human_size "$max_bytes") ($max_sectors sectors)"
            exit 1
        fi
    done
}

# Format bytes as human-readable (e.g. 1073741824 → "1.0G")
human_size() {
    local bytes="$1"
    if [ "$bytes" -lt 0 ]; then
        echo "remaining"
        return
    fi
    if [ "$bytes" -ge $((1024 * 1024 * 1024)) ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)G"
    elif [ "$bytes" -ge $((1024 * 1024)) ]; then
        echo "$(echo "scale=0; $bytes / 1048576" | bc)M"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=0; $bytes / 1024" | bc)K"
    else
        echo "${bytes}B"
    fi
}

# Parse blkdevparts= from an env image file.
# Populates PARTITION_NAMES, PARTITION_SECTORS, PARTITION_SIZES.
#
# The env image contains a blkdevparts= string like:
#   mmcblk0:32K(env),512K@32K(idblock),512K(uboot_a),...,512M(app),6600M(data)
#
# Each entry is: SIZE[@OFFSET](NAME)
#   - SIZE: number followed by K or M (or bare bytes)
#   - @OFFSET: optional explicit start offset (only used by idblock)
#   - NAME: partition name in parentheses
#
# Entries are walked sequentially; @OFFSET resets the cursor.
parse_partition_table() {
    local env_file="$1"

    if [ ! -f "$env_file" ]; then
        err "env image not found: $env_file"
        exit 1
    fi

    local blkdevparts
    blkdevparts=$(strings "$env_file" | grep -o 'blkdevparts=.*' | head -1)

    if [ -z "$blkdevparts" ]; then
        err "No blkdevparts= found in env image"
        exit 1
    fi

    log "Partition table from env:"
    info "  $blkdevparts"

    local entries_str="${blkdevparts#*:}"
    local cursor=0

    IFS=',' read -ra entries <<< "$entries_str"
    for entry in "${entries[@]}"; do
        local name size_str offset_str=""

        # Extract name from parentheses
        name="${entry##*(}"
        name="${name%)}"

        # Remove the (name) suffix to get size[@offset]
        local size_part="${entry%(*}"

        # Check for @offset
        if [[ "$size_part" == *"@"* ]]; then
            size_str="${size_part%%@*}"
            offset_str="${size_part#*@}"
        else
            size_str="$size_part"
        fi

        local size_bytes
        size_bytes=$(size_to_bytes "$size_str")

        # If explicit offset, reset cursor
        if [ -n "$offset_str" ]; then
            cursor=$(size_to_bytes "$offset_str")
        fi

        local sector=$((cursor / 512))
        PARTITION_SECTORS["$name"]=$sector
        PARTITION_SIZES["$name"]="$size_str"
        PARTITION_NAMES+=("$name")

        if [ "$size_bytes" -ge 0 ]; then
            cursor=$((cursor + size_bytes))
        fi
    done

    echo ""
    info "Parsed partition layout:"
    printf "  ${CYAN}%-12s %-10s %-12s %s${NC}\n" "NAME" "SIZE" "SECTOR" "SECTOR (hex)"
    for name in "${PARTITION_NAMES[@]}"; do
        local sec="${PARTITION_SECTORS[$name]}"
        printf "  %-12s %-10s %-12s 0x%08x\n" "$name" "${PARTITION_SIZES[$name]}" "$sec" "$sec"
    done
    echo ""
}

# Enter download mode (MASKROM → loader binary, with DDR+usbplug fallback)
enter_download_mode() {
    log "Checking for device in MASKROM mode..."

    if ! "$XROCK" ready 2>/dev/null; then
        warn "No device detected. Make sure the device is:"
        warn "  1. Powered off"
        warn "  2. Boot/MASKROM button held down"
        warn "  3. USB cable connected to this computer"
        warn "  4. Then power on (keep button held)"
        echo ""
        read -rp "Press Enter when device is connected in MASKROM mode..."
    fi

    log "Loading $(basename "$DOWNLOAD_BIN") to enter download mode..."
    if "$XROCK" download "$DOWNLOAD_BIN"; then
        log "Download mode entered via $(basename "$DOWNLOAD_BIN")"
        sleep 2
        DEVICE_CONNECTED=1
        return 0
    fi

    # Fallback: separate DDR + usbplug
    warn "$(basename "$DOWNLOAD_BIN") failed, trying separate DDR + usbplug..."
    if [ -f "$DDR_BIN" ] && [ -f "$USBPLUG_BIN" ]; then
        "$XROCK" maskrom "$DDR_BIN" "$USBPLUG_BIN" --rc4-off
        log "Download mode entered via DDR + usbplug"
        sleep 2
        DEVICE_CONNECTED=1
        return 0
    fi

    err "Could not enter download mode"
    exit 1
}

# Check that xrock and loader binary are available (prompt if missing)
preflight_tools() {
    if [ -z "$XROCK" ] || [ ! -x "$XROCK" ]; then
        warn "xrock not found in PATH or common locations"
        if ! prompt_for_file XROCK "xrock binary" --exec; then
            exit 1
        fi
    fi

    if [ ! -f "$DOWNLOAD_BIN" ]; then
        warn "$(basename "$DOWNLOAD_BIN") not found at $DOWNLOAD_BIN"
        if ! prompt_for_file DOWNLOAD_BIN "loader binary (.bin)"; then
            exit 1
        fi
    fi

    log "Preflight OK"
}

# Deduplicate SELECTED_LIST while preserving partition-table order
deduplicate_selection() {
    declare -A _seen
    local ordered=()
    for name in "${PARTITION_NAMES[@]}"; do
        for req in "${SELECTED_LIST[@]}"; do
            if [ "$req" = "$name" ] && [ -z "${_seen[$req]+x}" ]; then
                ordered+=("$req")
                _seen["$req"]=1
            fi
        done
    done
    SELECTED_LIST=("${ordered[@]}")
}

# ── Mode-specific functions ──────────────────────────────────────────────────

# Restore: write a partition image to device
write_partition() {
    local name="$1"
    local sector="$2"
    local image="$3"

    local size_human
    size_human=$(ls -lh "$image" | awk '{print $5}')
    local sector_hex
    sector_hex=$(printf "0x%08x" "$sector")

    log "Writing $name partition ($size_human) at sector $sector ($sector_hex)..."
    info "Image: $image"

    if "$XROCK" flash write "$sector" "$image"; then
        log "$name partition written successfully"
    else
        err "Failed to write $name partition!"
        exit 1
    fi
}

# Backup: read a partition from device to file
read_partition() {
    local name="$1"
    local sector="$2"
    local count="$3"
    local output="$4"
    local size_human="$5"

    local sector_hex
    sector_hex=$(printf "0x%08x" "$sector")

    log "Reading $name ($size_human, $count sectors) from sector $sector ($sector_hex)..."

    if "$XROCK" flash read "$sector" "$count" "$output"; then
        local actual_size
        actual_size=$(ls -lh "$output" | awk '{print $5}')
        log "$name read successfully ($actual_size) → $output"
    else
        err "Failed to read $name partition!"
        exit 1
    fi
}

# Backup: read the entire flash device from sector 0 to end
full_raw_backup() {
    local output="$DATA_DIR/full_emmc.img"
    local flash_bytes flash_sectors

    flash_bytes=$(get_flash_capacity_bytes)
    if [ "$flash_bytes" -le 0 ]; then
        err "Could not determine flash capacity from xrock"
        exit 1
    fi

    flash_sectors=$((flash_bytes / 512))

    info "Flash capacity: $(human_size "$flash_bytes") ($flash_sectors sectors)"
    info "Output file:    $output"

    if [ -f "$output" ]; then
        warn "Output file already exists and will be overwritten: $output"
        read -rp "Overwrite existing full raw backup? [y/N] " overwrite
        if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    # Check available disk space
    local avail_kb needed_kb
    avail_kb=$(df -k "$DATA_DIR" | tail -1 | awk '{print $4}')
    needed_kb=$((flash_bytes / 1024))
    if [ "$avail_kb" -lt "$needed_kb" ]; then
        err "Not enough disk space for full raw backup"
        err "Need ~$(human_size "$flash_bytes"), have ~$(human_size $((avail_kb * 1024)))"
        exit 1
    fi

    warn "Full raw backup reads the entire eMMC and can take a long time."
    read -rp "Start full raw backup now? [Y/n] " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        echo "Aborted."
        exit 0
    fi

    log "Reading full flash ($flash_sectors sectors) from sector 0..."
    if "$XROCK" flash read 0 "$flash_sectors" "$output"; then
        local actual_size
        actual_size=$(ls -lh "$output" | awk '{print $5}')
        log "Full raw backup complete ($actual_size) → $output"
        info "To raw-restore manually (dangerous), use:"
        info "  $XROCK flash write 0 $output"
    else
        err "Failed to read full flash"
        exit 1
    fi
}

# Restore: write a full raw eMMC image from sector 0
full_raw_restore() {
    local input="$DATA_DIR/full_emmc.img"
    local img_bytes img_sectors flash_bytes flash_sectors

    if [ ! -f "$input" ] && [ -f "$DATA_DIR/full_emmc.bin" ]; then
        input="$DATA_DIR/full_emmc.bin"
    fi

    if [ ! -f "$input" ]; then
        warn "Full raw image not found at $DATA_DIR/full_emmc.img"
        if ! prompt_for_file input "full raw eMMC image"; then
            exit 1
        fi
    fi

    img_bytes=$(wc -c < "$input")
    if [ "$img_bytes" -le 0 ]; then
        err "Raw image is empty: $input"
        exit 1
    fi

    if [ $((img_bytes % 512)) -ne 0 ]; then
        err "Raw image is not 512-byte aligned: $input"
        err "Size is $img_bytes bytes; expected a multiple of 512."
        exit 1
    fi

    flash_bytes=$(get_flash_capacity_bytes)
    if [ "$flash_bytes" -le 0 ]; then
        err "Could not determine flash capacity from xrock"
        exit 1
    fi

    img_sectors=$((img_bytes / 512))
    flash_sectors=$((flash_bytes / 512))

    info "Flash capacity: $(human_size "$flash_bytes") ($flash_sectors sectors)"
    info "Input image:    $input"
    info "Image size:     $(human_size "$img_bytes") ($img_sectors sectors)"

    if [ "$img_bytes" -gt "$flash_bytes" ]; then
        err "Raw image is larger than flash capacity"
        err "Image: $(human_size "$img_bytes"), flash: $(human_size "$flash_bytes")"
        exit 1
    fi

    warn "THIS WILL OVERWRITE THE ENTIRE eMMC FROM SECTOR 0."
    warn "All partitions and data on the device will be replaced."
    read -rp "Type YES to continue full raw restore: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "Aborted."
        exit 0
    fi

    log "Writing full raw image ($img_sectors sectors) to sector 0..."
    if "$XROCK" flash write 0 "$input"; then
        log "Full raw restore complete"
    else
        err "Failed to write full raw image"
        exit 1
    fi

    log "Resetting device..."
    "$XROCK" reset 2>/dev/null || warn "Auto-reset failed — manually power cycle the device"
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") <backup|restore> [OPTIONS] [PARTITION...]

Backup or restore RV1106 partitions via MASKROM mode.
The env partition is parsed to discover the device's partition table,
then you choose which partitions to operate on.

Subcommands:
  backup     Read partitions from device and save as image files
  restore    Write partition images back to device

Partitions:
  With no partition arguments, an interactive menu is shown.
  You can also specify partition names directly:
    $(basename "$0") backup  app data       # back up app + data
    $(basename "$0") restore all            # restore everything with an image

Options:
  -d DIR    Directory for partition images
            Backup: where to save images (default: script directory)
            Restore: where to find images (default: script directory)
  -R        Backup only: dump full raw eMMC to DIR/full_emmc.img and exit
  -W        Restore only: write DIR/full_emmc.img to sector 0 and exit
  -l FILE   Path to a loader binary (.bin) for MASKROM download mode
            (default: rv1106_download_loader.bin in the script directory)
  -x PATH   Path to xrock binary (default: auto-detect via PATH)
  -h        Show this help

Loader binaries (rv1106_download_loader.bin or rv1106_ddr_*.bin +
rv1106_usbplug_*.bin) are expected in the same directory as this script.

Examples:
  $(basename "$0") backup                                  # interactive backup
  $(basename "$0") backup  -d ../backups all               # back up everything
  $(basename "$0") backup  -d ../backups -R                # full raw backup (whole eMMC)
  $(basename "$0") backup  -l /path/to/custom_loader.bin   # use a custom loader
  $(basename "$0") restore                                 # interactive restore
  $(basename "$0") restore -d ../backups app               # restore app from backups dir
  $(basename "$0") restore -d ../backups -W                # full raw restore (whole eMMC)
EOF
    exit 0
}

# ── Parse subcommand ─────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
    usage
fi

MODE="$1"
shift

case "$MODE" in
    backup|restore) ;;
    -h|--help|help) usage ;;
    *) err "Unknown subcommand: '$MODE' (use 'backup' or 'restore')"; echo ""; usage ;;
esac

# ── Parse options ────────────────────────────────────────────────────────────

while getopts ":d:x:l:RWh" opt; do
    case "$opt" in
        d) DATA_DIR="$OPTARG" ;;
        x) XROCK="$OPTARG" ;;
        l) DOWNLOAD_BIN="$OPTARG" ;;
        R) RAW_FULL_BACKUP=1 ;;
        W) RAW_FULL_RESTORE=1 ;;
        h) usage ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
        :)  echo "Option -$OPTARG requires an argument" >&2; usage ;;
    esac
done
shift $((OPTIND - 1))

if [ "$MODE" != "backup" ] && [ "$RAW_FULL_BACKUP" = "1" ]; then
    err "Option -R is only valid with the 'backup' subcommand"
    exit 1
fi

if [ "$MODE" != "restore" ] && [ "$RAW_FULL_RESTORE" = "1" ]; then
    err "Option -W is only valid with the 'restore' subcommand"
    exit 1
fi

if [ "$RAW_FULL_BACKUP" = "1" ] && [ "$RAW_FULL_RESTORE" = "1" ]; then
    err "Options -R and -W cannot be used together"
    exit 1
fi

# ── Resolve xrock ───────────────────────────────────────────────────────────

if [ -z "$XROCK" ]; then
    XROCK="$(command -v xrock 2>/dev/null || true)"
    if [ -z "$XROCK" ]; then
        for candidate in /usr/local/bin/xrock /usr/bin/xrock /opt/homebrew/bin/xrock; do
            if [ -x "$candidate" ]; then
                XROCK="$candidate"
                break
            fi
        done
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# BACKUP MODE
# ══════════════════════════════════════════════════════════════════════════════

if [ "$MODE" = "backup" ]; then

    echo ""
    echo "============================================================"
    echo "  RV1106 Partition Backup"
    echo "============================================================"
    echo ""

    mkdir -p "$DATA_DIR"
    DATA_DIR="$(cd "$DATA_DIR" && pwd)"

    info "Output:    $DATA_DIR"
    info "Loaders:   $SCRIPT_DIR"
    info "xrock:     ${XROCK:-<not found>}"
    echo ""

    preflight_tools

    # ── Connect to device ─────────────────────────────────────────────────
    enter_download_mode

    log "Verifying device is ready..."
    if ! "$XROCK" ready; then
        err "Device not ready after entering download mode"
        exit 1
    fi
    log "Device ready"

    if [ "$RAW_FULL_BACKUP" = "1" ]; then
        if [ $# -gt 0 ]; then
            warn "Ignoring partition arguments in full raw backup mode"
        fi

        full_raw_backup
        echo ""
        echo "============================================================"
        echo -e "  ${GREEN}FULL RAW BACKUP COMPLETE${NC}"
        echo "============================================================"
        echo ""
        exit 0
    fi

    # ── Read env to discover partition table ──────────────────────────────
    # env is always the first partition at sector 0. Read 64 sectors (32K)
    # initially — the blkdevparts string is always within the first 32K.
    ENV_FILE="$DATA_DIR/env"

    log "Reading env partition (32K) to discover partition table..."
    if ! "$XROCK" flash read 0 64 "$ENV_FILE"; then
        err "Failed to read env partition from device"
        exit 1
    fi
    log "env saved → $ENV_FILE"

    parse_partition_table "$ENV_FILE"
    resolve_last_remaining_partition_size

    # Self-correct: re-read env if actual size differs from 32K assumption
    if [ -n "${PARTITION_SIZES[env]+x}" ]; then
        env_expected=$(size_to_bytes "${PARTITION_SIZES[env]}")
        env_actual=$((64 * 512))
        if [ "$env_expected" -ne "$env_actual" ]; then
            warn "env partition is ${PARTITION_SIZES[env]} ($(human_size "$env_expected")), but we read $(human_size "$env_actual")"
            warn "Re-reading env with correct size..."
            env_sectors=$((env_expected / 512))
            "$XROCK" flash read 0 "$env_sectors" "$ENV_FILE"
            log "env re-read with correct size"
        fi
    fi

    # ── Show partition table ──────────────────────────────────────────────
    # Build selectable list (everything except env, which is already saved)
    selectable_names=()
    skipped_unknown_size=()
    for name in "${PARTITION_NAMES[@]}"; do
        if [ "$name" != "env" ]; then
            if [ "$(partition_size_bytes "$name")" -lt 0 ]; then
                skipped_unknown_size+=("$name")
            else
                selectable_names+=("$name")
            fi
        fi
    done

    if [ ${#skipped_unknown_size[@]} -gt 0 ]; then
        warn "Skipping partition(s) with remaining-size marker '-' in backup: ${skipped_unknown_size[*]}"
        warn "These can still be restored from image files, but size cannot be inferred for raw read."
    fi

    echo ""
    printf "  ${CYAN}%-4s %-14s %-8s %-12s %s${NC}\n" \
        "#" "PARTITION" "SIZE" "SECTOR" "BYTES"

    printf "  ${GREEN}%-4s${NC} %-14s %-8s %-12s %-12s ${GREEN}(saved)${NC}\n" \
        "--" "env" "${PARTITION_SIZES[env]}" \
        "$(printf '0x%08x' "${PARTITION_SECTORS[env]}")" \
        "$(human_size "$(size_to_bytes "${PARTITION_SIZES[env]}")")"

    for s in "${!selectable_names[@]}"; do
        name="${selectable_names[$s]}"
        sec="${PARTITION_SECTORS[$name]}"
        sec_hex=$(printf "0x%08x" "$sec")
        size_bytes=$(partition_size_bytes "$name")

        existing=""
        if [ -f "$DATA_DIR/$name" ]; then
            existing=" ${YELLOW}(exists, will overwrite)${NC}"
        fi

        printf "  %-4s %-14s %-8s %-12s %-12s%b\n" \
            "$((s + 1)))" "$name" "${PARTITION_SIZES[$name]}" "$sec_hex" \
            "$(human_size "$size_bytes")" "$existing"
    done
    echo ""

    # ── Build selection list ──────────────────────────────────────────────
    if [ $# -gt 0 ]; then
        if [ "$1" = "all" ]; then
            SELECTED_LIST=("${selectable_names[@]}")
        else
            for arg in "$@"; do
                if [ "$arg" = "env" ]; then
                    info "env is always backed up automatically, skipping"
                    continue
                fi
                if [ -z "${PARTITION_SECTORS[$arg]+x}" ]; then
                    err "Unknown partition: '$arg'"
                    info "Partitions on device: ${PARTITION_NAMES[*]}"
                    exit 1
                fi
                SELECTED_LIST+=("$arg")
            done
        fi
    else
        info "${#selectable_names[@]} additional partition(s) available to back up."
        echo ""
        read -rp "Enter numbers to back up (e.g. 1 3 5), 'all', or Enter for env only: " choices

        if [ -z "$choices" ]; then
            log "Only env was backed up."
            echo ""
            info "Saved: $ENV_FILE"
            exit 0
        fi

        if [ "$choices" = "all" ]; then
            SELECTED_LIST=("${selectable_names[@]}")
        else
            for c in $choices; do
                if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt ${#selectable_names[@]} ]; then
                    err "Invalid selection: $c (must be 1-${#selectable_names[@]})"
                    exit 1
                fi
                SELECTED_LIST+=("${selectable_names[$((c - 1))]}")
            done
        fi
    fi

    if [ ${#SELECTED_LIST[@]} -eq 0 ]; then
        log "Only env was backed up."
        echo ""
        info "Saved: $ENV_FILE"
        exit 0
    fi

    deduplicate_selection

    # ── Estimate size + confirm ───────────────────────────────────────────
    total_bytes=0
    echo ""
    info "Selected for backup (${#SELECTED_LIST[@]} + env):"
    printf "  %-14s %s\n" "env" "$(human_size "$(size_to_bytes "${PARTITION_SIZES[env]}")")"
    for name in "${SELECTED_LIST[@]}"; do
        size_bytes=$(partition_size_bytes "$name")
        if [ "$size_bytes" -lt 0 ]; then
            err "Cannot back up '$name' because its size is '-' (remaining space)"
            err "Select fixed-size partitions only, or back up this partition with another method."
            exit 1
        fi
        total_bytes=$((total_bytes + size_bytes))
        printf "  %-14s %s\n" "$name" "$(human_size "$size_bytes")"
    done
    echo ""
    info "Total to read: $(human_size "$total_bytes") (plus env already saved)"
    echo ""

    # Check available disk space
    avail_kb=$(df -k "$DATA_DIR" | tail -1 | awk '{print $4}')
    needed_kb=$((total_bytes / 1024))
    if [ "$avail_kb" -lt "$needed_kb" ]; then
        err "Not enough disk space! Need ~$(human_size "$total_bytes"), have ~$(human_size $((avail_kb * 1024)))"
        exit 1
    fi

    warn "Large partitions (data, app) will take several minutes each."
    echo ""
    read -rp "Start backup? [Y/n] " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
        echo "Aborted."
        exit 0
    fi
    echo ""

    # ── Read selected partitions ──────────────────────────────────────────
    completed=0
    total=${#SELECTED_LIST[@]}

    for name in "${SELECTED_LIST[@]}"; do
        completed=$((completed + 1))
        sector="${PARTITION_SECTORS[$name]}"
        size_bytes=$(partition_size_bytes "$name")
        if [ "$size_bytes" -lt 0 ]; then
            err "Cannot back up '$name' because its size is '-' (remaining space)"
            exit 1
        fi
        sector_count=$((size_bytes / 512))
        size_h=$(human_size "$size_bytes")
        output="$DATA_DIR/$name"

        log "[$completed/$total] Backing up $name..."

        if [ "$size_bytes" -gt $((100 * 1024 * 1024)) ]; then
            warn "$name is $size_h — this may take several minutes..."
        fi

        read_partition "$name" "$sector" "$sector_count" "$output" "$size_h"
    done

    # ── Summary ───────────────────────────────────────────────────────────
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}BACKUP COMPLETE${NC} — $((total + 1)) partition(s) saved"
    echo "============================================================"
    echo ""
    info "Output directory: $DATA_DIR"
    info ""
    info "Saved images:"
    printf "  %-14s %s\n" "env" "$(ls -lh "$ENV_FILE" | awk '{print $5}')"
    for name in "${SELECTED_LIST[@]}"; do
        printf "  %-14s %s\n" "$name" "$(ls -lh "$DATA_DIR/$name" | awk '{print $5}')"
    done
    echo ""
    info "To restore, run:"
    info "  $(basename "$0") restore -d $DATA_DIR all"
    echo ""

# ══════════════════════════════════════════════════════════════════════════════
# RESTORE MODE
# ══════════════════════════════════════════════════════════════════════════════

elif [ "$MODE" = "restore" ]; then

    echo ""
    echo "============================================================"
    echo "  RV1106 Partition Restore"
    echo "============================================================"
    echo ""

    if [ -d "$DATA_DIR" ]; then
        DATA_DIR="$(cd "$DATA_DIR" && pwd)"
    fi

    info "Images:    $DATA_DIR"
    info "Loaders:   $SCRIPT_DIR"
    echo ""

    if [ "$RAW_FULL_RESTORE" = "1" ]; then
        if [ $# -gt 0 ]; then
            warn "Ignoring partition arguments in full raw restore mode"
        fi

        info "xrock:     ${XROCK:-<not found>}"
        preflight_tools

        if [ "$DEVICE_CONNECTED" = "1" ]; then
            log "Device already in download mode"
        else
            enter_download_mode

            log "Verifying device is ready..."
            if ! "$XROCK" ready; then
                err "Device not ready after entering download mode"
                exit 1
            fi
            log "Device ready"
        fi

        full_raw_restore

        echo ""
        echo "============================================================"
        echo -e "  ${GREEN}FULL RAW RESTORE COMPLETE${NC}"
        echo "============================================================"
        echo ""
        exit 0
    fi

    # ── Find or read the env image ────────────────────────────────────────
    ENV_IMAGE="$DATA_DIR/env"
    if [ ! -f "$ENV_IMAGE" ] && [ -f "$DATA_DIR/env.img" ]; then
        ENV_IMAGE="$DATA_DIR/env.img"
    fi

    if [ ! -f "$ENV_IMAGE" ]; then
        warn "env image not found at $DATA_DIR/env"
        warn "The env image is required — it contains the partition table."
        echo ""
        echo "  1) Enter a path to an existing env image file"
        echo "  2) Read env directly from the device (requires MASKROM mode)"
        echo "  q) Quit"
        echo ""
        read -rp "Choice [1/2/q]: " env_choice

        case "$env_choice" in
            1)
                if ! prompt_for_file ENV_IMAGE "env partition image"; then
                    exit 1
                fi
                ;;
            2)
                # Need xrock + loader binary to read from device
                info "Checking prerequisites for device read..."
                preflight_tools

                enter_download_mode

                log "Verifying device is ready..."
                if ! "$XROCK" ready; then
                    err "Device not ready after entering download mode"
                    exit 1
                fi

                mkdir -p "$DATA_DIR"
                ENV_IMAGE="$DATA_DIR/env"
                log "Reading env partition (32K) from device sector 0..."
                if ! "$XROCK" flash read 0 64 "$ENV_IMAGE"; then
                    err "Failed to read env partition from device"
                    exit 1
                fi
                log "env read from device → $ENV_IMAGE"
                ;;
            *)
                echo "Aborted."
                exit 0
                ;;
        esac
    fi

    parse_partition_table "$ENV_IMAGE"

    # ── Show partition table with image availability ──────────────────────
    echo ""
    printf "  ${CYAN}%-4s %-14s %-8s %-12s %-10s %s${NC}\n" \
        "#" "PARTITION" "SIZE" "SECTOR" "IMAGE" "IMAGE SIZE"

    avail_indices=()   # indices into PARTITION_NAMES for partitions with images

    for i in "${!PARTITION_NAMES[@]}"; do
        name="${PARTITION_NAMES[$i]}"
        sec="${PARTITION_SECTORS[$name]}"
        sec_hex=$(printf "0x%08x" "$sec")

        # Check for image file (try both "name" and "name.img")
        img_path="$DATA_DIR/$name"
        if [ ! -f "$img_path" ] && [ -f "${img_path}.img" ]; then
            img_path="${img_path}.img"
        fi

        if [ -f "$img_path" ]; then
            img_size=$(ls -lh "$img_path" | awk '{print $5}')
            avail_indices+=("$i")
            n=${#avail_indices[@]}
            printf "  ${GREEN}%-4s${NC} %-14s %-8s %-12s ${GREEN}%-10s${NC} %s\n" \
                "${n})" "$name" "${PARTITION_SIZES[$name]}" "$sec_hex" "ready" "$img_size"
        else
            printf "  ${YELLOW}%-4s${NC} %-14s %-8s %-12s ${YELLOW}%-10s${NC}\n" \
                "--" "$name" "${PARTITION_SIZES[$name]}" "$sec_hex" "no image"
        fi
    done
    echo ""

    if [ ${#avail_indices[@]} -eq 0 ]; then
        err "No partition images found in $DATA_DIR"
        exit 1
    fi

    # ── Build selection list ──────────────────────────────────────────────
    if [ $# -gt 0 ]; then
        if [ "$1" = "all" ]; then
            for idx in "${avail_indices[@]}"; do
                SELECTED_LIST+=("${PARTITION_NAMES[$idx]}")
            done
        else
            for arg in "$@"; do
                if [ -z "${PARTITION_SECTORS[$arg]+x}" ]; then
                    err "Unknown partition: '$arg'"
                    info "Partitions in env: ${PARTITION_NAMES[*]}"
                    exit 1
                fi
                SELECTED_LIST+=("$arg")
            done
        fi
    else
        info "${#avail_indices[@]} partition(s) have backup images available."
        echo ""
        read -rp "Enter numbers to restore (e.g. 1 3 5), 'all', or Enter to cancel: " choices

        if [ -z "$choices" ]; then
            echo "Aborted."
            exit 0
        fi

        if [ "$choices" = "all" ]; then
            for idx in "${avail_indices[@]}"; do
                SELECTED_LIST+=("${PARTITION_NAMES[$idx]}")
            done
        else
            for c in $choices; do
                if ! [[ "$c" =~ ^[0-9]+$ ]] || [ "$c" -lt 1 ] || [ "$c" -gt ${#avail_indices[@]} ]; then
                    err "Invalid selection: $c (must be 1-${#avail_indices[@]})"
                    exit 1
                fi
                arr_idx="${avail_indices[$((c - 1))]}"
                SELECTED_LIST+=("${PARTITION_NAMES[$arr_idx]}")
            done
        fi
    fi

    if [ ${#SELECTED_LIST[@]} -eq 0 ]; then
        err "No partitions selected"
        exit 1
    fi

    deduplicate_selection

    # ── Confirm ───────────────────────────────────────────────────────────
    echo ""
    info "Selected for restore (${#SELECTED_LIST[@]}):"
    for name in "${SELECTED_LIST[@]}"; do
        sec="${PARTITION_SECTORS[$name]}"
        disp_path="${IMAGE_PATHS[$name]:-$DATA_DIR/$name}"
        if [ -f "$disp_path" ]; then
            img_size=$(ls -lh "$disp_path" | awk '{print $5}')
        else
            img_size="???"
        fi
        printf "  %-14s %6s  at sector %-10s (0x%08x)\n" \
            "$name" "$img_size" "$sec" "$sec"
    done
    echo ""

    warn "THIS WILL OVERWRITE THE SELECTED PARTITIONS WITH THE BACKUP IMAGES."
    warn "Any modifications to those partitions will be erased."
    echo ""
    read -rp "Type YES to continue: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "Aborted."
        exit 0
    fi
    echo ""

    # ── Preflight (tools + image files) ───────────────────────────────────
    if [ "$DEVICE_CONNECTED" = "0" ]; then
        info "xrock:     ${XROCK:-<not found>}"
        preflight_tools
    fi

    # Resolve image paths for all selected partitions
    for name in "${SELECTED_LIST[@]}"; do
        img="$DATA_DIR/$name"
        if [ ! -f "$img" ] && [ -f "${img}.img" ]; then
            img="${img}.img"
        fi
        if [ ! -f "$img" ]; then
            warn "'$name' partition image not found at $DATA_DIR/$name"
            if ! prompt_for_file img "$name partition image"; then
                exit 1
            fi
        fi
        IMAGE_PATHS["$name"]="$img"
    done

    # ── Flash ─────────────────────────────────────────────────────────────
    if [ "$DEVICE_CONNECTED" = "1" ]; then
        log "Device already in download mode (from env read)"
    else
        enter_download_mode

        log "Verifying device is ready..."
        if ! "$XROCK" ready; then
            err "Device not ready after entering download mode"
            exit 1
        fi
        log "Device ready"
    fi

    # Resolve trailing '-' partition size from flash capacity when possible,
    # then validate every selected image fits its destination partition.
    resolve_last_remaining_partition_size
    validate_restore_image_sizes

    completed=0
    total=${#SELECTED_LIST[@]}

    for name in "${SELECTED_LIST[@]}"; do
        completed=$((completed + 1))
        log "[$completed/$total] Restoring $name..."

        part_size="${PARTITION_SIZES[$name]}"
        size_bytes=$(partition_size_bytes "$name")
        if [ "$size_bytes" -lt 0 ]; then
            img_bytes=$(wc -c < "${IMAGE_PATHS[$name]}")
            if [ "$img_bytes" -gt $((100 * 1024 * 1024)) ]; then
                warn "$name image is ~$(human_size "$img_bytes") — this may take several minutes..."
            fi
        elif [ "$size_bytes" -gt $((100 * 1024 * 1024)) ]; then
            warn "$name is ~$part_size — this may take several minutes..."
        fi

        write_partition "$name" "${PARTITION_SECTORS[$name]}" "${IMAGE_PATHS[$name]}"
    done

    # ── Reset + summary ───────────────────────────────────────────────────
    echo ""
    log "All $total partitions written. Resetting device..."
    "$XROCK" reset 2>/dev/null || warn "Auto-reset failed — manually power cycle the device"

    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}RESTORE COMPLETE${NC} — $total partition(s) written"
    echo "============================================================"
    echo ""
    info "The device should now boot with the restored partitions."
    info "If it doesn't boot, try power cycling manually."
    echo ""

fi
