#!/usr/bin/env bash
set -euo pipefail

# Simple timestamped logger
trace() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# -------------------------
# Configuration
# -------------------------
TIMEZONE="Europe/Stockholm"
USER_NAME="toffe"
HOSTNAME="overlord"
MOUNT_OPTS="noatime,compress=zstd:3,discard=async,space_cache=v2"
ZRAM_SIZE="16G"

# Prompt for passwords
read -sp "Enter password for $USER_NAME: " USER_PASS; echo
read -sp "Enter password for root: " ROOT_PASS; echo

# -------------------------
# Preflight & Disk selection
# -------------------------
trace "Starting network services..."
systemctl start systemd-resolved 2>/dev/null || true
systemctl start NetworkManager 2>/dev/null || true

INSTALLER_USB=$(findmnt -nvo SOURCE /run/archiso/bootmnt 2>/dev/null | xargs -r lsblk -no PKNAME 2>/dev/null || true)
[ -z "${INSTALLER_USB:-}" ] && INSTALLER_USB="none"

echo "-------------------------------------------------------"
echo "AVAILABLE DISKS (Installer USB: /dev/$INSTALLER_USB)"
lsblk -dpno NAME,SIZE,MODEL,TYPE | grep "disk" | grep -v "$INSTALLER_USB" || true
echo "-------------------------------------------------------"

read -rp "Enter the FULL PATH of the disk to ERASE (e.g., /dev/nvme0n1): " DISK
if [[ ! -b "$DISK" ]]; then
  echo "Error: $DISK is not a valid block device." >&2
  exit 1
fi

echo "⚠️  WARNING: ALL DATA ON $DISK WILL BE PERMANENTLY DELETED!"
read -rp "Type YES to confirm: " confirm
[[ "$confirm" == "YES" ]] || exit 1

# -------------------------
# Partitioning
# -------------------------
trace "Partitioning $DISK..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1024M -t 1:EF00 "$DISK"   # EFI
sgdisk -n 2:0:0 -t 2:8300 "$DISK"         # Root

udevadm settle
if [[ "$DISK" =~ nvme ]]; then P="p"; else P=""; fi
EFI_PART="${DISK}${P}1"
MAIN_PART="${DISK}${P}2"

mkfs.fat -F32 "$EFI_PART"
mkfs.btrfs -f "$MAIN_PART"

# -------------------------
# Btrfs subvolumes
# -------------------------
trace "Creating Btrfs subvolumes..."
mount "$MAIN_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
umount /mnt

# -------------------------
# Mount subvolumes
# -------------------------
trace "Mounting Btrfs subvolumes..."
mount -o subvol=@,"$MOUNT_OPTS" "$MAIN_PART" /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o subvol=@home,"$MOUNT_OPTS" "$MAIN_PART" /mnt/home
mount -o subvol=@snapshots,"$MOUNT_OPTS" "$MAIN_PART" /mnt/.snapshots
mount -o subvol=@var_log,"$MOUNT_OPTS" "$MAIN_PART" /mnt/var/log
mount -o umask=0077 "$EFI_PART" /mnt/boot

# -------------------------
# Install base system
# -------------------------
trace "Enabling multilib and ranking mirrors..."
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm reflector
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

trace "Pacstrapping base system..."
# FIXED: systemd-resolved and systemd-zram-generator spelling
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo vim nano networkmanager systemd-resolved btrfs-progs \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
  plasma-meta sddm konsole dolphin firefox \
  pipewire-alsa pipewire-pulse \
  snapper systemd-zram-generator git wget

# -------------------------
# Generate fstab
# -------------------------
trace "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab

# Write ZRAM config
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF

# -------------------------
# Chroot configuration
# -------------------------
trace "Entering chroot..."
export TIMEZONE USER_NAME USER_PASS ROOT_PASS HOSTNAME MAIN_PART MOUNT_OPTS ZRAM_SIZE

arch-chroot /mnt /bin/bash <<EOF
set -euo pipefail
trace() { printf '\n[%s] %s\n' "\$(date +%H:%M:%S)" "\$*" >&2; }

# Localization & hostname
trace "Configuring locale, timezone and hostname..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "sv_SE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
echo "KEYMAP=se-latin1" > /etc/vconsole.conf

# Users and sudo
trace "Creating user and configuring sudo..."
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Initramfs & NVIDIA
trace "Configuring initramfs..."
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader
trace "Installing systemd-boot..."
bootctl install
CUR_PARTUUID=\$(blkid -s PARTUUID -o value "$MAIN_PART")

cat > /boot/loader/loader.conf <<EOT
default arch.conf
timeout 3
console-mode max
editor no
EOT

cat > /boot/loader/entries/arch.conf <<EOT
title   Arch Linux (Zen)
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options root=PARTUUID=\$CUR_PARTUUID rw rootflags=subvol=@ quiet nvidia_drm.modeset=1
EOT

# Enable services
systemctl enable NetworkManager sddm systemd-resolved
EOF

# -------------------------
# Final cleanup
# -------------------------
trace "Unmounting target filesystem..."
umount -R /mnt || true

trace "✅ Installation finished. Reboot when ready."mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o subvol=@home,"$MOUNT_OPTS" "$MAIN_PART" /mnt/home
mount -o subvol=@snapshots,"$MOUNT_OPTS" "$MAIN_PART" /mnt/.snapshots
mount -o subvol=@var_log,"$MOUNT_OPTS" "$MAIN_PART" /mnt/var/log
mount -o umask=0077 "$EFI_PART" /mnt/boot

# -------------------------
# Install base system
# -------------------------
trace "Enabling multilib and ranking mirrors..."
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm reflector
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

trace "Pacstrapping base system..."
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo vim nano networkmanager systemd-resolved btrfs-progs \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings \
  plasma-meta sddm konsole dolphin firefox \
  pipewire-alsa pipewire-pulse \
  snapper systemd-zram-generator git wget

# -------------------------
# Generate fstab once (from live environment)
# -------------------------
trace "Generating fstab (from live environment)..."
genfstab -U /mnt > /mnt/etc/fstab

# Write ZRAM config into installed system
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF

# Disable fstrim.timer on the installer root to match discard=async strategy
trace "Disabling fstrim.timer on installer root..."
systemctl --root=/mnt disable fstrim.timer || true

# -------------------------
# Chroot configuration
# -------------------------
trace "Entering chroot..."
export TIMEZONE USER_NAME USER_PASS ROOT_PASS HOSTNAME MAIN_PART MOUNT_OPTS ZRAM_SIZE

arch-chroot /mnt /bin/bash <<'EOF'
set -euo pipefail
trace() { printf '\n[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# Localization & hostname
trace "Configuring locale, timezone and hostname..."
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "sv_SE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
echo "KEYMAP=se-latin1" > /etc/vconsole.conf

# Users and sudo
trace "Creating user and configuring sudo..."
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

# Initramfs & NVIDIA modules
trace "Configuring initramfs to include NVIDIA modules..."
if grep -q '^MODULES=' /etc/mkinitcpio.conf; then
  sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
else
  printf '\nMODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n' >> /etc/mkinitcpio.conf
fi
mkinitcpio -P

# Pacman hook: rebuild initramfs when kernel or NVIDIA packages change
trace "Installing pacman hook for NVIDIA/kernel updates..."
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
NeedsTargets
Exec = /usr/bin/mkinitcpio -P
HOOK

# Snapper setup (do not overwrite fstab)
trace "Configuring snapper for root..."
snapper --no-dbus -c root create-config /
# Do not regenerate /etc/fstab here; fstab was generated from the live environment.
# If a specific fstab line for .snapshots is required, add it from the live environment.

# Bootloader
trace "Installing systemd-boot..."
bootctl install
CUR_PARTUUID=$(blkid -s PARTUUID -o value "$MAIN_PART")

cat > /boot/loader/loader.conf <<EOT
default arch.conf
timeout 3
console-mode max
editor no
EOT

cat > /boot/loader/entries/arch.conf <<EOT
title   Arch Linux (Zen)
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options root=PARTUUID=$CUR_PARTUUID rw rootflags=subvol=@ quiet nvidia_drm.modeset=1
EOT

# Enable essential services
trace "Enabling essential services..."
systemctl enable NetworkManager sddm systemd-resolved

# Note: do NOT enable fstrim.timer because discard=async is used on mounts
EOF

# -------------------------
# Final cleanup
# -------------------------
trace "Unmounting target filesystem..."
umount -R /mnt || true

trace "Installation finished. Reboot when ready."

