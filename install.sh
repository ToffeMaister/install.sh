#!/usr/bin/env bash
set -euo pipefail

# --- 1. CONFIGURATION ---
[cite_start]TIMEZONE="Europe/Stockholm" [cite: 1]
[cite_start]HOSTNAME="overlord" [cite: 1, 2]
[cite_start]USER_NAME="toffe" [cite: 1, 2]
[cite_start]MOUNT_OPTS="noatime,compress=zstd:3,discard=async,space_cache=v2" [cite: 1]

[cite_start]read -sp "Enter root password: " ROOT_PASS; echo [cite: 1, 2]
[cite_start]read -sp "Enter password for $USER_NAME: " USER_PASS; echo [cite: 1, 2]

# --- 2. SIMPLIFIED DISK SELECTION ---
echo "Available Disks:"
[cite_start]lsblk -dno NAME,SIZE,MODEL [cite: 2]
read -rp "Enter the disk name to ERASE (e.g., sda or nvme0n1): " DISK_NAME

DISK="/dev/$DISK_NAME"

# [cite_start]Wipe GPT/MBR [cite: 2]
[cite_start]sgdisk --zap-all "$DISK" [cite: 1, 2]
# [cite_start]1GB Boot[cite: 2], Remaining Disk as Btrfs
[cite_start]sgdisk -n 1:0:+1024M -t 1:EF00 -c 1:"boot" [cite: 1, 2]
[cite_start]sgdisk -n 2:0:0      -t 2:8300 -c 2:"root" [cite: 1]
udevadm settle

# [cite_start]Handle Partition Naming [cite: 1]
[[ "$DISK" =~ nvme ]] && P="p" || P=""
EFI_PART="${DISK}${P}1"
ROOT_PART="${DISK}${P}2"

# [cite_start]Formatting [cite: 1, 2]
[cite_start]mkfs.fat -F32 "$EFI_PART" [cite: 1, 2]
[cite_start]mkfs.btrfs -f "$ROOT_PART" [cite: 1]

# --- 3. BTRFS SUBVOLUMES & MOUNTING ---
[cite_start]mount "$ROOT_PART" /mnt [cite: 1]
[cite_start]btrfs subvolume create /mnt/@ [cite: 1]
[cite_start]btrfs subvolume create /mnt/@home [cite: 1]
[cite_start]btrfs subvolume create /mnt/@var_log [cite: 1]
[cite_start]umount /mnt [cite: 1]

# [cite_start]Optimized Mounts [cite: 1]
[cite_start]mount -o subvol=@,"$MOUNT_OPTS" "$ROOT_PART" /mnt [cite: 1]
[cite_start]mkdir -p /mnt/{boot,home,var/log} [cite: 1]
[cite_start]mount -o subvol=@home,"$MOUNT_OPTS" "$ROOT_PART" /mnt/home [cite: 1]
[cite_start]mount -o subvol=@var_log,"$MOUNT_OPTS" "$ROOT_PART" /mnt/var/log [cite: 1]
[cite_start]mount -o umask=0077 "$EFI_PART" /mnt/boot [cite: 1]

# --- 4. BASE INSTALLATION ---
# [cite_start]Enable multilib [cite: 1, 2]
[cite_start]sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf [cite: 1, 2]

# [cite_start]Zen Kernel + Hardware Essentials [cite: 1]
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  nano networkmanager sudo btrfs-progs \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
  [cite_start]plasma-meta sddm konsole dolphin [cite: 1, 2]

[cite_start]genfstab -U /mnt >> /mnt/etc/fstab [cite: 1, 2]

# --- 5. SYSTEM CONFIGURATION (CHROOT) ---
export TIMEZONE HOSTNAME USER_NAME ROOT_PASS USER_PASS ROOT_PART

arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail

# [cite_start]Localization & Hostname [cite: 1, 2]
[cite_start]ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime [cite: 1, 2]
[cite_start]hwclock --systohc [cite: 1, 2]
[cite_start]echo "en_US.UTF-8 UTF-8" > /etc/locale.gen [cite: 1, 2]
[cite_start]locale-gen [cite: 1, 2]
[cite_start]echo "LANG=en_US.UTF-8" > /etc/locale.conf [cite: 1, 2]
[cite_start]echo "$HOSTNAME" > /etc/hostname [cite: 1, 2]

# [cite_start]User Setup [cite: 1, 2]
[cite_start]echo "root:$ROOT_PASS" | chpasswd [cite: 1, 2]
[cite_start]useradd -m -G wheel,storage,power -s /bin/bash "$USER_NAME" [cite: 1, 2]
[cite_start]echo "$USER_NAME:$USER_PASS" | chpasswd [cite: 1, 2]
[cite_start]echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel [cite: 1, 2]

# [cite_start]Enable SDDM and Network [cite: 1, 2]
[cite_start]systemctl enable NetworkManager sddm [cite: 1, 2]

# [cite_start]NVIDIA DRM Modeset [cite: 1, 2]
[cite_start]sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf [cite: 1, 2]
[cite_start]mkinitcpio -P [cite: 1, 2]

# [cite_start]Bootloader Setup [cite: 1, 2]
[cite_start]bootctl install [cite: 1, 2]
[cite_start]PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART") [cite: 1, 2]

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

# --- 6. FINISH ---
[cite_start]umount -R /mnt [cite: 1, 2]
[cite_start]echo "✅ Done! Type 'reboot' to start your new system." [cite: 1, 2]
