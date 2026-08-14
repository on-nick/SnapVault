#!/bin/bash
#
# SnapVault (snapvault.sh)
# Backs up photos/videos from an Android phone (connected via MTP) to a
# removable drive (pendrive / external SSD / SD card).
#
# - Auto-detects your removable drive and phone folders on first run.
# - Remembers your choice in a config file so future runs are one command.
# - Only copies NEW files since the last backup (no duplicates, no re-copying).
# - Asks for confirmation before starting each time.
#
# HOW IT WORKS:
#   Uses `rsync --ignore-existing`, which skips any file on the drive that
#   already has the same name in the destination folder. Since phone camera
#   filenames (IMG_20260708_120000.jpg, VID_...mp4, etc.) are unique per
#   photo/video, this reliably means "only copy what's new" without keeping
#   a separate database.
#
# USAGE:
#   ./snapvault.sh              Run a normal backup
#   ./snapvault.sh --dry-run    Preview what would be copied, copy nothing
#   ./snapvault.sh --setup      Re-run setup (pick a different drive/folders)
#
# REQUIREMENTS (Linux only, tested on GNOME/KDE distros with gvfs):
#   - rsync
#   - gio (part of glib2, used to mount the phone over MTP)
#
set -uo pipefail

CONFIG_DIR="$HOME/.config/snapvault"
CONFIG_FILE="$CONFIG_DIR/config.sh"

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
DRY_RUN=""
FORCE_SETUP=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN="-n" ;;
        --setup)   FORCE_SETUP=1 ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S')  $1"
}

# ------------------------------------------------------------------
# 0. Sanity checks
# ------------------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "This script currently only supports Linux (it relies on gio/gvfs for MTP)."
    echo "Patches welcome for macOS/Windows — see the README."
    exit 1
fi

for cmd in rsync gio; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "'$cmd' is not installed."
        case "$cmd" in
            rsync) echo "Install it with: sudo apt install rsync   (or your distro's equivalent)" ;;
            gio)   echo "Install it with: sudo apt install glib2.0-bin   (or your distro's equivalent)" ;;
        esac
        exit 1
    fi
done

# ------------------------------------------------------------------
# 1. Detect the phone over MTP
# ------------------------------------------------------------------
detect_phone_mount() {
    local gvfs_dir="/run/user/$(id -u)/gvfs"
    local d

    if [ -d "$gvfs_dir" ]; then
        for d in "$gvfs_dir"/mtp:host=*; do
            [ -d "$d" ] && { echo "$d"; return 0; }
        done
    fi

    # Not mounted yet — try to trigger a mount via gio
    local mtp_uri
    mtp_uri=$(gio mount -l 2>/dev/null | grep -oP 'mtp://[^ ]+' | head -n1)
    if [ -n "$mtp_uri" ]; then
        gio mount "$mtp_uri" >/dev/null 2>&1
        sleep 2
    fi

    if [ -d "$gvfs_dir" ]; then
        for d in "$gvfs_dir"/mtp:host=*; do
            [ -d "$d" ] && { echo "$d"; return 0; }
        done
    fi

    return 1
}

echo "Looking for your Android phone..."
PHONE_MOUNT="$(detect_phone_mount || true)"

if [ -z "$PHONE_MOUNT" ]; then
    echo "Couldn't detect your phone over MTP."
    echo "Try: unlock your phone screen, set USB mode to 'File Transfer (MTP)',"
    echo "then open the Files app once so it auto-mounts, and re-run this script."
    exit 1
fi

STORAGE_DIR=""
for d in "$PHONE_MOUNT"/*/; do
    STORAGE_DIR="$d"
    break
done

if [ -z "$STORAGE_DIR" ]; then
    echo "Phone detected but its storage folder couldn't be opened."
    echo "Make sure the phone is unlocked and set to File Transfer mode."
    exit 1
fi

echo "Phone found at: $STORAGE_DIR"
echo ""

# ------------------------------------------------------------------
# 2. Detect removable drives
# ------------------------------------------------------------------
detect_drives() {
    local -a candidates=()
    local base d

    for base in "/run/media/$USER" "/media/$USER" "/media"; do
        [ -d "$base" ] || continue
        for d in "$base"/*/; do
            [ -d "$d" ] || continue
            d="${d%/}"
            # skip obvious non-drive entries
            [[ "$d" == "$base" ]] && continue
            candidates+=("$d")
        done
    done

    printf '%s\n' "${candidates[@]}"
}

choose_drive() {
    mapfile -t drives < <(detect_drives)

    if [ "${#drives[@]}" -eq 0 ]; then
        echo "No removable drive found under /run/media/$USER, /media/$USER, or /media." >&2
        echo "Plug in your pendrive/SD card/external drive, make sure it's mounted, and try again." >&2
        echo "" >&2
        read -rp "Or type a folder path to use instead: " MANUAL_PATH
        if [ -n "$MANUAL_PATH" ] && [ -d "$MANUAL_PATH" ]; then
            echo "$MANUAL_PATH"
            return 0
        fi
        return 1
    fi

    if [ "${#drives[@]}" -eq 1 ]; then
        echo "Found drive: ${drives[0]}" >&2
        echo "${drives[0]}"
        return 0
    fi

    echo "Multiple drives found:" >&2
    local i
    for i in "${!drives[@]}"; do
        echo "  $((i+1))) ${drives[$i]}" >&2
    done
    local choice
    read -rp "Which one is your backup drive? [1-${#drives[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#drives[@]}" ]; then
        echo "${drives[$((choice-1))]}"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------
# 3. Detect phone subfolders worth offering (DCIM, Pictures, etc.)
# ------------------------------------------------------------------
choose_subfolders() {
    local -a common=("DCIM/Camera" "DCIM/Screenshots" "Pictures" "Movies" "Download")
    local -a found=()
    local f

    for f in "${common[@]}"; do
        [ -d "$STORAGE_DIR$f" ] && found+=("$f")
    done

    if [ "${#found[@]}" -eq 0 ]; then
        echo "Couldn't find common folders (DCIM/Camera, Pictures, ...) on the phone." >&2
        read -rp "Enter folder(s) to back up, comma-separated, relative to phone storage root: " manual
        IFS=',' read -ra found <<< "$manual"
    else
        echo "Found these folders on your phone:" >&2
        local i
        for i in "${!found[@]}"; do
            echo "  $((i+1))) ${found[$i]}" >&2
        done
        echo "" >&2
        read -rp "Back up which ones? (e.g. 1,2 or 'all') [all]: " sel
        sel="${sel:-all}"
        if [ "$sel" != "all" ]; then
            local -a picked=()
            IFS=',' read -ra idxs <<< "$sel"
            local idx
            for idx in "${idxs[@]}"; do
                idx="$(echo "$idx" | xargs)"
                if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#found[@]}" ]; then
                    picked+=("${found[$((idx-1))]}")
                fi
            done
            found=("${picked[@]}")
        fi
    fi

    printf '%s\n' "${found[@]}"
}

# ------------------------------------------------------------------
# 4. Setup (first run, or --setup)
# ------------------------------------------------------------------
run_setup() {
    echo "=== First-time setup ==="
    echo ""

    local drive
    drive="$(choose_drive)" || { echo "No drive selected. Aborting."; exit 1; }

    local backup_dir="$drive/PhoneBackup"

    echo ""
    mapfile -t subfolders < <(choose_subfolders)

    if [ "${#subfolders[@]}" -eq 0 ]; then
        echo "No folders selected. Aborting."
        exit 1
    fi

    mkdir -p "$CONFIG_DIR"
    {
        echo "# Generated by snapvault.sh --setup on $(date '+%Y-%m-%d %H:%M:%S')"
        echo "BACKUP_DRIVE=\"$drive\""
        echo "BACKUP_DIR=\"$backup_dir\""
        echo -n "PHONE_SUBFOLDERS=("
        for f in "${subfolders[@]}"; do
            echo -n "\"$f\" "
        done
        echo ")"
    } > "$CONFIG_FILE"

    echo ""
    echo "Setup saved to $CONFIG_FILE"
    echo "  Drive:   $drive"
    echo "  Backups: $backup_dir"
    echo "  Folders: ${subfolders[*]}"
    echo ""
    echo "Run this script again anytime — it'll reuse this config."
    echo "Use --setup to change these choices later."
}

if [ "$FORCE_SETUP" -eq 1 ] || [ ! -f "$CONFIG_FILE" ]; then
    run_setup
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# ------------------------------------------------------------------
# 5. Verify the configured drive is still there
# ------------------------------------------------------------------
if [ ! -d "$BACKUP_DRIVE" ]; then
    echo "Can't find your configured drive at: $BACKUP_DRIVE"
    echo "Is it plugged in? Or run './snapvault.sh --setup' to pick a different one."
    exit 1
fi

mkdir -p "$BACKUP_DIR"
LOG_FILE="$BACKUP_DIR/backup.log"

if [ "$DRY_RUN" == "-n" ]; then
    echo "*** DRY RUN MODE: no files will actually be copied ***"
    echo ""
fi

echo "Backup destination: $BACKUP_DIR"
echo "Folders to back up: ${PHONE_SUBFOLDERS[*]}"
echo ""

# ------------------------------------------------------------------
# 6. Confirm and run
# ------------------------------------------------------------------
read -rp "Do you want to backup now? (y/n): " CONFIRM
case "$CONFIRM" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Backup cancelled."; exit 0 ;;
esac

echo ""
TOTAL_NEW=0

for sub in "${PHONE_SUBFOLDERS[@]}"; do
    SRC="$STORAGE_DIR$sub"
    DEST="$BACKUP_DIR/$sub"

    if [ ! -d "$SRC" ]; then
        log "Skipping '$sub' (not found on phone)"
        continue
    fi

    mkdir -p "$DEST"
    log "Syncing '$sub' ..."

    # --ignore-existing: never overwrite/re-copy files already present -> no duplicates
    # --info=name : print each new file copied, so we can count them
    RESULT=$(rsync -a $DRY_RUN --ignore-existing --info=name "$SRC/" "$DEST/" 2>>"$LOG_FILE")
    COUNT=$(echo "$RESULT" | grep -c . || true)
    TOTAL_NEW=$((TOTAL_NEW + COUNT))

    if [ "$COUNT" -gt 0 ]; then
        echo "$RESULT" | sed 's/^/    + /'
    fi
    log "'$sub': $COUNT new file(s) copied"
done

echo ""
log "Backup finished. Total new files copied: $TOTAL_NEW"
echo "Done. $TOTAL_NEW new file(s) backed up to $BACKUP_DIR"
