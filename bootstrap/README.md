# koala bootstrap

Automated setup scripts for koala after a fresh Arch Linux install.

## Prerequisites (manual steps before running these scripts)

Complete Phases 1-9 of the runbook manually:
- Partition and format disks
- Install base system via pacstrap
- Configure hostname, locale, bootloader
- First reboot — log in as mathias

Then install git and clone this repo:

```bash
sudo pacman -S git
git clone https://github.com/mathiasb/archinfra.git ~/infra
cd ~/infra
bootstrap/run-all.sh
```

## What gets automated

| Script | What it does |
|---|---|
| `00-packages.sh` | Install all packages (pacman + AUR) |
| `01-system.sh` | Snapper, fail2ban, UFW, SSH hardening, reflector |
| `02-nvidia.sh` | NVIDIA containerd config, device plugin prep |
| `03-k3s.sh` | k3s install, kubeconfig, PV redirect |
| `04-flux.sh` | Flux CLI, bootstrap to Gitea |
| `05-apps.sh` | Deploy all k3s apps from manifests |
| `06-backup.sh` | SSH key to piblock, backup script, systemd timer |

## Notes

- Scripts are idempotent — safe to re-run
- Each script checks if its work is already done before proceeding
- Secrets (Gitea token, restic password) are prompted for interactively
- The infra repo is assumed to be at ~/infra
- Run as mathias (sudo available), not as root
