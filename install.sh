#!/usr/bin/env bash
set -e

USERNAME="toffe"
HOSTNAME="overlord"
TIMEZONE="Europe/Stockholm"
LOCALE="en_US.UTF-8"
SWEDISH_LOCALE="sv_SE.UTF-8"

DRIVE="/dev/nvme0n1"
EFI="${DRIVE}p1"
ROOT="${DRIVE}p2"

echo "WARNING: This will erase all data on $DRIVE. Continue? (yes/no)"
read CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 1
fi

# --- PARTITIONING ---
sgdisk --zap-all "$DRIVE"
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DRIVE"
sgdisk -n 2:0:0   -t 2:8300 -c 2:ROOT "$DRIVE"

mkfs.fat -F32 "$EFI"
mkfs.btrfs -f "$ROOT"

mount "$ROOT" /mnt
btrfs su cr /mnt/@
btrfs su cr /mnt/@home
btrfs su cr /mnt/@snapshots
umount /mnt

mount -o subvol=@,compress=zstd,noatime "$ROOT" /mnt
mkdir -p /mnt/{boot,home,.snapshots}
mount -o subvol=@home,compress=zstd,noatime "$ROOT" /mnt/home
mount -o subvol=@snapshots,compress=zstd,noatime "$ROOT" /mnt/.snapshots
mount "$EFI" /mnt/boot

pacman -Sy --noconfirm pacman-contrib btrfs-progs
cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
rankmirrors -n 6 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist

pacstrap -K /mnt base linux-zen linux-zen-headers linux-firmware base-devel amd-ucode nano git btrfs-progs

genfstab -U /mnt >> /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<EOF
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "$LOCALE UTF-8" >> /etc/locale.gen
echo "$SWEDISH_LOCALE UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf
echo "LC_TIME=$SWEDISH_LOCALE" >> /etc/locale.conf
echo "LC_MONETARY=$SWEDISH_LOCALE" >> /etc/locale.conf
echo "LC_NUMERIC=$SWEDISH_LOCALE" >> /etc/locale.conf
echo "LC_MEASUREMENT=$SWEDISH_LOCALE" >> /etc/locale.conf

echo "KEYMAP=sv-latin1" > /etc/vconsole.conf
mkdir -p /etc/X11/xorg.conf.d
cat <<EOX > /etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "se"
EndSection
EOX

echo "$HOSTNAME" > /etc/hostname

sed -i '/\[multilib\]/,/Include/ s/^#//' /etc/pacman.conf

echo "Set root password:"
passwd

useradd -m -g users -G wheel,storage,power -s /bin/bash $USERNAME
echo "Set password for $USERNAME:"
passwd $USERNAME
EDITOR=nano visudo

pacman -S --noconfirm nvidia-open-dkms nvidia-utils lib32-nvidia-utils networkmanager pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber bluez bluez-utils sddm

systemctl enable NetworkManager bluetooth fstrim.timer sddm

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

bootctl install
cat <<EOL > /boot/loader/entries/arch.conf
title   Arch Linux (Zen)
linux   /vmlinuz-linux-zen
initrd  /amd-ucode.img
initrd  /initramfs-linux-zen.img
options root=PARTUUID=\$(blkid -s PARTUUID -o value $ROOT) rw nvidia-drm.modeset=1 nvidia_drm.fbdev=1
EOL

pacman -S --noconfirm systemd-zram-generator
cat <<ZEOF > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram
compression-algorithm = zstd
ZEOF
systemctl enable systemd-zram-setup@zram0

pacman -S --noconfirm plasma-meta kde-applications xdg-user-dirs noto-fonts konsole dolphin
xdg-user-dirs-update

exit
EOF

umount -R /mnt
echo "Installation complete! You can reboot now."
