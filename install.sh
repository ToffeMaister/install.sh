#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Arch Linux Install Script
# Hardware: Ryzen 5600 + RTX 5070 Ti + NVMe (/dev/nvme0n1)
# Boot: UEFI + systemd-boot
# Filesystem: Btrfs (subvolumes @ and @home)
# Swap: zram (systemd-zram-generator)
# Desktop: KDE Plasma (Wayland)
# Kernel: linux-zen
# ============================================================

# --- CONFIG ---
USERNAME="toffe"
HOSTNAME="overlord"
TIMEZONE="Europe/Stockholm"
LANG_LOCALE="en_US.UTF-8"
SV_LOCALE="sv_SE.UTF-8"

DRIVE="/dev/nvme0n1"
EFI="${DRIVE}p1"
ROOT="${DRIVE}p2"

# --- DISK PARTITIONING (UEFI + GPT, UNATTENDED) ---
sgdisk --zap-all "${DRIVE}"
sgdisk -n 1:1MiB:+1GiB -t 1:ef00 -c 1:"EFI"  "${DRIVE}"
sgdisk -n 2:0:0        -t 2:8300 -c 2:"ROOT" "${DRIVE}"

mkfs.fat -F32 "${EFI}"
mkfs.btrfs -L archroot -f "${ROOT}"

# --- BTRFS SUBVOLUMES ---
mount "${ROOT}" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt

# --- MOUNT SUBVOLUMES ---
mount -o noatime,compress=zstd,subvol=@ "${ROOT}" /mnt
mkdir -p /mnt/{home,boot}
mount -o noatime,compress=zstd,subvol=@home "${ROOT}" /mnt/home
mount "${EFI}" /mnt/boot

# --- BASE INSTALL ---
pacstrap /mnt \
  base linux-zen linux-zen-headers \
  linux-firmware amd-ucode \
  btrfs-progs \
  nvidia-open nvidia-utils \
  plasma sddm \
  networkmanager \
  sudo nano

genfstab -U /mnt >> /mnt/etc/fstab

# --- CHROOT CONFIG ---
arch-chroot /mnt /bin/bash <<EOF
set -e

# Time & locale
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

sed -i "s/#${LANG_LOCALE}/${LANG_LOCALE}/" /etc/locale.gen
sed -i "s/#${SV_LOCALE}/${SV_LOCALE}/" /etc/locale.gen
locale-gen

cat > /etc/locale.conf <<EOL
LANG=${LANG_LOCALE}
LC_TIME=${SV_LOCALE}
EOL

# Hostname
echo "${HOSTNAME}" > /etc/hostname

# User
useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Passwords (ONLY INTERACTIVE PROMPTS)
echo "Set root password:"
passwd

echo "Set password for ${USERNAME}:"
passwd "${USERNAME}"

# Enable services
systemctl enable NetworkManager
systemctl enable sddm
systemctl enable nvidia-persistenced

# NVIDIA DRM (Wayland-safe)
cat > /etc/modprobe.d/nvidia.conf <<EON
options nvidia_drm modeset=1 fbdev=1
EON

# Initramfs
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# systemd-boot
bootctl install

cat > /boot/loader/loader.conf <<EOL
default arch.conf
timeout 3
editor no
EOL

cat > /boot/loader/entries/arch.conf <<EOL
title   Arch Linux (linux-zen)
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options root=LABEL=archroot rootflags=subvol=@ rw quiet \
        nvidia_drm.modeset=1 nvidia_drm.fbdev=1 loglevel=3
EOL

EOF

echo "Installation complete. Reboot when ready."
