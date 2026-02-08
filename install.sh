#!/usr/bin/env bash
set -euo pipefail

# --- 1. CONFIGURATION ---
TIMEZONE="Europe/Stockholm"
HOSTNAME="overlord"
USER_NAME="toffe"
ZRAM_SIZE="16G"
MOUNT_OPTS="noatime,compress=zstd:3,discard=async,space_cache=v2"

# Capture passwords once at the start
read -sp "Enter password for $USER_NAME: " USER_PASS; echo
read -sp "Enter password for root: " ROOT_PASS; echo

# --- 2. DISK PREPARATION ---
echo "Available Disks:"
lsblk -dno NAME,SIZE,MODEL
read -rp "Enter disk name (e.g., nvme0n1 or sda): " DISK_NAME
DISK="/dev/$DISK_NAME"

# Wipe and Partition
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"boot"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"root"
udevadm settle

# Identify partitions (NVMe vs SATA)
[[ "$DISK" =~ nvme ]] && P="p" || P=""
EFI_PART="${DISK}${P}1"
ROOT_PART="${DISK}${P}2"

# Format
mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f "$ROOT_PART"

# --- 3. BTRFS SUBVOLUMES ---
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

# --- 4. BASE INSTALLATION ---
# Enable multilib for NVIDIA [cite: 4]
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

# Pacstrap includes Firefox and NVIDIA drivers [cite: 1, 4]
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo nano networkmanager btrfs-progs \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils \
  plasma-meta sddm konsole dolphin firefox git wget

# Generate mount table [cite: 1, 3]
genfstab -U /mnt >> /mnt/etc/fstab

# Write ZRAM config 
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF

# --- 5. SYSTEM CONFIGURATION (CHROOT) ---
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

# User Setup [cite: 4]
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel,storage,power -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Enable Services [cite: 4]
systemctl enable NetworkManager
systemctl enable sddm

# Hardware Optimization: NVIDIA Initramfs & Modesetting [cite: 4]
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

# NVIDIA Update Hook
mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/nvidia.hook <<HOOK
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Package
Target = nvidia-open-dkms
Target = nvidia-utils
Target = linux-zen
[Action]
Description = Update Nvidia module in initcpio
Depends = mkinitcpio
When = PostTransaction
Exec = /usr/bin/mkinitcpio -P
HOOK

# Bootloader (systemd-boot) [cite: 4]
bootctl install
PARTUUID=$(blkid -s PARTUUID -o value "$ROOT_PART")

cat > /boot/loader/entries/arch.conf <<EOT
title Arch Linux (Zen)
linux /vmlinuz-linux-zen
initrd /amd-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=$PARTUUID rw rootflags=subvol=@ nvidia-drm.modeset=1 quiet
EOT
EOF

# --- 6. FINISH ---
umount -R /mnt
echo "✅ Done! Type 'reboot' and Firefox will be available on your desktop."
