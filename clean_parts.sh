#!/bin/bash
set -eux

export DEV_DRIVE1="/dev/nvme0n1"
export DEV_DRIVE2="/dev/nvme1n1"

export PART_EFI1="/dev/nvme0n1p1"
export PART_SWAP1="/dev/nvme0n1p2"
export PART_DRIVE1="/dev/nvme0n1p3"

export PART_EFI2="/dev/nvme1n1p1"
export PART_SWAP2="/dev/nvme1n1p2"
export PART_DRIVE2="/dev/nvme1n1p3"
export PART_DRIVE2_OLD="/dev/nvme1n1p2"

export PART_NAME_EFI1="efi1"
export PART_NAME_EFI2="efi1"
export PART_NAME_SWAP1="swap1"
export PART_NAME_SWAP2="swap2"
export PART_NAME_DRIVE1="system1"
export PART_NAME_DRIVE2="system2"

export PART_SWAP1_MAPPED="/dev/mapper/$PART_NAME_SWAP1"
export PART_SWAP2_MAPPED="/dev/mapper/$PART_NAME_SWAP2"
export PART_DRIVE1_MAPPED="/dev/mapper/$PART_NAME_DRIVE1"
export PART_DRIVE2_MAPPED="/dev/mapper/$PART_NAME_DRIVE2"

echo "==== partition $DEV_DRIVE1"
sgdisk --clear $DEV_DRIVE1
sgdisk --zap-all $DEV_DRIVE1
sgdisk --clear \
    --new=1:0:+768MiB  --typecode=1:ef00 --change-name=1:$PART_NAME_EFI1  \
    --new=2:0:+8192MiB --typecode=2:8300 --change-name=2:$PART_NAME_SWAP1 \
    --new=3:0:0        --typecode=3:8300 --change-name=3:$PART_NAME_DRIVE1 \
    $DEV_DRIVE1
sgdisk --print $DEV_DRIVE1

partprobe $DEV_DRIVE1

echo "==== crypt $DEV_DRIVE1"
wipefs --all --force $PART_SWAP1
wipefs --all --force $PART_DRIVE1

echo -n "$DMCRYPT_PASSWORD" | cryptsetup luksFormat $PART_SWAP1 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup luksFormat $PART_DRIVE1 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_SWAP1 $PART_NAME_SWAP1 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_DRIVE1 $PART_NAME_DRIVE1 -

wipefs --all --force $PART_DRIVE1_MAPPED

mkswap $PART_SWAP1_MAPPED
swapon $PART_SWAP1_MAPPED

echo "==== btrfs on $PART_DRIVE1_MAPPED"
mkfs.btrfs $PART_DRIVE1_MAPPED

mkdir /mnt_drive1
mkdir /mnt_drive2
mkdir /mnt_new

echo "==== copy data from drive2 to drive1"
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_DRIVE2_OLD $PART_NAME_DRIVE2 -
mount $PART_DRIVE1_MAPPED /mnt_drive1
mount -o degraded $PART_DRIVE2_MAPPED /mnt_drive2

btrfs subvolume snapshot -r /mnt_drive2/@root /mnt_drive2/@root_snap
btrfs subvolume snapshot -r /mnt_drive2/@home /mnt_drive2/@home_snap

btrfs send /mnt_drive2/@root_snap | btrfs receive /mnt_drive1
btrfs send /mnt_drive2/@home_snap | btrfs receive /mnt_drive1

btrfs subvolume snapshot /mnt_drive1/@root_snap /mnt_drive1/@root
btrfs subvolume snapshot /mnt_drive1/@home_snap /mnt_drive1/@home

btrfs subvolume delete /mnt_drive1/@root_snap
btrfs subvolume delete /mnt_drive1/@home_snap

umount /mnt_drive1
umount /mnt_drive2

cryptsetup close $PART_NAME_DRIVE2
cryptsetup close $PART_NAME_DRIVE1

echo "==== partition $DEV_DRIVE2"
sgdisk --clear $DEV_DRIVE2
sgdisk --zap-all $DEV_DRIVE2
sgdisk --clear \
    --new=1:0:+768MiB  --typecode=1:ef00 --change-name=1:$PART_NAME_EFI2  \
    --new=2:0:+8192MiB --typecode=2:8300 --change-name=2:$PART_NAME_SWAP2 \
    --new=3:0:0        --typecode=3:8300 --change-name=3:$PART_NAME_DRIVE2 \
    $DEV_DRIVE2
sgdisk --print $DEV_DRIVE2

partprobe $DEV_DRIVE2

echo "==== crypt $DEV_DRIVE2"
wipefs --all --force $PART_DRIVE2

echo -n "$DMCRYPT_PASSWORD" | cryptsetup luksFormat $PART_SWAP2 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup luksFormat $PART_DRIVE2 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_SWAP2 $PART_NAME_SWAP2 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_DRIVE2 $PART_NAME_DRIVE2 -

mkswap $PART_SWAP2_MAPPED
wipefs --all --force $PART_DRIVE2_MAPPED

echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_DRIVE1 $PART_NAME_DRIVE1 -

mount -o subvol=@root,ssd,compress=lzo,noatime,nodiratime ${PART_DRIVE1_MAPPED} /mnt_new
mount $PART_EFI1 /mnt_new/boot
mount -o subvol=@home,ssd,compress=lzo,noatime,nodiratime ${PART_DRIVE1_MAPPED} /mnt_new/home

PART_UUID_SWAP1=$(blkid -s UUID -o value $PART_SWAP1)
PART_UUID_SWAP2=$(blkid -s UUID -o value $PART_SWAP2)
PART_UUID_DRIVE1=$(blkid -s UUID -o value $PART_DRIVE1)
PART_UUID_DRIVE2=$(blkid -s UUID -o value $PART_DRIVE2)

echo "==== fstab"
genfstab -U /mnt_new > /mnt_new/etc/fstab
cat /mnt_new/etc/fstab

echo "==== create install-chroot script"
cat << SCRIPT_DELIMITER > /mnt_new/usr/local/bin/install-chroot.sh
#!/bin/bash
set -eux

echo "==== initramfs"
mkinitcpio -p linux

echo "==== bootloader"
mkdir -p /boot/loader/entries
cat << INNER_DELIMITER > /boot/loader/loader.conf
default  arch
INNER_DELIMITER

cat << INNER_DELIMITER > /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=$PART_UUID_SWAP1=$PART_NAME_SWAP1 rd.luks.name=$PART_UUID_DRIVE1=$PART_NAME_DRIVE1 rd.luks.name=$PART_UUID_DRIVE2=$PART_NAME_DRIVE2 root=$PART_DRIVE1_MAPPED rootflags=subvol=@root rd.luks.options=discard rw mem_sleep_default=deep i915.enable_dpcd_backlight=1
INNER_DELIMITER

bootctl --path=/boot install

SCRIPT_DELIMITER

chmod u+x /mnt_new/usr/local/bin/install-chroot.sh

echo "==== run install-chroot in chroot"
arch-chroot /mnt_new /usr/local/bin/install-chroot.sh




