#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

### 1. CONFIGURATION ###
TIMEZONE="Europe/Stockholm" 
HOSTNAME="overlord" 
USERNAME="toffe" 
ZRAM_SIZE="16G" 
MOUNT_OPTS="noatime,compress=zstd:3,discard=async,space_cache=v2" 

# Capture passwords early
read -sp "Enter password for $USERNAME: " USER_PASS; echo 
read -sp "Enter password for root: " ROOT_PASS; echo 

### 2. DISK SELECTION ###
INSTALLER_USB=$(findmnt -nvo SOURCE /run/archiso/bootmnt 2>/dev/null | xargs -r lsblk -no PKNAME || true) 
lsblk -dpno NAME,SIZE,MODEL | grep disk | grep -v "$INSTALLER_USB" 

read -rp "Disk to ERASE (e.g. /dev/nvme0n1): " DISK 
[[ -b "$DISK" ]] || exit 1 

echo "⚠️ ALL DATA ON $DISK WILL BE LOST" 
read -rp "Type YES to confirm: " CONFIRM 
[[ "$CONFIRM" == "YES" ]] || exit 1 

### 3. PARTITIONING & FORMATTING ###
sgdisk --zap-all "$DISK" 
sgdisk -n 1:0:+1G -t 1:EF00 "$DISK" 
sgdisk -n 2:0:0   -t 2:8300 "$DISK" 
udevadm settle 

[[ "$DISK" =~ nvme ]] && P="p" || P="" 
EFI="${DISK}${P}1" 
ROOT="${DISK}${P}2" 

mkfs.fat -F32 "$EFI" 
mkfs.btrfs -f "$ROOT" 

### 4. BTRFS SUBVOLUMES & MOUNTING ###
mount "$ROOT" /mnt 
btrfs subvolume create /mnt/@ 
btrfs subvolume create /mnt/@home 
btrfs subvolume create /mnt/@snapshots 
btrfs subvolume create /mnt/@var_log 
umount /mnt 

mount -o subvol=@,"$MOUNT_OPTS" "$ROOT" /mnt 
mkdir -p /mnt/{boot,home,.snapshots,var/log} 
mount -o subvol=@home,"$MOUNT_OPTS" "$ROOT" /mnt/home 
mount -o subvol=@snapshots,"$MOUNT_OPTS" "$ROOT" /mnt/.snapshots 
mount -o subvol=@var_log,"$MOUNT_OPTS" "$ROOT" /mnt/var/log 
mount -o umask=0077 "$EFI" /mnt/boot 

### 5. BASE INSTALLATION ###
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf 
pacman -Sy --noconfirm reflector 
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist 

pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo vim nano git wget \
  networkmanager btrfs-progs snapper \
  pipewire pipewire-alsa pipewire-pulse \
  plasma-meta sddm konsole dolphin \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings 

### 6. SYSTEM CONFIGURATION ###
genfstab -U /mnt > /mnt/etc/fstab 

cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF 

export TIMEZONE HOSTNAME USERNAME ROOT_PASS USER_PASS ROOT 

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime 
hwclock --systohc 

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen 
echo "sv_SE.UTF-8 UTF-8" >> /etc/locale.gen 
locale-gen 
echo "LANG=en_US.UTF-8" > /etc/locale.conf 

echo "$HOSTNAME" > /etc/hostname 
echo "KEYMAP=se-latin1" > /etc/vconsole.conf 

echo "root:$ROOT_PASS" | chpasswd 
useradd -m -G wheel -s /bin/bash "$USERNAME" 
echo "$USERNAME:$USER_PASS" | chpasswd 
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel 
chmod 440 /etc/sudoers.d/wheel 

# NVIDIA Configuration
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf 
mkinitcpio -P 

# NVIDIA Hook Implementation
mkdir -p /etc/pacman.d/hooks 
cat > /etc/pacman.d/hooks/nvidia.hook <<HOOK
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia

[Action]
Depends=mkinitcpio
When=PostTransaction
Exec=/usr/bin/mkinitcpio -P
HOOK 

# Bootloader
bootctl install 
PARTUUID=\$(blkid -s PARTUUID -o value "$ROOT") 

cat > /boot/loader/loader.conf <<EOT
default arch.conf
timeout 3
editor no
EOT 

cat > /boot/loader/entries/arch.conf <<EOT
title Arch Linux (Zen)
linux /vmlinuz-linux-zen
initrd /amd-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=\$PARTUUID rw rootflags=subvol=@ quiet nvidia_drm.modeset=1
EOT 

systemctl enable NetworkManager sddm systemd-resolved 
EOF

### 7. FINISH ###
umount -R /mnt 
log "✅ Installation complete. Reboot."
