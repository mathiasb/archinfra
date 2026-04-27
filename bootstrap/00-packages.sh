#!/bin/bash
# Install all packages
set -euo pipefail

CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${CONFIG_DIR}/config.sh"

echo "--- Installing pacman packages ---"

PACKAGES=(
  # Base system
  amd-ucode base base-devel linux linux-headers linux-firmware
  # Boot
  grub efibootmgr
  # Filesystem
  btrfs-progs snapper snap-pac
  # Network
  # NOTE: ufw is intentionally NOT installed — see docs/network.md.
  networkmanager openssh tailscale fail2ban reflector
  # GPU
  nvidia-open nvidia-utils nvidia-container-toolkit cuda
  # k8s tooling
  helm
  # Container build / CD pipeline (buildkit installed separately via scripts/buildkitd-setup.sh)
  skopeo age sops
  # Dev tools
  git go python python-pip python-pipx nodejs npm terraform
  # CLI utilities
  curl wget vim nano tmux zsh htop btop jq tree lsof stow
  # System tools
  sudo man-db man-pages smartmontools pacman-contrib restic
)

sudo pacman -S --needed --noconfirm "${PACKAGES[@]}"

echo "--- Installing AUR packages ---"

# Install yay if not present
if ! command -v yay &>/dev/null; then
  cd /tmp
  git clone https://aur.archlinux.org/yay.git
  cd yay
  makepkg -si --noconfirm
  cd ~
else
  echo "yay already installed, skipping"
fi

AUR_PACKAGES=(act github-cli)
for pkg in "${AUR_PACKAGES[@]}"; do
  if ! pacman -Qi "${pkg}" &>/dev/null; then
    yay -S --noconfirm "${pkg}"
  else
    echo "${pkg} already installed, skipping"
  fi
done

echo "--- Packages done ---"
