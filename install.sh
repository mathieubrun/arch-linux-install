#!/bin/bash
set -eux

export DEV_DRIVE1="/dev/nvme0n1"
export DEV_DRIVE2="/dev/nvme1n1"

export PART_EFI="/dev/nvme0n1p1"
export PART_EMPTY="/dev/nvme0n1p2"
export PART_DRIVE1="/dev/nvme0n1p3"

export PART_SWAP="/dev/nvme1n1p1"
export PART_DRIVE2="/dev/nvme1n1p2"

export PART_NAME_EFI="efi"
export PART_NAME_SWAP="swap"
export PART_NAME_DRIVE1="system1"
export PART_NAME_DRIVE2="system2"

export PART_SWAP_MAPPED="/dev/mapper/$PART_NAME_SWAP"
export PART_DRIVE1_MAPPED="/dev/mapper/$PART_NAME_DRIVE1"
export PART_DRIVE2_MAPPED="/dev/mapper/$PART_NAME_DRIVE2"

export ADD_LOCALE="fr_CH"
export ADD_KEYMAP="fr_CH-latin1"
export ADD_TIMEZONE="Europe/Zurich"
export FIRST_USER="mathieu"

echo "==== partition $DEV_DRIVE1"
sgdisk --clear $DEV_DRIVE1
sgdisk --zap-all $DEV_DRIVE1
sgdisk --clear \
    --new=1:0:+576MiB  --typecode=1:ef00 --change-name=1:$PART_NAME_EFI  \
    --new=2:0:+7616MiB --typecode=2:8300 --change-name=2:"empty" \
    --new=3:0:0        --typecode=3:8300 --change-name=3:$PART_NAME_DRIVE1 \
    $DEV_DRIVE1
sgdisk --print $DEV_DRIVE1

echo "==== partition $DEV_DRIVE2"
sgdisk --clear $DEV_DRIVE2
sgdisk --zap-all $DEV_DRIVE2
sgdisk --clear \
    --new=1:0:+8192MiB --typecode=1:8200 --change-name=1:$PART_NAME_SWAP  \
    --new=2:0:0        --typecode=2:8300 --change-name=2:$PART_NAME_DRIVE2 \
    $DEV_DRIVE2
sgdisk --print $DEV_DRIVE2

echo "==== crypt partitions"
wipefs --all --force $PART_SWAP
wipefs --all --force $PART_DRIVE1
wipefs --all --force $PART_DRIVE2

echo -n "$DMCRYPT_PASSWORD" | cryptsetup luksFormat $PART_SWAP -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup luksFormat $PART_DRIVE1 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup luksFormat $PART_DRIVE2 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_SWAP $PART_NAME_SWAP -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_DRIVE1 $PART_NAME_DRIVE1 -
echo -n "$DMCRYPT_PASSWORD" | cryptsetup open $PART_DRIVE2 $PART_NAME_DRIVE2 -

wipefs --all --force $PART_DRIVE1_MAPPED
wipefs --all --force $PART_DRIVE2_MAPPED

echo "==== swap and boot"
mkfs.fat -F32 $PART_EFI
mkswap $PART_SWAP_MAPPED
swapon $PART_SWAP_MAPPED

echo "==== btrfs with metadata mirror and data mirrorr"
mkfs.btrfs -m raid1 -d raid1 $PART_DRIVE1_MAPPED $PART_DRIVE2_MAPPED

echo "==== btrfs subvolumes"
mount $PART_DRIVE1_MAPPED /mnt
btrfs sub create /mnt/@root
btrfs sub create /mnt/@home
btrfs sub list /mnt
umount /mnt

mount -o subvol=@root,ssd,compress=lzo,noatime,nodiratime ${PART_DRIVE1_MAPPED} /mnt

mkdir /mnt/{boot,home}

mount $PART_EFI /mnt/boot
mount -o subvol=@home,ssd,compress=lzo,noatime,nodiratime ${PART_DRIVE1_MAPPED} /mnt/home

PART_UUID_SWAP=$(blkid -s UUID -o value $PART_SWAP)
PART_UUID_DRIVE1=$(blkid -s UUID -o value $PART_DRIVE1)
PART_UUID_DRIVE2=$(blkid -s UUID -o value $PART_DRIVE2)

echo "==== install base packages"
timedatectl set-ntp true
pacman -Sy --noconfirm archlinux-keyring

pacstrap /mnt \
    base \
    base-devel \
    btrfs-progs \
    git \
    go \
    intel-ucode \
    linux linux-firmware linux-headers \
    networkmanager wpa_supplicant \
    systemd \
    terminus-font \
    zsh 

echo "==== setup vconsole"
cat << SCRIPT_DELIMITER > /mnt/etc/vconsole.conf
FONT=ter-132n
KEYMAP=$ADD_KEYMAP
SCRIPT_DELIMITER

echo "==== fstab"
genfstab -U /mnt > /mnt/etc/fstab
cat /mnt/etc/fstab

echo "==== create install-chroot script"
cat << SCRIPT_DELIMITER > /mnt/usr/local/bin/install-chroot.sh
#!/bin/bash
set -eux

echo "==== initramfs"
sed -i 's/HOOKS.*/HOOKS=(base systemd autodetect keyboard sd-vconsole consolefont modconf block sd-encrypt btrfs filesystems keyboard fsck)/' /etc/mkinitcpio.conf
sed -i 's/MODULES.*/MODULES=(battery)/' /etc/mkinitcpio.conf
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
options rd.luks.name=$PART_UUID_SWAP=$PART_NAME_SWAP rd.luks.name=$PART_UUID_DRIVE2=$PART_NAME_DRIVE2 rd.luks.name=$PART_UUID_DRIVE1=$PART_NAME_DRIVE1 root=$PART_DRIVE1_MAPPED rootflags=subvol=@root rd.luks.options=discard rw mem_sleep_default=deep i915.enable_dpcd_backlight=1
INNER_DELIMITER

bootctl --path=/boot install

echo "==== setup timezone"
ln -sf /usr/share/zoneinfo/$ADD_TIMEZONE /etc/localtime
hwclock --systohc

echo "==== setup locales"
echo "LANG=$ADD_LOCALE.UTF-8" > /etc/locale.conf
sed -i "/\($ADD_LOCALE.UTF-8 UTF-8\)/s/^#//g" /etc/locale.gen
sed -i "/\(en_US.UTF-8 UTF-8\)/s/^#//g" /etc/locale.gen
locale-gen

echo "=== setup networkmanager"
cat << INNER_DELIMITER > /etc/NetworkManager/conf.d/dhcp-client.conf
[main]
dhcp=dhclient
INNER_DELIMITER
systemctl enable NetworkManager-dispatcher.service 
systemctl enable NetworkManager.service

echo "=== add user"
useradd -m $FIRST_USER -s /bin/zsh
echo "$FIRST_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
visudo -c

echo '$FIRST_USER:$FIRST_USER' | chpasswd

echo "==== install yay"
sed -i 's/#Color/Color/' /etc/pacman.conf
su - $FIRST_USER -c "git clone https://aur.archlinux.org/yay.git \
&& cd yay \
&& makepkg -si --noconfirm"

pacman -Sy --noconfirm \
    nvidia nvidia-utils 
    
echo "==== setup nvidia power management"
cat << INNER_DELIMITER > /lib/udev/rules.d/80-nvidia-pm.rules
# Remove NVIDIA USB xHCI Host Controller devices, if present
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c0330", ATTR{remove}="1"

# Remove NVIDIA USB Type-C UCSI devices, if present
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x0c8000", ATTR{remove}="1"

# Remove NVIDIA Audio devices, if present
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x040300", ATTR{remove}="1"

# Enable runtime PM for NVIDIA VGA/3D controller devices on driver bind
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="auto"

# Disable runtime PM for NVIDIA VGA/3D controller devices on driver unbind
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="on"
ACTION=="unbind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030200", TEST=="power/control", ATTR{power/control}="on"
INNER_DELIMITER

cat << INNER_DELIMITER > /etc/modprobe.d/nvidia.conf
options nvidia "NVreg_DynamicPowerManagement=0x02"
INNER_DELIMITER

echo "==== setup powertop"
pacman -Sy --noconfirm \
    powertop

cat << INNER_DELIMITER > /etc/systemd/system/powertop.service
[Unit]
Description=Powertop tunings

[Service]
Type=exec
ExecStart=/usr/bin/powertop --auto-tune
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
INNER_DELIMITER
systemctl enable powertop.service

echo "==== setup tlp"
pacman -Sy --noconfirm \
    smartmontools tlp tlp-rdw 

sed -i 's/TLP_DEFAULT_MODE.*/TLP_DEFAULT_MODE=BAT/' /etc/default/tlp 
sed -i 's/SATA_LINKPWR_ON_BAT.*/SATA_LINKPWR_ON_BAT=max_performance/' /etc/default/tlp 
sed -i 's/#PCIE_ASPM_ON_BAT.*/PCIE_ASPM_ON_BAT=powersave/' /etc/default/tlp 
sed -i 's/#PCIE_ASPM_ON_AC.*/PCIE_ASPM_ON_AC=default/' /etc/default/tlp 
systemctl enable tlp.service
systemctl enable tlp-sleep.service

echo "==== setup optimus-manager"
# su - $FIRST_USER -c "yay -Sy --noconfirm optimus-manager gdm-prime"
# systemctl enable optimus-manager.service
# systemctl enable gdm.service

echo "==== setup docker"
pacman -Sy --noconfirm \
    docker
usermod -aG docker $FIRST_USER
systemctl enable docker.service

echo "==== setup qemu"
pacman -Sy --noconfirm \
    qemu qemu-arch-extra libvirt virt-manager

usermod -aG libvirt $FIRST_USER
systemctl enable libvirtd

echo "==== misc packages"
pacman -Sy --noconfirm \
    arduino \
    bluez bluez-utils pulseaudio-alsa pulseaudio-bluetooth \
    chrome-gnome-shell \
    code \
    kubectl \
    firefox \
    gnome-backgrounds \
    gnome-control-center \
    gnome-nettool \
    gnome-shell \
    gnome-shell-extensions \
    gnome-system-monitor  \
    gnome-themes-extra \
    gnome-tweaks \
    htop \
    inkscape \
    intellij-idea-community-edition \
    kitty \
    nano \
    nautilus \
    network-manager-applet \
    openssh \
    packer \
    qpdfview \
    sensors-applet \
    rawtherapee \
    syncthing \
    vagrant \
    vim \
    vlc \
    zsh-completions zsh-autosuggestions

echo "==== firefox touch gestures"
echo "MOZ_USE_XINPUT2 DEFAULT=1" >> /etc/security/pam_env.conf

SCRIPT_DELIMITER

chmod u+x /mnt/usr/local/bin/install-chroot.sh

echo "==== run install-chroot in chroot"
arch-chroot /mnt /usr/local/bin/install-chroot.sh