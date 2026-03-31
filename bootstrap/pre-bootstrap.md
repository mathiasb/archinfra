# koala pre-bootstrap — manual install steps

Complete these steps before running the bootstrap scripts.
Everything from Phase 10 onwards is automated by `bootstrap/run-all.sh`.

---

## Requirements

- Arch Linux ISO written to USB (`dd if=archlinux-x86_64.iso of=/dev/rdiskN bs=1m status=progress`)
- Monitor and keyboard connected to koala
- USB drive plugged in before powering on

---

## Boot from USB

At startup spam **Del** to enter BIOS, or:

```bash
# From the running system (if reinstalling):
sudo efibootmgr --create \
  --disk /dev/sda --part 1 \
  --label "Arch USB" \
  --loader /EFI/boot/bootx64.efi
sudo efibootmgr --bootnext 0001  # use entry number from above
sudo reboot
```

---

## Phase 1-2 — Live environment

```bash
loadkeys us
ping -c 3 archlinux.org   # confirm network
```

---

## Phase 3 — Partition nvme0n1

> nvme1n1 (/data) is NEVER touched. All commands target nvme0n1 only.

```bash
# Deactivate old LVM if present
vgchange -an

gdisk /dev/nvme0n1
```

Create these partitions:

| # | Size | Code | Name |
|---|---|---|---|
| 1 | 1 GiB | EF00 | EFI system partition |
| 2 | 2 GiB | 8300 | Linux filesystem (boot) |
| 3 | 500 GiB | 8300 | Linux filesystem (root) |
| 4 | remaining | 8300 | Linux filesystem (k3s PV) |

```bash
# Wipe old signatures and format
wipefs -a /dev/nvme0n1p3
wipefs -a /dev/nvme0n1p4
partprobe /dev/nvme0n1

mkfs.fat  -F32 -n EFI   /dev/nvme0n1p1
mkfs.ext4 -L   BOOT     /dev/nvme0n1p2
mkfs.btrfs -L  ROOT     /dev/nvme0n1p3
mkfs.ext4 -L   K3SPV    /dev/nvme0n1p4
```

---

## Phase 4 — Mount filesystems

```bash
BTRFS="noatime,compress=zstd,space_cache=v2"

# Root subvolume — create subvolumes
mount /dev/nvme0n1p3 /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var-log
btrfs subvolume create /mnt/@var-lib-k3s
umount /mnt

# Mount with correct options
mount -o ${BTRFS},subvol=@ /dev/nvme0n1p3 /mnt
mkdir -p /mnt/boot/efi /mnt/home /mnt/.snapshots \
         /mnt/var/log /mnt/var/lib/rancher /mnt/data

mount -o ${BTRFS},subvol=@home        /dev/nvme0n1p3 /mnt/home
mount -o ${BTRFS},subvol=@snapshots   /dev/nvme0n1p3 /mnt/.snapshots
mount -o ${BTRFS},subvol=@var-log     /dev/nvme0n1p3 /mnt/var/log
mount -o ${BTRFS},subvol=@var-lib-k3s /dev/nvme0n1p3 /mnt/var/lib/rancher
mount /dev/nvme0n1p2 /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot/efi
mount /dev/nvme1n1p1 /mnt/data
mkdir -p /mnt/data/k3s/pv
mount /dev/nvme0n1p4 /mnt/data/k3s/pv

# Verify — must show 9 mounts
df -h | grep /mnt
```

---

## Phase 5-6 — Install base system + fstab

```bash
reflector --country Sweden,Germany,Netherlands \
  --age 12 --protocol https --sort rate \
  --save /etc/pacman.d/mirrorlist

pacstrap -K /mnt \
  base base-devel linux linux-headers linux-firmware \
  amd-ucode btrfs-progs networkmanager openssh sudo git \
  vim wget curl grub efibootmgr snapper snap-pac

genfstab -U /mnt >> /mnt/etc/fstab

# Verify 9 entries
grep -v "^#" /mnt/etc/fstab | grep -v "^$"
```

---

## Phase 7-8 — Chroot configuration

```bash
arch-chroot /mnt

# Timezone + locale
ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
echo "sv_SE.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Hostname
echo "koala" > /etc/hostname
cat > /etc/hosts << 'HOSTS'
127.0.0.1   localhost
::1         localhost
127.0.1.1   koala.local koala
HOSTS

# Rebuild initramfs (fixes vconsole warning)
mkinitcpio -P

# Passwords + user
passwd
useradd -m -G wheel,video,render -s /bin/zsh mathias
passwd mathias

# Sudo
EDITOR=vim visudo
# Uncomment: %wheel ALL=(ALL:ALL) ALL

# Services
systemctl enable NetworkManager sshd

# GRUB
vim /etc/default/grub
# Set: GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet nvidia-drm.modeset=1"

grub-install --target=x86_64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

# Verify nvidia parameter is in config
grep "nvidia-drm" /boot/grub/grub.cfg

exit
```

---

## Phase 9 — First reboot

```bash
umount -R /mnt
reboot
# Remove USB when screen goes dark
```

Log in as `mathias`. Start SSH:

```bash
sudo systemctl start sshd
```

From flamingo, copy your SSH public key:

```bash
# On flamingo:
ssh-copy-id mathias@koala   # or use 1Password agent
ssh mathias@koala echo "key auth works"
```

---

## Phase 10 — Install NVIDIA drivers + reboot

```bash
sudo pacman -S nvidia-open nvidia-utils nvidia-container-toolkit cuda
sudo reboot
```

After reboot, verify:

```bash
nvidia-smi   # must show RTX 5070
```

---

## Phase 11 — Clone infra repo and run bootstrap

```bash
# Install git if not already installed
sudo pacman -S git

# Clone from GitHub (Gitea not running yet)
git clone https://github.com/mathiasb/archinfra.git ~/infra
cd ~/infra

# Run bootstrap
bootstrap/run-all.sh
```

---

## What bootstrap/run-all.sh does automatically

- Installs all packages (pacman + AUR)
- Configures Snapper, fail2ban, UFW, SSH hardening
- Configures NVIDIA containerd integration
- Installs k3s and redirects PV storage to fast disk
- Installs Flux CLI and bootstraps to Gitea
- Deploys all k3s apps (ingress, cert-manager, Gitea, AI stack, monitoring)
- Sets up restic backup timer to piblock

## After bootstrap completes

1. Set Gitea admin password
2. Import bare repos to Gitea
3. Configure NPM proxy hosts on piguard
4. Add koala models to LiteLLM on piguard
5. Restore `/data/backups/restic-password` from piblock if needed
