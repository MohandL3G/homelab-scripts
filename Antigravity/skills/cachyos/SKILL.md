---
name: cachyos
description: Reference and operational guide for CachyOS Linux, Arch Linux package management, kernel schedulers (BORE, sched-ext), NVIDIA driver configuration (chwd), gaming optimization (Proton, Steam, MangoHud), and dual-boot recovery. Use whenever Mohand asks about CachyOS on his Gaming PC, troubleshooting gaming or driver issues, configuring schedulers, managing pacman/AUR packages, or handling boot and filesystem maintenance.
---

# CachyOS & Arch Linux Gaming Reference Manual

This skill provides comprehensive operational guidelines, quick-reference command recipes, and offline wiki documentation for CachyOS on Mohand's Gaming PC (`MOHANDL3G-PC`).

The complete, unabridged official CachyOS Wiki documentation is mirrored locally inside this skill's `wiki/` directory for fast, offline grep and retrieval.

---

## 1. Hardware Context & Tuning (MOHANDL3G-PC)

* **CPU**: Intel Core i5-13400F (6 Performance cores + 4 Efficient cores, 16 threads).
  * *Tuning*: Hybrid P/E core architecture heavily benefits from the default **BORE** scheduler or **sched-ext** (`scx_lavd` or `scx_rusty`).
* **GPU**: NVIDIA GeForce RTX 5060 (GDDR6/GDDR7).
  * *Tuning*: Requires recent proprietary drivers (`linux-cachyos-nvidia` or `nvidia-dkms`). Uses Wayland Explicit Sync (`linux-drm-syncobj`) under KDE Plasma 6.
* **Display**: Gigabyte G27QA 1440p @ 180 Hz (G-Sync / Adaptive Sync).
  * *Tuning*: Enable Variable Refresh Rate (VRR) in KDE Display Settings (*Always* or *Automatic*).
* **Storage / Dual-Boot**: 2 TB Kingston NVMe SSD partitioned alongside Windows 11.

---

## 2. Package Management

CachyOS is based on Arch Linux and uses `pacman` and `paru` (AUR helper). Binaries are compiled with `-O3`, LTO, and x86-64-v3/v4 microarchitecture optimizations.

### Core Pacman Commands
```bash
# Update system and all repositories
sudo pacman -Syu

# Install packages
sudo pacman -S <package_name>

# Remove package and unused dependencies
sudo pacman -Rns <package_name>

# Search official repositories
pacman -Ss <keyword>

# Search installed packages
pacman -Qs <keyword>

# Clean cached package tarballs
sudo pacman -Sc
```

### AUR (Arch User Repository) via Paru
```bash
# Search and install from AUR
paru -S <aur_package_name>

# Upgrade system including AUR packages
paru -Sua
```

### Key CachyOS Tools
* `cachyos-hello`: Graphical welcome center (quick app installer, driver installer, system tweaks).
* `cachyos-package-installer`: Fast GUI installer for common browsers, gaming suites, and kernels.
* `cachyos-kernel-manager`: GUI/CLI tool to install, configure, and patch custom CachyOS kernels.

---

## 3. Hardware & NVIDIA Driver Management

CachyOS uses `chwd` (**CachyOS Hardware Detection**) to automate GPU and chipset driver setup.

### `chwd` Command Recipes
```bash
# List detected hardware and available driver profiles
chwd -l

# Automatically install recommended drivers (NVIDIA / Intel)
sudo chwd -a

# Install specific profile manually
sudo chwd -i pci <profile_name>

# Remove a driver profile
sudo chwd -r pci <profile_name>
```

### NVIDIA Wayland & DRM Kernel Parameters
Ensure DRM kernel mode setting is active (handled by default in CachyOS bootloader):
```text
nvidia-drm.modeset=1 nvidia-drm.fbdev=1
```
Check driver status and active power/clocks:
```bash
nvidia-smi
```

---

## 4. Kernel Schedulers & CPU Optimization

CachyOS ships custom-tuned Linux kernels (`linux-cachyos`) optimized for low-latency desktop responsiveness and gaming.

### BORE (Burst-Oriented Response Enhancer)
* The default scheduler in `linux-cachyos`.
* Automatically prioritizes bursty interactive tasks (game frames, desktop input) over background CPU tasks. Zero configuration required.

### `sched-ext` (eBPF Schedulers)
CachyOS includes native support for extensible schedulers via BPF:
```bash
# Install sched-ext suite
sudo pacman -S scx-scheds

# Test a scheduler in user space (e.g., scx_lavd or scx_rusty)
sudo scx_lavd

# Enable sched-ext as a persistent systemd service
sudo systemctl enable --now scx.service
```
* Edit `/etc/default/scx` to configure the default scheduler (set `SCX_SCHEDULER=scx_lavd` for optimal gaming and hybrid P/E core distribution).

---

## 5. Gaming Stack & Optimization

### All-in-One Gaming Setup
Install the complete gaming ecosystem in a single command:
```bash
sudo pacman -S cachyos-gaming-meta
```
* Installs: Steam, Lutris, Wine-CachyOS, Proton-CachyOS, GameMode, MangoHud, Vulkan/32-bit drivers.

### Steam Launch Options Recipes
In Steam game properties (`Launch Options`):
* **Enable MangoHud (FPS, temps, frametimes overlay):**
  ```text
  mangohud %command%
  ```
* **Enable GameMode (CPU governor, I/O priority):**
  ```text
  gamemoderun %command%
  ```
* **Enable NVIDIA DLSS / NVAPI support in Proton:**
  ```text
  PROTON_ENABLE_NVAPI=1 %command%
  ```
* **Combine all together:**
  ```text
  mangohud gamemoderun PROTON_ENABLE_NVAPI=1 %command%
  ```

---

## 6. Dual-Boot & System Maintenance

### Fix Clock Mismatch with Windows
Windows uses Local Time for the BIOS RTC, while Linux defaults to UTC. Sync Linux to match Windows:
```bash
sudo timedatectl set-local-rtc 1 --adjust-system-clock
```

### Btrfs Snapshots & Snapper
If Btrfs was chosen during installation, Snapper automatically snapshots root before and after every `pacman` transaction:
```bash
# List snapshots
snapper list

# Rollback to a previous snapshot
sudo snapper-rollback <snapshot_number>
```
*Snapshots can also be selected directly from the bootloader menu (systemd-boot or GRUB) to boot into a working state.*

### Emergency Recovery via Live USB (`cachy-chroot`)
If an update or config ever prevents booting:
1. Boot into the CachyOS Live USB.
2. Open terminal and run:
   ```bash
   sudo cachy-chroot
   ```
   *(Automatically detects installed partitions, subvolumes, and mounts `/boot` and `/`).*
3. Repair drivers, rebuild initramfs (`mkinitcpio -P`), or rollback packages.

---

## 7. Mirrored Wiki Documentation Index

The exact upstream documentation guides from `https://wiki.cachyos.org/` are available in this skill's `wiki/` directory.

### Key Wiki Files for Direct Reference:
* **Gaming & Proton**: `wiki/configuration/gaming.mdx`
* **Sched-ext Schedulers**: `wiki/configuration/sched-ext.mdx`
* **Post-Install Setup**: `wiki/configuration/post_install_setup.mdx`
* **Btrfs Snapshots**: `wiki/configuration/btrfs_snapshots.mdx`
* **Boot Manager Configuration**: `wiki/configuration/boot_manager_configuration.mdx`
* **Secure Boot Setup**: `wiki/configuration/secure_boot_setup.mdx`
* **KDE Desktop Configuration**: `wiki/configuration/desktop_environments/kde.mdx`
* **Cachy-Chroot**: `wiki/features/cachy_chroot.mdx`
* **CachyOS Settings & Tweaks**: `wiki/features/cachyos_settings.mdx`
* **General System Tweaks**: `wiki/configuration/general_system_tweaks.mdx`
* **Automount with fstab**: `wiki/configuration/automount_with_fstab.mdx`
* **FAQ**: `wiki/cachyos_basic/faq.mdx`
