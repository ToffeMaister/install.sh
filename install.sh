#!/usr/bin/env bash
set -euo pipefail

log() { echo -e "\n[$(date +%H:%M:%S)] $*"; }

### CONFIG ###
TIMEZONE="Europe/Stockholm"
HOSTNAME="overlord"
USERNAME="toffe"
ZRAM_SIZE="16G"
MOUNT_OPTS="noatime,compress=zstd:3,discard=async,space_cache=v2"

read -sp "Enter password for $USERNAME: " USER_PASS; echo
read -sp "Enter password for root: " ROOT_PASS; echo

### NETWORK (LIVE ISO ONLY) ###
log "Starting installer network..."
systemctl start NetworkManager || true

### DISK SELECTION ###
INSTALLER_USB=$(findmnt -nvo SOURCE /run/archiso/bootmnt 2>/dev/null | xargs -r lsblk -no PKNAME || true)
lsblk -dpno NAME,SIZE,MODEL | grep disk | grep -v "$INSTALLER_USB"

read -rp "Disk to ERASE (e.g. /dev/nvme0n1): " DISK
[[ -b "$DISK" ]] || { echo "Invalid disk"; exit 1; }

echo "⚠️ ALL DATA ON $DISK WILL BE LOST"
read -rp "Type YES to confirm: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || exit 1

### PARTITIONING ###
log "Partitioning..."
sgdisk --zap-all "$DISK"
sgdisk -n 1:0:+1G -t 1:EF00 "$DISK"
sgdisk -n 2:0:0   -t 2:8300 "$DISK"

udevadm settle
[[ "$DISK" =~ nvme ]] && P="p" || P=""
EFI="${DISK}${P}1"
ROOT="${DISK}${P}2"

mkfs.fat -F32 "$EFI"
mkfs.btrfs -f "$ROOT"

### BTRFS ###
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

### MIRRORS ###
log "Updating mirrors..."
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm reflector
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

### PACSTRAP ###
log "Installing base system..."
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo vim nano git wget \
  networkmanager btrfs-progs snapper \
  pipewire pipewire-alsa pipewire-pulse \
  plasma-meta sddm konsole dolphin firefox \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings

### VERIFY NETWORKMANAGER ###
if [[ ! -f /mnt/usr/lib/systemd/system/NetworkManager.service ]]; then
  echo "❌ NetworkManager.service missing — pacstrap failed"
  exit 1
fi

### FSTAB ###
genfstab -U /mnt > /mnt/etc/fstab

### ZRAM ###
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF

### BASIC CONFIG (NO SYSTEMCTL) ###
arch-chroot /mnt /bin/bash <<EOF
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "sv_SE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
echo "KEYMAP=se-latin1" > /etc/vconsole.conf

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

bootctl install
PARTUUID=\$(blkid -s PARTUUID -o value "$ROOT")

cat > /boot/loader/entries/arch.conf <<EOT
title Arch Linux (Zen)
linux /vmlinuz-linux-zen
initrd /amd-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=\$PARTUUID rw rootflags=subvol=@ quiet nvidia_drm.modeset=1
EOT
EOF

### ENABLE SERVICES (CORRECT WAY) ###
log "Enabling services..."
systemctl --root=/mnt enable NetworkManager
systemctl --root=/mnt enable sddm
systemctl --root=/mnt enable systemd-resolved

### FINISH ###
umount -R /mnt
log "✅ Install finished. Reboot."
# -------------------------
# Pacstrap (FAIL HARD if broken)
# -------------------------
log "Installing base system..."
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo vim nano git wget \
  networkmanager btrfs-progs snapper \
  pipewire pipewire-alsa pipewire-pulse \
  plasma-meta sddm konsole dolphin firefox \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings

log "Pacstrap completed successfully."

# -------------------------
# fstab
# -------------------------
genfstab -U /mnt > /mnt/etc/fstab

# -------------------------
# ZRAM
# -------------------------
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF

# -------------------------
# Chroot
# -------------------------
log "Configuring system..."
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
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

bootctl install
PARTUUID=\$(blkid -s PARTUUID -o value "$ROOT")

cat > /boot/loader/entries/arch.conf <<EOT
title Arch Linux (Zen)
linux /vmlinuz-linux-zen
initrd /amd-ucode.img
initrd /initramfs-linux-zen.img
options root=PARTUUID=\$PARTUUID rw rootflags=subvol=@ quiet nvidia_drm.modeset=1
EOT

systemctl enable NetworkManager
systemctl enable sddm
systemctl enable systemd-resolved
EOF

# -------------------------
# Done
# -------------------------
umount -R /mnt
log "✅ Install finished. Reboot when ready."mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o subvol=@home,"$MOUNT_OPTS" "$ROOT" /mnt/home
mount -o subvol=@snapshots,"$MOUNT_OPTS" "$ROOT" /mnt/.snapshots
mount -o subvol=@var_log,"$MOUNT_OPTS" "$ROOT" /mnt/var/log
mount -o umask=0077 "$EFI" /mnt/boot

# -------------------------
# Mirrors
# -------------------------
log "Updating mirrors..."
sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf
pacman -Sy --noconfirm reflector
reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist

# -------------------------
# Base install
# -------------------------
log "Installing base system..."
pacstrap -K /mnt \
  base base-devel linux-zen linux-zen-headers linux-firmware amd-ucode \
  sudo vim nano git wget \
  networkmanager btrfs-progs snapper \
  pipewire pipewire-alsa pipewire-pulse \
  plasma-meta sddm konsole dolphin firefox \
  nvidia-open-dkms nvidia-utils lib32-nvidia-utils nvidia-settings

# -------------------------
# fstab
# -------------------------
log "Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab

# -------------------------
# ZRAM config
# -------------------------
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = $ZRAM_SIZE
compression-algorithm = zstd
EOF

# -------------------------
# Chroot
# -------------------------
log "Entering chroot..."
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
useradd -m -G wheel -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

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

# -------------------------
# Finish
# -------------------------
log "Unmounting..."
umount -R /mnt

log "✅ Installation complete. You may reboot."mount -o subvol=@home,"$MOUNT_OPTS" "$MAIN_PART" /mnt/home
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




