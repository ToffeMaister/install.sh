#!/usr/bin/env bash
set -euo pipefail

[ -n "${BASH_VERSION:-}" ] || { echo "This script must be run with bash"; exit 1; }

# ============================================================
# Arch Linux Install Script
# Boot: UEFI + systemd-boot
# FS: Btrfs (@, @home)
# Kernel: linux-zen
# Desktop: KDE Plasma (Wayland)
# NVIDIA: nvidia-open (runtime load only)
# Swap: none (zram installed post-boot)
# ============================================================

# --- CONFIG ---
USERNAME="toffe"
HOSTNAME="overlord"
TIMEZONE="Europe/Stockholm"
LANG_LOCALE="en_US.UTF-8"
SV_LOCALE="sv_SE.UTF-8"

ROOT_PASSWORD="456"
USER_PASSWORD="123"

DRIVE="/dev/nvme0n1"
EFI="${DRIVE}p1"
ROOT="${DRIVE}p2"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- DISK PARTITIONING ---
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

# --- PARTUUID ---
ROOT_PARTUUID="$(blkid -s PARTUUID -o value "${ROOT}")"
[ -n "${ROOT_PARTUUID}" ] || die "Failed to read PARTUUID"

# --- CHROOT CONFIG ---
arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc

sed -i "s/#${LANG_LOCALE}/${LANG_LOCALE}/" /etc/locale.gen
sed -i "s/#${SV_LOCALE}/${SV_LOCALE}/" /etc/locale.gen
locale-gen

cat > /etc/locale.conf <<EOL
LANG=${LANG_LOCALE}
LC_TIME=${SV_LOCALE}
EOL

echo "${HOSTNAME}" > /etc/hostname

useradd -m -G wheel -s /bin/bash "${USERNAME}"
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# --- SET PASSWORDS ---
echo "root:${ROOT_PASSWORD}" | chpasswd
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd

systemctl enable NetworkManager
systemctl enable sddm

# --- NVIDIA CONFIG (runtime load only, NOT in initramfs) ---
cat > /etc/modprobe.d/nvidia.conf <<EON
options nvidia_drm modeset=1 fbdev=1
EON

# --- INITRAMFS CONFIG (NO NVIDIA MODULES) ---
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- BOOTLOADER ---
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
options root=PARTUUID=${ROOT_PARTUUID} rootflags=subvol=@ rw quiet loglevel=3 \\
        nvidia_drm.modeset=1 nvidia_drm.fbdev=1
EOL
EOF

# --- PRE-BOOT VALIDATION ---
mountpoint -q /mnt || die "/mnt not mounted"
mountpoint -q /mnt/boot || die "/mnt/boot not mounted"

[ -f /mnt/boot/loader/loader.conf ] || die "Missing loader.conf"
[ -f /mnt/boot/loader/entries/arch.conf ] || die "Missing arch.conf"

grep -q "root=PARTUUID=${ROOT_PARTUUID}" /mnt/boot/loader/entries/arch.conf \
  || die "PARTUUID mismatch in arch.conf"

[ -f /mnt/boot/vmlinuz-linux-zen ] || die "Missing kernel"
[ -f /mnt/boot/initramfs-linux-zen.img ] || die "Missing initramfs"
[ -f /mnt/boot/amd-ucode.img ] || die "Missing microcode"

echo "Installation complete. Reboot when ready."
