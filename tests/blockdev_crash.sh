#!/bin/bash
# Block-level crash test (Linux, root, a kernel with dm-log-writes and loop devices - GitHub's ubuntu runners have both):
#   sudo -E tests/blockdev_crash.sh <tclkit-8.6> ?<commits>? ?<file-system>?
# A real file system (ext4 by default) on a dm-log-writes device records every write it makes, in the order the device completed them (the
# worst case for a power failure).  MK Studio makes a series of commits on it with the durable flushes ON; then the log is replayed onto a copy
# of the original image and the power is "cut" after (up to) 400 different writes: each of those disk states is mounted (the file system
# recovers its journal), the database opened the way MK Studio opens it, and its content must be exactly one of the commits - never older than the
# last one that had been acknowledged, never anything but a complete state.  This tests the commit protocol against a real file system's write
# ordering instead of our model of it.  Not covered: torn writes inside one sector, a disk that lies.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
kit=${1:?usage: blockdev_crash.sh <tclkit> ?commits? ?fs?}
commits=${2:-6}
fs=${3:-ext4}
work=$(mktemp -d /tmp/mks-blockcrash.XXXXXX)
loopd="" ; loopl=""
cleanup() {
    set +e
    mountpoint -q "$work/mnt" && umount "$work/mnt"
    dmsetup remove mkslog >/dev/null 2>&1
    [ -n "$loopd" ] && losetup -d "$loopd"
    [ -n "$loopl" ] && losetup -d "$loopl"
    rm -rf -- "$work"
}
trap cleanup EXIT
modprobe dm-log-writes 2>/dev/null || true
dmsetup targets | grep -q log-writes || { echo "this kernel has no dm-log-writes target"; exit 2; }
mkdir -p "$work/mnt"
truncate -s 128M "$work/base.img"
case $fs in
    ext4) mkfs.ext4 -q -F "$work/base.img" ;;
    xfs)  truncate -s 320M "$work/base.img"; mkfs.xfs -q -f "$work/base.img" ;;
    btrfs) truncate -s 160M "$work/base.img"; mkfs.btrfs -q -f "$work/base.img" ;;
    *) echo "unknown file system $fs"; exit 2 ;;
esac
cp --sparse=always "$work/base.img" "$work/data.img"
truncate -s 2G "$work/log.img"
loopd=$(losetup -f --show "$work/data.img")
loopl=$(losetup -f --show "$work/log.img")
sectors=$(blockdev --getsz "$loopd")
dmsetup create mkslog --table "0 $sectors log-writes $loopd $loopl"
mount -t "$fs" /dev/mapper/mkslog "$work/mnt"
dmsetup message mkslog 0 mark start
echo "== workload: $commits commits on $fs, flush: native library $(basename "${MKS_MKSYNC_DIR:-none}")"
"$kit" "$here/blockdev_workload.tcl" "$work/mnt" "$commits" "$work/expected.txt" mkslog
sync
umount "$work/mnt"
dmsetup remove mkslog
losetup -d "$loopd"; loopd=""
losetup -d "$loopl"; loopl=""
echo "== expected states:"; cat "$work/expected.txt"
python3 "$here/blockdev_crash.py" --log "$work/log.img" --base "$work/base.img" --work "$work" --expected "$work/expected.txt" --kit "$kit" --db crash.mk --fs "$fs"
