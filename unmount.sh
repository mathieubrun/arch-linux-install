#!/bin/bash
set -eux

export PART_NAME_SWAP="swap"
export PART_NAME_DRIVE1="system1"
export PART_NAME_DRIVE2="system2"

export PART_SWAP_MAPPED="/dev/mapper/$PART_NAME_SWAP"

swapoff $PART_SWAP_MAPPED
umount -l /mnt/home
umount -l /mnt

cryptsetup close $PART_NAME_SWAP
cryptsetup close $PART_NAME_DRIVE1
cryptsetup close $PART_NAME_DRIVE2

