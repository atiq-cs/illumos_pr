#!/bin/bash
# -----------------------------------------------------------------------------
# Script : create_zfs_pools to create illumos-compatible ZFS root pool
#
# Usage:
#   sudo ./01_create_zfs_pools.sh <pool_name> <root_slice> [data_slice]
#   sudo ./01_create_zfs_pools.sh <pool_name> <root_disk> [data_disk]
#
#  Examples:
#  1. Single ZFS Pool (Standard Caiman-style):
#    slice:
#     sudo ./01_create_zfs_pools.sh spool /dev/dsk/c4t0d0s3
#    disk:
#     sudo ./01_create_zfs_pools.sh spool /dev/dsk/c4t0d0
#
#   Example run on my system: 3rd partition of my disk is where I am
#   creating this zfs pool for illumos
#     sudo ./01_create_zfs_pools.sh spool /dev/dsk/c2t00A075014881A463d0s2
#
#  2. Dual ZFS Pools (Separate Data Pool):
#     sudo ./01_create_zfs_pools.sh spool /dev/dsk/c4t0d0s2 /dev/dsk/c4t0d0s3
#
# Notes:
#   - Script per completion of initial review:
#      https://codeberg.org/atiq/illumos/pulls/1
#
#   - Mimics OpenIndiana/Caiman automated installer layout on a single pool.
#    however, changes BE name from 'openindiana' to 'OI' using variable:
#    $BE_NAME
#
#    - <pool>/ROOT/openindiana
#    - <pool>/ROOT/openindiana/var
#    - <pool>/export
#    - <pool>/export/home
#
#    in addition,
#    - <pool>/swap
#    - <pool>/dump
#
#   - If [data_slice / data_disk] is provided, creates a second pool for /export.
#     - If [data_disk] is OMITTED, /export dataset is created on the root pool
#        as usual.
#   - Requires root privileges or run with sudo.
#   - Destroys ALL data on target device(s).
#
# Refs:
#   - OpenIndiana text installer ZFS layout (single rpool with /export)
#   - Caiman org.openindiana.caiman:install metadata (handled by installer)
#   - 2014-07 Troubleshooting ZFS Swap and Dump devices:
#   https://web.archive.org/web/20250214125030/https://churchill.ddns.me.uk/post/troubleshooting-zfs-swap-and-dump-devices/
#   - OpenIndiana ZFS root-on-ZFS layout and /export hierarchy
#
# tag: illumos, opensolaris, openindiana
# -----------------------------------------------------------------------------

# standard error management: stop if there's an error, fix that first
set -euo pipefail

## Configuration
# Name for the secondary pool if a second device is provided.
SECONDARY_POOL_NAME="data"

# Default boot environment name to match installer-created layout.
BE_NAME="OI"

## Argument Parsing & Validation
POOL_NAME="$1"
ROOT_DEVICE="$2"
DATA_DEVICE="$3"  # Optional 3rd argument

if [[ -z "$POOL_NAME" || -z "$ROOT_DEVICE" ]]; then
  echo "Error: Missing required arguments."
  echo "Usage: $0 <pool_name> <root_device> [data_device]"
  exit 1
fi

## Validation:
# - If a path is given (contains '/'), it must start with /dev/dsk/
# - Bare device IDs like c4t0d0 are accepted
if [[ "$ROOT_DEVICE" == *"/"* && "$ROOT_DEVICE" != /dev/dsk/* ]]; then
  echo "Error: Root device path must start with /dev/dsk/ (or use bare disk ID like c4t0d0)"
  echo "  Got: $ROOT_DEVICE"
  exit 1
fi

if [[ "$DATA_DEVICE" == *"/"* && "$DATA_DEVICE" != /dev/dsk/* ]]; then
  echo "Error: Root device path must start with /dev/dsk/ (or use bare disk ID like c4t0d0)"
  echo "  Got: $DATA_DEVICE"
  exit 1
fi


echo "Configuration:"
echo "  Root Pool:   ${POOL_NAME}"
echo "  Root Device: ${ROOT_DEVICE}"

if [[ -n "$DATA_DEVICE" ]]; then
  echo "  Data Pool:   ${SECONDARY_POOL_NAME} (will mount at /export)"
  echo "  Data Device: ${DATA_DEVICE}"
else
  echo "  Data Layout: Single pool (export resides on ${POOL_NAME})"
fi

echo ""
echo "WARNING: This operation is DESTRUCTIVE."
if [[ -n "$DATA_DEVICE" ]]; then
  echo "  All data on ${ROOT_DEVICE} AND ${DATA_DEVICE} will be destroyed."
else
  echo "  All data on ${ROOT_DEVICE} will be destroyed."
fi
echo ""

## Confirmation [y/N]
read -r -p "Are you sure you want to proceed? [y/N] " response
if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
  echo "Aborted by user."
  exit 0
fi

## Root Pool Creation
echo "Creating system pool '${POOL_NAME}' on ${ROOT_DEVICE}..."
# Improve battery life on laptops
#  atime off and autotrim only on A/C power
zpool create \
  -o ashift=12 \
  -o autotrim=off \
  -O atime=off \
  -O mountpoint=none \
  "${POOL_NAME}" "${ROOT_DEVICE}"

## Virtual Memory Devices (Swap & Dump)
# Calculate swap/dump size based on 50% of physical RAM (Caiman default logic)
TOTAL_RAM_MB=$(prtconf -m)
VOL_SIZE_MB=$(( TOTAL_RAM_MB / 2 ))
VOL_SIZE="${VOL_SIZE_MB}m"

echo "System RAM: ${TOTAL_RAM_MB} MB"
echo "Calculated volume size (50%): ${VOL_SIZE}"

# Explanation:
# Swap: 4KB block size optimized for x86 memory pages
# Dump: 128KB block size optimized for high-throughput crash dumps
echo "Creating swap volume (${VOL_SIZE}, 4KB blocks)..."
zfs create -b 4096 -V "${VOL_SIZE}" "${POOL_NAME}/swap"

echo "Creating dump volume (${VOL_SIZE}, 128KB blocks)..."
## Dump volume: tuned for crash dumps.
# Matches installer behavior (refreservation cleared), features off:
# - Disable compression (value 2 in history = off)
# - Disable checksum (value 2 in history = off)
# - Disable dedup (value 2 in history = off)
# plus explicit primarycache=none for performance.
zfs create \
  -b 131072 \
  -V "${VOL_SIZE}" \
  -o refreservation=none \
  -o compression=off \
  -o checksum=off \
  -o dedup=off \
  -o primarycache=none \
  "${POOL_NAME}/dump"

# Export and re-import to avoid mounting in / (uses temporary mountpoint /mnt)
zpool export "${POOL_NAME}"
zpool import "${POOL_NAME}" -N -R /mnt

## Boot Environment (BE) Structure
echo "Creating boot environment hierarchy..."

# ROOT container
zfs create \
  -o canmount=off \
  -o mountpoint=legacy \
  "${POOL_NAME}/ROOT"

# Primary Boot Environment (OI)
zfs create \
  -o canmount=noauto \
  -o compression=lz4 \
  -o mountpoint=/ \
  "${POOL_NAME}/ROOT/${BE_NAME}"

# Separate /var dataset
zfs create \
  -o canmount=noauto \
  -o compression=lz4 \
  "${POOL_NAME}/ROOT/${BE_NAME}/var"

# Set bootfs
zpool set bootfs="${POOL_NAME}/ROOT/${BE_NAME}" "${POOL_NAME}"

## User Data Dataset (/home)
if [[ -n "$DATA_DEVICE" ]]; then
  # Case A: Dual ZFS Pools - Separate Data Pool for /home
  #  * default mount point is /
  echo "Creating separate data pool '${SECONDARY_POOL_NAME}' on ${DATA_DEVICE}..."
  zpool create \
    -O mountpoint=none \    # instead of -m for readability
    "${SECONDARY_POOL_NAME}" "${DATA_DEVICE}"

  echo " and /home dataset.."
  zfs create \
    -o compression=lz4 \
    -o primarycache=metadata \
    -o devices=off \
    -o mountpoint=/home \
    "${SECONDARY_POOL_NAME}/home"
else
  # Case B: Single ZFS Pool - /home on Root Pool
  echo "Creating /home dataset on '${POOL_NAME}'..."
  zfs create \
    -o compression=lz4 \
    -o primarycache=metadata \
    -o devices=off \
    -o mountpoint=/home \
    "${POOL_NAME}/home"
fi

zpool export "${POOL_NAME}"
if [[ -n "$DATA_DEVICE" ]]; then
  zpool export "${SECONDARY_POOL_NAME}"
fi

echo "SUCCESS: ZFS pool setup complete."