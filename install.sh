#!/usr/bin/env bash
set -euo pipefail

log() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

### 1. CONFIGURATION (Edit as needed) ###
TIMEZONE="Europe/Stockholm" 
HOSTNAME="overlord" 
USER_NAME="toffe" 
MOUNT_OPTS="noatime,compress=zstd:3,discard=async,space_cache=v2" 

# Capture passwords
read -sp "Enter root password: " ROOT_PASS; echo
read -sp "Enter password for $USER_NAME: " USER_PASS; echo

### 2. DISK PREPARATION ###
log "Scanning for disks..."
lsblk -dpno NAME,SIZE,MODEL | grep disk
read -rp "Disk to ERASE (e.g. /dev/nvme0n1 or /dev/sda): " DISK

# Wipe disk 
sgdisk --zap-all "$DISK"
# 1GB EFI, Remaining as Btrfs 
sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT"
udevadm settle

[[ "$DISK" =~ nvme ]] && P="p" || P=""
EFI_PART="${DISK}${P}1"
ROOT_PART="${DISK}${P}2"

log "Formatting..."
mkfs.fat -F32 "$EFI_PART" 
mkfs.btrfs -f "$ROOT_PART" 

### 3. BTRFS SUBVOLUMES & MOUNTING ###
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var_log
umount /mnt

# Mount subvolumes with optimization 
mount -o subvol=@,"$MOUNT_OPTS" "$ROOT_PART" /mnt
mkdir -p /mnt/{boot,home,var/log}
mount -o subvol=@home,"$MOUNT_OPTS" "$ROOT_PART" /mnt/home
mount -o subvol=@var_log,"$MOUNT_OPTS" "$ROOT_PART" /mnt/var/log
mount -o umask=0077 "$EFI_PART" /mnt/boot

### 4. BASE INSTALLATION ###
# Enable multilib for NVIDIA 
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

log "Installing base system (Zen kernel)..."
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  nano networkmanager sudo btrfs-progs \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
  plasma-meta sddm konsole dolphin 

# Generate fstab 
genfstab -U /mnt >> /mnt/etc/fstab

### 5. SYSTEM CONFIGURATION (CHROOT) ###
export TIMEZONE HOSTNAME USER_NAME ROOT_PASS USER_PASS ROOT_PART

arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

# Localization 
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# Users 
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel,storage,power -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Enable Services 
systemctl enable NetworkManager
systemctl enable sddm

# Hardware Optimization: Initramfs & NVIDIA 
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (systemd-boot) 
bootctl install
PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")

cat > /boot/loader/loader.conf <<EOT
default arch.conf
timeout 3
EOT

cat > /boot/loader/entries/arch.conf <<EOT
title Arch Linux (Zen)
linux /vmlinuz-linux-zen
initrd /amd-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=$PARTUUID rw rootflags=subvol=@ nvidia-drm.modeset=1 quiet
EOT
EOF

### 6. FINISH ###
umount -R /mnt
log "✅ System ready! Type 'reboot' and log in."
