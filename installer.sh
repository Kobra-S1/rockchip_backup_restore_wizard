#!/usr/bin/env bash
# installer.sh — Fetch the Rockchip loader binaries needed by
# rockchip_backup_restore_wizard.sh
#
# Downloads the DDR init and USB plug firmware blobs used as the MASKROM
# download-mode fallback (see README.md § Loader Binaries) from the
# upstream Rockchip rkbin repository and places them next to this script.
#
# The primary loader, rv1106_download_loader.bin, is not published as a
# single file upstream (it's built by merging DDR+HPMCU+SPL blobs with
# rkbin's boot_merger tool) and must be supplied separately if missing —
# see the README for sources.
#
# Usage:
#   ./installer.sh [-d DIR] [-f]

set -euo pipefail

RKBIN_RAW_BASE="https://raw.githubusercontent.com/rockchip-linux/rkbin/master/bin/rv11"

# name → expected size in bytes, used as a sanity check on the download
declare -A LOADER_FILES=(
    [rv1106_ddr_924MHz_v1.15.bin]=22632
    [rv1106_usbplug_v1.09.bin]=52740
)

DEST_DIR="$(cd "$(dirname "$0")" && pwd)"
FORCE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Downloads the RV1106 DDR init and USB plug loader binaries (fallback path
for MASKROM download mode) from the rockchip-linux/rkbin repository.

Options:
  -d DIR   Destination directory (default: this script's directory)
  -f       Re-download even if a file already exists
  -h       Show this help
EOF
}

while getopts ":d:fh" opt; do
    case "$opt" in
        d) DEST_DIR="$OPTARG" ;;
        f) FORCE=1 ;;
        h) usage; exit 0 ;;
        \?) err "Unknown option: -$OPTARG"; usage; exit 1 ;;
        :) err "Option -$OPTARG requires an argument"; usage; exit 1 ;;
    esac
done

if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_CMD="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_CMD="wget"
else
    err "Neither curl nor wget found — install one of them and retry."
    exit 1
fi

fetch() {
    local url="$1" dest="$2"
    if [ "$DOWNLOAD_CMD" = "curl" ]; then
        curl -fL --progress-bar "$url" -o "$dest"
    else
        wget -q --show-progress "$url" -O "$dest"
    fi
}

mkdir -p "$DEST_DIR"

fail=0
for name in "${!LOADER_FILES[@]}"; do
    dest="$DEST_DIR/$name"
    expected_size="${LOADER_FILES[$name]}"

    if [ -f "$dest" ] && [ "$FORCE" -ne 1 ]; then
        log "$name already present, skipping (use -f to re-download)"
        continue
    fi

    log "Downloading $name..."
    tmp="$dest.part"
    trap 'rm -f "$tmp"' EXIT
    if ! fetch "$RKBIN_RAW_BASE/$name" "$tmp"; then
        err "Failed to download $name"
        rm -f "$tmp"
        fail=1
        continue
    fi

    actual_size=$(wc -c < "$tmp")
    if [ "$actual_size" -ne "$expected_size" ]; then
        warn "$name: expected $expected_size bytes, got $actual_size — keeping it, but verify manually"
    fi

    mv "$tmp" "$dest"
    trap - EXIT
    log "Saved $dest"
done

if [ ! -f "$DEST_DIR/rv1106_download_loader.bin" ]; then
    warn "rv1106_download_loader.bin (primary loader) is still missing."
    warn "It isn't published as a standalone file upstream — see the" \
         "README's 'Loader Binaries' section for how to obtain or build it."
    warn "The DDR + USB plug binaries fetched above are used as a fallback" \
         "in the meantime."
fi

if [ "$fail" -ne 0 ]; then
    err "One or more downloads failed."
    exit 1
fi

log "Done."
