#!/usr/bin/env bash
set -euo pipefail

DISK="/dev/nvme0n1"
HOSTNAME="overlord"
USERNAME="toffe"
TIMEZONE="Europe/Stockholm"
LOCALE="en_US.UTF-8"

ROOT_LABEL="ROOT"
EFI_LABEL="EFI"

ROOT_PASSWORD="456"
USER_PASSWORD="123"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -b "$DISK" ]] || die "Disk not found: $DISK"
[[ -d /sys/firmware/efi/efivars ]] || die "Not booted in UEFI mode"

PART_SUFFIX=""
if [[ "$DISK" =~ (nvme|mmcblk) ]]; then
  PART_SUFFIX="p"
fi
EFI_PART="${DISK}${PART_SUFFIX}1"
ROOT_PART="${DISK}${PART_SUFFIX}2"

echo "==> Installing Arch on $DISK"

# ------------------------------------------------------------
# Partitioning
# ------------------------------------------------------------
wipefs -a "$DISK"
sgdisk --zap-all "$DISK"

sgdisk -n 1:0:+1G  -t 1:ef00 -c 1:"EFI"  "$DISK"
sgdisk -n 2:0:0    -t 2:8300 -c 2:"ROOT" "$DISK"

partprobe "$DISK" 2>/dev/null || true
sleep 1

mkfs.fat -F32 -n "$EFI_LABEL" "$EFI_PART"
mkfs.btrfs -f -L "$ROOT_LABEL" "$ROOT_PART"

# ------------------------------------------------------------
# Btrfs subvolumes
# ------------------------------------------------------------
mount "$ROOT_PART" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@snapshots

umount /mnt

# ------------------------------------------------------------
# Mount layout (order matters)
# ------------------------------------------------------------
mount -o subvol=@,compress=zstd,noatime "$ROOT_PART" /mnt

mkdir -p /mnt/boot
mkdir -p /mnt/home
mkdir -p /mnt/var
mkdir -p /mnt/var/log
mkdir -p /mnt/var/cache/pacman/pkg
mkdir -p /mnt/.snapshots

mount -o subvol=@home,compress=zstd,noatime "$ROOT_PART" /mnt/home
mount -o subvol=@var,compress=zstd,noatime "$ROOT_PART" /mnt/var
mount -o subvol=@log,compress=zstd,noatime "$ROOT_PART" /mnt/var/log
mount -o subvol=@pkg,compress=zstd,noatime "$ROOT_PART" /mnt/var/cache/pacman/pkg
mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT_PART" /mnt/.snapshots

mount "$EFI_PART" /mnt/boot

# ------------------------------------------------------------
# Base install (no audio stack)
# ------------------------------------------------------------
pacstrap -K /mnt \
  base \
  linux-zen \
  linux-zen-headers \
  linux-firmware \
  amd-ucode \
  sudo \
  nano \
  networkmanager \
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
  base-devel \
  nvidia-dkms \
  nvidia-utils \
  lib32-nvidia-utils \
  opencl-nvidia

genfstab -U /mnt >> /mnt/etc/fstab

# ------------------------------------------------------------
# Chroot configuration
# ------------------------------------------------------------
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

# Time & locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

sed -i "s/^#\\($LOCALE\\)/\\1/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Swedish keyboard (console only; language stays English)
echo "KEYMAP=sv-latin1" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Services
systemctl enable NetworkManager
systemctl enable sddm

# User
id -u $USERNAME >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash $USERNAME
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 0440 /etc/sudoers.d/wheel

echo "root:$ROOT_PASSWORD" | chpasswd
echo "$USERNAME:$USER_PASSWORD" | chpasswd

# NVIDIA
pacman -Rns --noconfirm nvidia nvidia-open 2>/dev/null || true

cat > /etc/modprobe.d/blacklist-nouveau.conf <<NOUVEAU
blacklist nouveau
options nouveau modeset=0
NOUVEAU

cat > /etc/modprobe.d/nvidia.conf <<NVIDIA
options nvidia_drm modeset=1
NVIDIA

cat > /etc/environment <<ENV
__GLX_VENDOR_LIBRARY_NAME=nvidia
GBM_BACKEND=nvidia-drm
ENV

mkinitcpio -P

# Bootloader
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
options root=LABEL=$ROOT_LABEL rw
ENTRY
EOF

echo "==> Installation complete. Reboot."
