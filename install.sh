#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
HOSTNAME="overlord"
USERNAME="toffe"
TIMEZONE="Europe/Stockholm"
LOCALE="en_US.UTF-8"

echo "==> Starting full Arch install on $DISK"

# ------------------------------------------------------------
# Disk partitioning (UEFI + GPT)
# ------------------------------------------------------------
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:0    -t 2:8300 -c 2:"ROOT" "$DISK"

mkfs.fat -F32 -n EFI "${DISK}p1"
mkfs.btrfs -f -L ROOT "${DISK}p2"

# ------------------------------------------------------------
# Btrfs subvolumes
# ------------------------------------------------------------
mount "${DISK}p2" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots

umount /mnt

mount -o subvol=@,compress=zstd,noatime "${DISK}p2" /mnt
mkdir -p /mnt/{boot,home,var,.snapshots}

mount -o subvol=@home,compress=zstd,noatime "${DISK}p2" /mnt/home
mount -o subvol=@var,compress=zstd,noatime "${DISK}p2" /mnt/var
mount -o subvol=@snapshots,compress=zstd,noatime "${DISK}p2" /mnt/.snapshots
mount "${DISK}p1" /mnt/boot

# ------------------------------------------------------------
# Base install
# ------------------------------------------------------------
pacstrap /mnt \
  base \
  linux-zen \
  linux-zen-headers \
  linux-firmware \
  sudo \
  nano \
  networkmanager \
  pipewire \
  pipewire-pulse \
  pipewire-alsa \
  pipewire-jack \
  wireplumber \
  plasma \
  kde-applications \
  sddm \
  xorg-xwayland \
  mesa \
  vulkan-icd-loader \
  libglvnd \
  egl-wayland \
  egl-gbm \
  git \
  base-devel

genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------------------------------------------
# Chroot configuration
# ------------------------------------------------------------
arch-chroot /mnt /bin/bash <<EOF

set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i "s/#$LOCALE/$LOCALE/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname

cat <<HOSTS >/etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

systemctl enable NetworkManager
systemctl enable sddm

# ------------------------------------------------------------
# User setup
# ------------------------------------------------------------
useradd -m -G wheel -s /bin/bash $USERNAME
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

echo "Set root password:"
passwd
echo "Set password for $USERNAME:"
passwd $USERNAME

# ------------------------------------------------------------
# NVIDIA (DKMS ONLY — no repo drivers)
# ------------------------------------------------------------
pacman -Rns --noconfirm nvidia nvidia-open || true

pacman -S --noconfirm \
  nvidia-dkms \
  nvidia-utils \
  lib32-nvidia-utils \
  opencl-nvidia

# ------------------------------------------------------------
# Blacklist nouveau
# ------------------------------------------------------------
cat <<NOUVEAU >/etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
NOUVEAU

# ------------------------------------------------------------
# NVIDIA DRM (Wayland)
# ------------------------------------------------------------
cat <<NVIDIA >/etc/modprobe.d/nvidia.conf
options nvidia_drm modeset=1
NVIDIA

# ------------------------------------------------------------
# Plasma Wayland NVIDIA stability
# ------------------------------------------------------------
cat <<ENV >/etc/environment
__GLX_VENDOR_LIBRARY_NAME=nvidia
GBM_BACKEND=nvidia-drm
ENV

# ------------------------------------------------------------
# Initramfs
# ------------------------------------------------------------
mkinitcpio -P

# ------------------------------------------------------------
# systemd-boot
# ------------------------------------------------------------
bootctl install

cat <<BOOT >/boot/loader/loader.conf
default arch
timeout 3
editor no
BOOT

cat <<ENTRY >/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options root=LABEL=ROOT rw
ENTRY

EOF

echo "==> Installation complete. Reboot."
