---
name: Windows PC
description: Operations, diagnostics, hardware monitoring, crash triage, and performance optimization for Mohand's Windows 11 workstation & Gaming PC (MOHANDL3G-PC, 192.168.0.50). Use whenever inspecting Gaming PC specs, diagnosing game crashes or BSODs, running remote PowerShell commands via SSH, monitoring GPU/thermals/VRAM, checking Resizable BAR or drivers, verifying network link speed, managing startup hygiene, working with C:\Portables and C:\Data, or working with WSL.
---

# Windows PC & Gaming PC Operations (MOHANDL3G-PC)

The workstation is Windows 11 IoT Enterprise (Build 26300.9818 x86_64, `MOHANDL3G-PC` at `192.168.0.50`). Default agent syntax is Linux/bash (the agent runs in LXC CT 103 on PVE) - verify target before choosing syntax.

---

## 1. Access & Remote Execution Harness

### SSH Connection
- Target: `ssh gamingpc` (`MohandL3G@192.168.0.50`, Windows 11 IoT Enterprise, PowerShell 7.7.0).
- OpenSSH Server is active and authenticated via public key.
- **Admin Key Requirement:** Windows OpenSSH redirects admin users (`MohandL3G`) to `C:\ProgramData\ssh\administrators_authorized_keys` with strict ACLs (`icacls.exe "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"`).
- **Default Shell Gotcha (Store Updates):**
  When PowerShell updates via WindowsApps, the physical path changes. If `HKLM:\SOFTWARE\OpenSSH\DefaultShell` points to an old binary, OpenSSH rejects all logins with `User not allowed because shell does not exist`.
  *Fix:* `Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value (Get-Process -Id $PID).Path -Force; Restart-Service sshd`.

### Mandatory Remote Execution Pattern: Stdin Heredoc
Passing inline PowerShell strings over SSH often causes remote quote-stripping and premature variable expansion (e.g. bash or remote pwsh expanding `$_` into nothingness or syntax errors).
**Always pipe PowerShell scripts over stdin via heredoc:**

```bash
ssh gamingpc 'pwsh -NoProfile -' << 'EOF'
# Exact PowerShell code runs without quoting or dollar-sign issues
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores
EOF
```

### Syntax & Tool Rules
- **No `rg` on Windows**: `rg` is not installed on the Windows host; always use `Select-String`.
- **Windows Services**: Prefer `sc.exe` for stubborn services (`sc.exe query <svc>`, `sc.exe stop <svc>`, `sc.exe config <svc> start= disabled`).
- **Paths**: Windows repositories use normal `C:\...` paths.
- **Git & Browser Testing**: Do NOT reach out to the Windows PC for Git operations or web automation when local CT 103 tools (`gh`, Playwright MCP) can perform them locally.

---

## 2. Hardware Profile & Fact Sheet

- **CPU**: 13th Gen Intel Core i5-13400F (10 cores / 16 threads: 6 P-cores + 4 E-cores, up to 4.60 GHz, 20 MB L3 Cache, LGA1700).
- **GPU**: NVIDIA GeForce RTX 5060 8 GB GDDR6/GDDR7 (3,840 CUDA cores, 145W TDP cap, Driver 621.14).
  * **Resizable BAR (ReBAR)**: Must remain **Enabled** (`BAR1 Memory Usage: Total: 8192 MiB`). If disabled, the legacy 256 MiB aperture causes severe DX12/Vulkan stuttering and GPU bus stalls.
  * **TDR Delay**: Configured to `TdrDelay = 8` and `TdrDdiDelay = 8` in `HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers` to prevent premature `VIDEO_TDR_FAILURE` (0x116) crashes.
- **Display**: Gigabyte G27QA 27-inch 2560×1440 (1440p QHD) @ **180 Hz**.
- **Motherboard**: Gigabyte H610M K DDR4 (BIOS version `FH`, dated 2025-12-02, Hardware TPM 2.0).
- **RAM**: 32 GB DDR4-3200 dual-channel (2x 16 GB in slots `DDR4-A1` and `DDR4-B1`).
- **Storage**: 2 TB Kingston NV3 PCIe 4.0 NVMe SSD (`KINGSTON SNV3S2000G`), `C:\` partition ~1.82 TiB NTFS.
- **Power Scheme**: `Ultimate Performance` scheme active (`e9a42b02-d5df-448d-aa00-03f14749eb61`).
- **Power Supply & APC UPS Advisory**: Connected to an APC UPS with a degraded/dead battery pending replacement. Sudden mains cuts or voltage dips immediately cut power to the PC, logging Event ID 41 (Kernel-Power) with `BugcheckCode = 0`, `PowerButtonTimestamp = 0`, and no minidump (hardware/GPU did not crash).
- **Memory Integrity (HVCI)**: Disabled in `HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity` for 1% low gaming frametimes. Hyper-V and WSL2 remain fully enabled (`hypervisorlaunchtype = Auto`).

---

## 3. Directory Layout & User Standards

### `C:\Portables` (Portable Applications & Gaming Tools)
- **`DSZ`** (`C:\Portables\DSZ\dsz.exe`): The user's chosen PlayStation 5 DualSense controller utility (configured to run minimized). Note: `DualSenseX` was abandoned/removed in favor of `DSZ`.
- **`BCUninstaller`**: Bulk Crap Uninstaller for clean software removals.
- **`LosslessCut-win-x64`**: Fast lossless video editor.
- **`nvidiaProfileInspector` & `nvidiaDlssGlom`**: GPU profile tuning and DLSS dll swaps.
- **`ProcessExplorer`**: Sysinternals process manager.
- **`SteamAchievementManager-7.0.41`**, **`TrophyVault`**, **`SteamEdit`**: Steam achievement and library tools.
- **Modding / Tools**: `CheatEvolution`, `SmokeAPI`, `mouse2joystick_custom_CEMU`, `SysDVR`, `WandEnhancer`.

### `C:\Data` (User Data & Storage)
- Contains user folders: `Backups`, `DaVinci`, `EpicGames`, `HyperV`, `WSL2`, `Ventoy.vhdx`, and emulation/game tables (`Bloodborne bbport 1.09 v2.1.CT`).

### Rclone UI & Cloudreve Synchronization
- **Application**: Rclone UI (`C:\Program Files\Rclone UI\Rclone UI.exe`), background sync client to Cloudreve on CT 100.
- **Internal Managed Engine**: Self-contained runtime under `C:\Users\MohandL3G\AppData\Local\com.rclone.ui\rclone-versions\v1.76.0\rclone.exe` (auto-update active).
- **CLI in PATH**: User PATH contains `C:\Users\MohandL3G\AppData\Local\com.rclone.ui\bin`, exposing the managed `rclone.exe` to PowerShell without needing an external package.
- **Standalone Policy**: Do not install standalone `Rclone.Rclone` from WinGet/UniGetUI; Rclone UI handles both the GUI daemon and terminal CLI natively.
- **Scheduled Sync Tasks** (Windows Task Scheduler folder `\RcloneUI\`): Automated hourly syncs for `BloodbornePC`, `Bloodborne`, `LuaTools`, and `SignalBackups` targeting Cloudreve.

---

## 4. Common Diagnostics & Recipes

### Hardware & Thermal Telemetry
```bash
# Run fastfetch for full system overview
ssh gamingpc "fastfetch"

# GPU status, temperatures, power draw, and fan speed
ssh gamingpc "nvidia-smi"

# Verify Resizable BAR status (must report 8192 MiB)
ssh gamingpc "nvidia-smi -q" | grep -A 4 "BAR1 Memory Usage"
```

### Crash Dump & BSOD Triage
```bash
ssh gamingpc 'pwsh -NoProfile -' << 'EOF'
# Check kernel minidumps and application crash dumps
Get-ChildItem C:\Windows\Minidump -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime
Get-ChildItem "$env:LOCALAPPDATA\CrashDumps" -ErrorAction SilentlyContinue | Select-Object Name, Length, LastWriteTime

# Query recent Windows Error Reporting (WER) system crash events
Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'} -MaxEvents 5 -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Message | Format-List
EOF
```

### Network Adapter & Link Speed Check
The physical network adapter is a Realtek PCIe GbE Family Controller:
```bash
ssh gamingpc 'pwsh -NoProfile -' << 'EOF'
# Check current negotiated link speed (should be 1 Gbps / 1000 Mbps)
Get-NetAdapter | Select-Object Name, Status, LinkSpeed

# Ensure energy-saving throttles remain disabled
Get-NetAdapterAdvancedProperty -Name "Ethernet" |
    Where-Object { $_.DisplayName -match "Energy|Green|Gigabit Lite|Power Saving" } |
    Select-Object DisplayName, DisplayValue
EOF
```
*Note*: If the link speed reports 100 Mbps, verify the physical Ethernet cable (must be 8-wire Cat5e or Cat6) and check the connected switch port.

### Startup Hygiene & Bloatware Watchdog
```bash
ssh gamingpc 'pwsh -NoProfile -' << 'EOF'
# Check startup commands
Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"

# Guard against Gigabyte BIOS auto-injection or lingering services
Get-Service *Gigabyte*, *EasyTune*, *XTU* -ErrorAction SilentlyContinue
Get-ScheduledTask *GraphicsCardEngine* -ErrorAction SilentlyContinue
EOF
```
*Rule*: Gigabyte software (`EasyTune`, `@BIOS`, `GigabyteUpdateService`, `AppCenter`) and Intel XTU are removed. If `GigabyteUpdateService` ever reappears, disable "Gigabyte Utilities Downloader Configuration" in the UEFI BIOS settings.

### Explorer & Desktop Auto-Refresh Failure (F5 Glitch Triage)
- **Symptom:** Files created or deleted in Explorer or Desktop do not update automatically; deleted files linger as "ghost" icons giving "Item Not Found" errors on second deletion; manual F5 or folder refresh is required.
- **Root Cause:**
  1. **Dead Network Mountpoints (`MountPoints2`):** Offline or defunct network/SMB/RaiDrive shares in `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2` cause background thread pool worker stalls on 21-second TCP timeouts.
  2. **Net Crawling Active:** When `NoNetCrawling` is disabled (default `0`), Explorer aggressively polls all cached network destinations.
  3. **Unified Process Contention:** `SeparateProcess = 0` forces Desktop and folder windows into a single process, serializing shell change notifications (`SHChangeNotify`) behind stalled network queries.
  4. **Orphaned JumpList Locks:** Stale `~RF*.TMP` lock files in `AppData\Roaming\Microsoft\Windows\Recent\CustomDestinations`.
- **Permanent Remediation Recipe:**
```powershell
# 1. Disable Net Crawling and Isolate Desktop Process
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "NoNetCrawling" -Value 1 -Type DWord -Force
Set-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "SeparateProcess" -Value 1 -Type DWord -Force

# 2. Purge dead network mountpoints in MountPoints2
Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2" |
    Where-Object { $_.PSChildName -like "##*" } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# 3. Clean orphaned JumpList lock files & restart Explorer
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Recent\CustomDestinations" -Filter "*~RF*.TMP" |
    Remove-Item -Force -ErrorAction SilentlyContinue
Stop-Process -Name explorer -Force
```

---

## 5. WSL & SSH Key Quirks

- WSL 2.7.13 (Debian) is installed on the workstation but was stopped on Sep 25. Before using Linux commands "in WSL", confirm it is running (`wsl --list --running`). When deliberately started, Windows repositories appear under `/mnt/c/...`.
- Do not install or run Node/npm on Windows when the task can be done in CT 103 or on PVE.
- **`ssh pve` alias gotcha**:
  The `ssh pve` alias works from Windows pwsh ONLY (`C:\Users\MohandL3G\.ssh\config` -> `192.168.0.51`). WSL's OpenSSH does not load it.
  From WSL, use the IP directly with a permission-fixed key copy (the Windows key is `0777` on the `/mnt/c` mount and ssh refuses it):
  ```bash
  mkdir -p /tmp/keys
  cp /mnt/c/Users/MohandL3G/.ssh/id_ed25519 /tmp/keys/id_ed25519
  chmod 600 /tmp/keys/id_ed25519
  ssh -i /tmp/keys/id_ed25519 root@192.168.0.51 'pct list'
  ```
