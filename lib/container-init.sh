#!/bin/bash

ROOTFS="$1"
fifo="$2"
shift 2

read -r signal < "$fifo" || exit 1
[[ "$signal" == "GO" ]] || exit 1

mount --make-rprivate / || exit 1
mount -t proc proc "$ROOTFS/proc" || exit 1

cd "$ROOTFS" || exit 1
exec chroot "$ROOTFS" "$@"
