#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
EFI_PART="${DISK}p1"
ROOT_PART="${DISK}p2"

HOSTNAME="overlord"
USERNAME="toffe"
TIMEZONE="Europe/Stockholm"
LOCALE="en_US.UTF-8"

ROOT_LABEL="ROOT"
EFI_LABEL="EFI"

ROOT_PASSWORD="456"
USER_PASSWORD="123"

# ------------------------------------------------------------
# UEFI check
# ------------------------------------------------------------
[[ -d /sys/firmware/efi/efivars ]] || { echo "UEFI required"; exit 1; }

# ------------------------------------------------------------
# Disk partitioning
# ------------------------------------------------------------
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK"
sleep 1

mkfs.fat -F32 -n "$EFI_LABEL" "$EFI_PART"
mkfs.btrfs -f -L "$ROOT_LABEL" "$ROOT_PART"

# ------------------------------------------------------------
# Btrfs subvolumes
# ------------------------------------------------------------
mount "$ROOT_PART" /mnt
for sv in @ @home @var @log @pkg @snapshots; do
  btrfs subvolume create "/mnt/$sv"
done
umount /mnt

# ------------------------------------------------------------
# Mount layout (CORRECT ORDER)
# ------------------------------------------------------------
mount -o subvol=@,compress=zstd,noatime,ssd,discard=async "$ROOT_PART" /mnt
mkdir -p /mnt/{boot,home,var,.snapshots}

mount -o subvol=@home,compress=zstd,noatime,ssd,discard=async "$ROOT_PART" /mnt/home
mount -o subvol=@var,compress=zstd,noatime,ssd,discard=async "$ROOT_PART" /mnt/var
mount -o subvol=@snapshots,compress=zstd,noatime,ssd,discard=async "$ROOT_PART" /mnt/.snapshots

# Create directories INSIDE @var
mkdir -p /mnt/var/log
mkdir -p /mnt/var/cache/pacman/pkg

mount -o subvol=@log,compress=zstd,noatime,ssd,discard=async "$ROOT_PART" /mnt/var/log
mount -o subvol=@pkg,compress=zstd,noatime,ssd,discard=async "$ROOT_PART" /mnt/var/cache/pacman/pkg

mount "$EFI_PART" /mnt/boot

# ------------------------------------------------------------
# Base system
# ------------------------------------------------------------
pacstrap -K /mnt \
  base linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo nano git mkinitcpio iptables-nft

# ------------------------------------------------------------
# Enable multilib
# ------------------------------------------------------------
cat >> /mnt/etc/pacman.conf <<EOF

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

arch-chroot /mnt pacman -Syy --noconfirm

# ------------------------------------------------------------
# Desktop + NVIDIA
# ------------------------------------------------------------
arch-chroot /mnt pacman -S --noconfirm \
  networkmanager sddm plasma kde-applications \
  xorg-xwayland mesa libglvnd egl-wayland egl-gbm \
  base-devel nvidia-dkms nvidia-utils lib32-nvidia-utils opencl-nvidia

# ------------------------------------------------------------
# fstab
# ------------------------------------------------------------
genfstab -U /mnt > /mnt/etc/fstab

# ------------------------------------------------------------
# System configuration
# ------------------------------------------------------------
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=sv-latin1" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
HOSTS

systemctl enable NetworkManager
systemctl enable sddm

useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

echo "root:$ROOT_PASSWORD" | chpasswd
echo "$USERNAME:$USER_PASSWORD" | chpasswd

cat > /etc/modprobe.d/nvidia.conf <<NVIDIA
options nvidia_drm modeset=1
NVIDIA

cat > /etc/environment <<ENV
__GLX_VENDOR_LIBRARY_NAME=nvidia
GBM_BACKEND=nvidia-drm
ENV

mkinitcpio -P

bootctl install

cat > /boot/loader/loader.conf <<BOOT
default arch
timeout 3
editor no
BOOT

cat > /boot/loader/entries/arch.conf <<ENTRY
title   Arch Linux (linux-zen)
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options root=LABEL=$ROOT_LABEL rw nvidia_drm.modeset=1
ENTRY
EOF

echo "Installation complete."
echo "After first boot, enable Btrfs scrub:"
echo "  sudo systemctl enable btrfs-scrub@-.timer"
