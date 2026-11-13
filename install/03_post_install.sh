#!/bin/bash
# -----------------------------------------------------------------------------
# Script : illumos/install/03_post_install.sh
# Desc   : Configure ZFS pools, cachefiles, swap, and dump after initial boot
# Date   : 2025-11-29
#
# Usage:
#   $ sudo 03_post_install.sh <root_pool_name>
#
# Notes:
#   - Run after first successful boot from the new ZFS root pool
#   - Validates and activates ZFS swap and dump devices created during install
#   - Generates /etc/zfs/zpool.cache to ensure pools auto-import on reboot
#   - Recommended manual verification after running:
#       1) Reboot test: init 6, verify pools auto-import
#       2) Swap check: swap -s, vmstat 5
#       3) Dump test: dumpadm, verify space and device
#       4) Pool health: zpool scrub spool; zpool scrub matrix
#       5) Performance tuning (optional):
#          - Enable compression: zfs set compression=lz4 spool
#          - Set recordsize: zfs set recordsize=128k <dataset>
#          - Configure ARC limits in /etc/system if needed
#
# Refs:
#   - dumpadm(8) and swap(8) manual pages
#   - OpenIndiana System Administration Guide
#   - illumos ZFS Administration Guide
#
# tag: illumos, opensolaris
# -----------------------------------------------------------------------------

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <root_pool_name>" >&2
  exit 1
fi

# Configuration variables
ROOT_POOL="$1"
# Optional second pool (e.g. "dpool"); leave empty for single pool systems
DATA_POOL=""
ZFS_CACHE_FILE="/etc/zfs/zpool.cache"
SWAP_DEVICE="/dev/zvol/dsk/${ROOT_POOL}/swap"
DUMP_DEVICE="/dev/zvol/dsk/${ROOT_POOL}/dump"

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

# Configure ZFS pool cache file (auto-import at boot)
mkdir -p "$(dirname "$ZFS_CACHE_FILE")"
zpool set cachefile="$ZFS_CACHE_FILE" "$ROOT_POOL"
if [[ -n "$DATA_POOL" ]] && zpool list "$DATA_POOL" >/dev/null 2>&1; then
  zpool set cachefile="$ZFS_CACHE_FILE" "$DATA_POOL"
fi

# Enable ZFS swap volume if present
if [[ -b "$SWAP_DEVICE" ]]; then
  swap -a "$SWAP_DEVICE"
fi

# Configure ZFS dump volume if present
if [[ -b "$DUMP_DEVICE" ]]; then
  dumpadm -d "$DUMP_DEVICE"
fi

# Quick status
zpool status
swap -l
dumpadm
zfs list -o name,used,avail,mounted,mountpoint,canmount


# Also, update /etc/vfstab with correct zfs pool name