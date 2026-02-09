#!/usr/bin/env bash
set -euo pipefail

echo "==> Arch Linux NVIDIA-safe installer (DKMS only)"

# ------------------------------------------------------------
# Detect NVIDIA GPU
# ------------------------------------------------------------
GPU_INFO="$(lspci -nn | grep -i nvidia || true)"

if [[ -z "$GPU_INFO" ]]; then
  echo "No NVIDIA GPU detected. Skipping NVIDIA setup."
  exit 0
fi

echo "Detected NVIDIA GPU:"
echo "$GPU_INFO"

# ------------------------------------------------------------
# Base system
# ------------------------------------------------------------
pacman -Syu --noconfirm \
  base \
  linux-zen \
  linux-zen-headers \
  linux-firmware \
  sudo \
  nano \
  networkmanager \
  pipewire \
  pipewire-pulse \
  pipewire-alsa \
  pipewire-jack \
  wireplumber \
  plasma \
  kde-applications \
  sddm \
  xorg-xwayland \
  mesa \
  vulkan-icd-loader \
  libglvnd \
  egl-wayland \
  egl-gbm

systemctl enable NetworkManager
systemctl enable sddm

# ------------------------------------------------------------
# NVIDIA DRIVER (DKMS ONLY — NO REPO DRIVERS)
# ------------------------------------------------------------
echo "==> Installing NVIDIA DKMS driver (safe path)"

pacman -Rns --noconfirm nvidia nvidia-open || true

pacman -S --noconfirm \
  nvidia-dkms \
  nvidia-utils \
  lib32-nvidia-utils \
  opencl-nvidia

# ------------------------------------------------------------
# Blacklist nouveau (required)
# ------------------------------------------------------------
cat <<EOF >/etc/modprobe.d/blacklist-nouveau.conf
blacklist nouveau
options nouveau modeset=0
EOF

# ------------------------------------------------------------
# NVIDIA DRM (Wayland required)
# ------------------------------------------------------------
cat <<EOF >/etc/modprobe.d/nvidia.conf
options nvidia_drm modeset=1
EOF

# ------------------------------------------------------------
# Plasma Wayland NVIDIA fixes (prevents empty desktop)
# ------------------------------------------------------------
cat <<EOF >/etc/environment
__GLX_VENDOR_LIBRARY_NAME=nvidia
KWIN_DRM_USE_EGL_STREAMS=1
GBM_BACKEND=nvidia-drm
EOF

# ------------------------------------------------------------
# Initramfs rebuild
# ------------------------------------------------------------
mkinitcpio -P

# ------------------------------------------------------------
# systemd-boot (safe re-run)
# ------------------------------------------------------------
bootctl install

echo "==> Installation complete. Reboot."
