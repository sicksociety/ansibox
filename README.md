# AnsiBox

**One-command Ansible home lab on Hyper-V: a "minikube" for Ansible.**

![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)
![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)
![Platform: Windows + Hyper-V](https://img.shields.io/badge/platform-Windows%20%2B%20Hyper--V-0078D4.svg)

AnsiBox builds a small lab on your Windows machine: one **control node** with Ansible preinstalled, plus as many **worker nodes** as you want. Pick **Debian 13** or **AlmaLinux 9** (a free RHEL clone); every VM is created from the official cloud image of that OS. The CLI deliberately mirrors minikube (`start`, `stop`, `status`, `ssh`, `delete`, and familiar flags such as `--nodes`, `--cpus`, `--memory`, `--disk-size`).

```powershell
.\ansibox.ps1 start
.\ansibox.ps1 ssh
# then, on the control node:
cd ~/lab && ansible all -m ping
```

## Contents

- [Why AnsiBox](#why-ansibox)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Flags](#flags)
- [Choosing an OS](#choosing-an-os)
- [Networking](#networking)
- [What gets built](#what-gets-built)
- [Where files live](#where-files-live)
- [Permissions](#permissions)
- [Built-in prerequisite checks](#built-in-prerequisite-checks)
- [Troubleshooting](#troubleshooting)
- [Cleaning up](#cleaning-up)
- [Security notes](#security-notes)
- [License](#license)

## Why AnsiBox

Learning Ansible needs a few Linux machines you can break and rebuild freely. Setting them up by hand (installing an OS, fixing IPs, copying SSH keys, installing Ansible) takes longer than the learning itself. AnsiBox does all of that for you, so you go from nothing to a working lab with one command, and back to nothing with another.

- **One command to a working lab.** `start` downloads the image, builds the network, creates the VMs, waits for SSH and configures the control node.
- **Two operating systems.** Debian 13 (apt) or AlmaLinux 9 (dnf, SELinux), so you can practice on both Linux families.
- **Tiny disk footprint.** Every VM is a Hyper-V differencing disk on one shared, read-only base image, so extra nodes cost almost no disk space.
- **Fixed IPs.** Static addressing via cloud-init network-config, so your inventory never changes between restarts.
- **Self-contained networking.** Creates its own internal Hyper-V switch and NAT. VMs get internet access and your existing network settings are not touched.
- **Ready-to-use Ansible.** The control node gets an inventory, an `ansible.cfg`, an SSH key and a smoke-test playbook.
- **Verified download.** The base image is checked against the distribution's published checksums.
- **minikube-style CLI.** `--nodes 3` and `--nodes=3` both work; `up` and `destroy` still work as aliases for `start` and `delete`.

## How it works

The big picture: AnsiBox is one PowerShell script that drives Hyper-V on your PC. It creates a private network, boots a few VMs from a cloud image, and gives the first one everything it needs to manage the others.

```
 Your Windows PC (Hyper-V)
 |
 |  ansibox.ps1 creates an internal switch + NAT  (172.16.10.0/24)
 |        172.16.10.1  = your PC (the gateway)
 |
 +-- lab-control  172.16.10.2   Ansible + SSH key + ~/lab (inventory, ansible.cfg, site.yml)
 +-- lab-node1    172.16.10.3   managed over SSH
 +-- lab-node2    172.16.10.4   managed over SSH
```

Each piece exists for a reason:

| Piece                                 | Why it exists                                                                                         |
| ------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| Official cloud image (qcow2)          | A small, ready-made OS built for automation. No installer to click through.                           |
| Shared base disk + differencing disks | Convert the image once; every VM is a thin layer on top. Fast to create, almost no extra disk space.  |
| cloud-init seed ISO                   | Configures each VM on first boot (user, SSH key, hostname, static IP, packages) with no manual steps. |
| Internal switch + NAT                 | Gives the VMs internet access without touching your real network or exposing them to your LAN.        |
| Fixed IPs and MAC addresses           | Your Ansible inventory stays valid after every stop, start or reboot.                                 |
| Lab SSH key                           | Key-only login, so Ansible connects to every node without passwords.                                  |
| `~/lab` on the control node           | A working starting point: inventory, config and a first playbook you can edit and rerun.              |

## Requirements

| Requirement             | Notes                                                                                                                                                               |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Windows with Hyper-V    | Pro, Enterprise or Education. Enable with `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All`, then reboot.                                  |
| PowerShell 5.1 or newer | Run from an **elevated (Administrator)** prompt to create or delete a lab. AnsiBox checks this itself and tells you how to relaunch if you forget.                  |
| NetNat cmdlets          | `New-NetNat` must be available (needed for the lab's internet access).                                                                                              |
| Windows OpenSSH Client  | `ssh`, `scp` and `ssh-keygen` (Settings > Optional features).                                                                                                       |
| `curl.exe`              | Ships with current Windows 10/11.                                                                                                                                   |
| `qemu-img`              | Used once per OS to convert the qcow2 image to VHDX. If missing, AnsiBox tries to install QEMU via `winget`; otherwise get it from <https://qemu.weilnetz.de/w64/>. |
| Internet access         | For the one-time image download (a few hundred MB; about 560 MB for AlmaLinux) and for package installs inside the VMs.                                             |

## Quick start

Open an elevated PowerShell in the folder containing `ansibox.ps1`:

```powershell
# If scripts are blocked on your machine:
Set-ExecutionPolicy -Scope Process Bypass

.\ansibox.ps1 start                 # asks for the OS, then builds control + 2 workers (3 nodes)
.\ansibox.ps1 status                # see names, state, OS, IPs
.\ansibox.ps1 ssh                   # shell on the control node
```

On the control node:

```bash
cd ~/lab
ansible all -m ping
ansible-playbook site.yml           # installs a small package on the workers and says hello
```

### How long does the first start take?

The first `start` is dominated by the image download, so it depends mostly on your internet speed (then conversion, first boot and package installs). As a reference point, a full first run took about **8 minutes on a 30 Mbit/s connection**. The image is cached afterwards, so later starts are much faster.

## Commands

| Command  | What it does                                                                       |
| -------- | ---------------------------------------------------------------------------------- |
| `start`  | Creates the lab if it doesn't exist; otherwise powers the existing VMs back on.    |
| `stop`   | Gracefully shuts down all running lab VMs. Disks and data are kept.                |
| `status` | Shows each VM's name, state, OS, IP, CPU count and memory.                         |
| `ssh`    | Connects to a node over SSH (default: `control`).                                  |
| `delete` | Removes the lab's VMs, disks, switch and NAT.                                      |
| `help`   | Prints usage (also `-h` / `--help`). `help <command>` shows one command in detail. |

`start` and `delete` print the total time they took.

### `start`

```powershell
.\ansibox.ps1 start
.\ansibox.ps1 start --distro rhel
.\ansibox.ps1 start --nodes 4 --memory 2g
.\ansibox.ps1 start --cpus 4 --disk-size 20g
.\ansibox.ps1 start --subnet 10.77.5.0/24
.\ansibox.ps1 start --memory-mode dynamic
```

`start` behaves like minikube's:

- **No lab yet** -> builds everything.
- **Lab exists, no `--nodes` flag** -> just powers the VMs on (and recreates the switch/NAT if the host lost them, e.g. after a reboot). Files in `~/lab` on the control node are left alone.
- **Lab exists, `--nodes` passed** -> re-runs the build: existing VMs are kept and missing nodes are added (nodes are never removed). If you edited `inventory.ini`, `ansible.cfg` or `site.yml` in `~/lab`, **your files are kept**; when AnsiBox's generated version differs, it is saved next to yours as `<name>.new`.

When `start` is about to create a new lab, it asks which OS to use (see [Choosing an OS](#choosing-an-os)). When it is about to create VMs, it also asks whether they should use **static** memory (fixed RAM, the default) or **dynamic** memory. Press Enter for the default, or pass `--distro` / `--memory-mode` to skip the questions. Both questions are skipped when there is no console to answer them (for example in CI), and the defaults are used. Neither is asked when `start` just powers on an existing lab.

### `ssh`

```powershell
.\ansibox.ps1 ssh                   # control node
.\ansibox.ps1 ssh -n node1          # a worker
.\ansibox.ps1 ssh node2             # positional also works
```

`ssh` needs no Administrator rights: a node's IP address is fixed by its name.

### `delete`

```powershell
.\ansibox.ps1 delete                # asks for confirmation
.\ansibox.ps1 delete --force        # no prompt
.\ansibox.ps1 delete --purge        # also wipes the lab folder (keys + cached images)
```

Only VMs named `<profile>-control` and `<profile>-node<N>` are removed; other VMs are left alone.

## Flags

| Flag              | Default           | Range               | Description                                                                  |
| ----------------- | ----------------- | ------------------- | ---------------------------------------------------------------------------- |
| `--nodes`         | `3`               | 2-11                | Total node count, **control included** (3 = control + 2 workers).            |
| `--distro`        | `debian` (asked)  | `debian`, `rhel`    | Operating system of the lab. See [Choosing an OS](#choosing-an-os).          |
| `--cpus`          | `2`               | 1-8                 | vCPUs per VM.                                                                |
| `--memory`        | `1024`            | 512-16384 MB        | RAM per VM.                                                                  |
| `--memory-mode`   | `static` (asked)  | `static`, `dynamic` | Fixed RAM per VM, or let Hyper-V resize it. See [Memory mode](#memory-mode). |
| `--disk-size`     | `10g`             | 4-200 GB            | Virtual disk size per VM.                                                    |
| `--subnet`        | `172.16.10.0/24`  | any /24             | Lab network.                                                                 |
| `--dns`           | `1.1.1.1,8.8.8.8` | -                   | DNS servers handed to the VMs (comma or space separated).                    |
| `-p`, `--profile` | `lab`             | letters/digits      | Lab name; prefixes every VM and the switch/NAT.                              |
| `-n`              | -                 | -                   | `--nodes` for `start`, `--node` for `ssh` (as in minikube).                  |
| `-f`, `--force`   | off               | -                   | Skip the confirmation prompt on `delete`.                                    |
| `--purge`         | off               | -                   | With `delete`, also remove the lab folder.                                   |
| `-h`, `--help`    | -                 | -                   | Show usage.                                                                  |

Flags accept `--flag value`, `--flag=value`, and the short forms above.

### Choosing an OS

AnsiBox supports two operating systems, so you can practice on both Linux families:

| `--distro`                                     | OS                           | Package manager | Image                                   |
| ---------------------------------------------- | ---------------------------- | --------------- | --------------------------------------- |
| `debian` (default; aliases `deb`, `d`)         | Debian 13 "Trixie"           | `apt`           | Official `genericcloud` image           |
| `rhel` (aliases `redhat`, `almalinux`, `alma`) | AlmaLinux 9 (Red Hat family) | `dnf`, SELinux  | Official `GenericCloud` image (~560 MB) |

AlmaLinux is a free, binary-compatible rebuild of RHEL: no subscription and no license, and the same tooling as RHEL, Rocky and CentOS Stream.

- If you don't pass `--distro`, `start` asks **once**, when it creates a new lab.
- A lab uses **one OS until you `delete` it**. The choice is remembered for that lab, and `status` shows it.
- Each OS has its own cached image, so switching later only downloads the image you haven't used yet.
- AlmaLinux needs about 1024 MB per VM to install packages reliably; AnsiBox warns you if you ask for less.
- On both OSes the control node ends up with the same Ansible collections (`ansible.posix`, `community.general`), so the same playbooks work on either lab.

### Size format

Sizes follow minikube: `<number>[b|k|m|g]` with an optional trailing `b`. A bare number is **megabytes**, so `2048`, `2048mb` and `2g` are all the same.

> PowerShell converts an unquoted `2gb` or `512mb` into a byte count before the script sees it. AnsiBox detects such large bare numbers and treats them as bytes, so all of these work.

### Memory mode

- **static** (default): every VM gets exactly `--memory` MB.
- **dynamic**: each VM starts at `--memory` MB, and Hyper-V may shrink it to 512 MB or grow it up to twice `--memory` (at most 16384 MB).

Without `--memory-mode`, `start` asks when it is about to create VMs; pressing Enter keeps static. Hyper-V has no host-wide dynamic-memory setting, so nothing is saved: each run starts from the default again.

Dynamic memory only grows if the guest supports Hyper-V memory ballooning. Inside a VM, `lsmod | grep hv_balloon` shows whether the driver is loaded. If a VM never gets more memory, use static. You can check what a VM uses with `Get-VMMemory -VMName lab-control`.

### Notes on what applies when

- `--cpus`, `--memory` and `--memory-mode` apply to VMs **as they are created**. Existing VMs keep their settings.
- `--disk-size` is applied **once per OS**, when that OS's shared base disk is built. To change it later, use `delete --purge` and start again.

## Networking

AnsiBox creates an **internal** Hyper-V switch named `<profile>-net` (default `lab-net`) and a NAT named `<profile>-nat`. Addresses are fixed:

| Address       | Role                                                |
| ------------- | --------------------------------------------------- |
| `172.16.10.1` | Host / gateway (the `vEthernet` adapter on your PC) |
| `172.16.10.2` | `lab-control`                                       |
| `172.16.10.3` | `lab-node1`                                         |
| `172.16.10.4` | `lab-node2`                                         |
| ...           | `lab-nodeN` -> `172.16.10.(2+N)`                    |

Each VM gets a static MAC (`00:15:5D:10:0A:xx`) so cloud-init can match the right NIC and apply the static config. There is no DHCP on the lab network.

**Limitations**

- Windows supports only **one NAT network per host**. If another NAT already exists, AnsiBox stops and tells you how to remove or reuse it.
- If the chosen subnet is already in use by another interface on your PC, AnsiBox refuses to continue. Pick another with `--subnet`.

## What gets built

**Every VM**

- Generation 2 Hyper-V VM, Secure Boot off, differencing disk on the shared base image
- Static memory by default, or dynamic memory if you chose it (see [Memory mode](#memory-mode))
- User `ansible` with passwordless `sudo` and key-only SSH (password login locked)
- Hyper-V guest services installed and enabled (`hv-kvp-daemon` on Debian, `hypervkvpd` on AlmaLinux), so Hyper-V can see the VM's IP address
- Configured on first boot through a cloud-init NoCloud seed ISO (built with the IMAPI2 COM API that ships with Windows, so no extra ISO tools are needed)

**Control node (`lab-control`)**

- Ansible installed from the OS packages (`ansible` on Debian, `ansible-core` plus the `ansible.posix` and `community.general` collections on AlmaLinux)
- The lab's private key copied to `~/.ssh/id_ed25519`
- `~/lab/` containing:
  - `inventory.ini` - `[control]` (local connection) and `[nodes]` groups
  - `ansible.cfg` - points at the inventory, disables host key checking
  - `site.yml` - a smoke-test playbook that installs a small package on the workers (`htop` on Debian, `tmux` on AlmaLinux) and prints a hello message

## Where files live

Lab data is stored in `%USERPROFILE%\ansible-lab` by default. Set the `LAB_HOME` environment variable to put it somewhere else (like `MINIKUBE_HOME`).

```
ansible-lab\
  images\       cached OS images (qcow2) + the converted base VHDX of each OS
  vms\          one folder per VM (differencing disk, seed ISO)
  lab.distro    which OS this lab was built with (removed by delete)
  lab_key       private SSH key for the lab (lab_key.pub = public key)
  known_hosts
```

Connect without the helper:

```powershell
ssh -i "$env:USERPROFILE\ansible-lab\lab_key" ansible@172.16.10.2
```

`LAB_HOME` must be a plain NTFS folder (not compressed or encrypted); Hyper-V can't attach such VHDX files.

## Permissions

AnsiBox only asks for Administrator rights where they are really needed:

| Command                                                     | Needs                                                                  |
| ----------------------------------------------------------- | ---------------------------------------------------------------------- |
| `help`, `ssh`                                               | Nothing special.                                                       |
| `status`, `stop`, `start` (resume)                          | Administrator **or** membership of the `Hyper-V Administrators` group. |
| `start` (new lab, `--nodes`, or repairing the host network) | Administrator: it creates the virtual switch, NAT and host IP address. |
| `delete`                                                    | Administrator: it removes the virtual switch and NAT network.          |

To use `status`, `stop`, `start` and `ssh` day to day without elevation, run this once in an elevated PowerShell, then sign out and back in:

```powershell
Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-578) -Member $env:USERNAME
```

## Built-in prerequisite checks

Before any command except `help`, AnsiBox verifies that the machine is ready and stops with a short, readable message if it isn't. You never get a raw PowerShell stack trace.

On a healthy machine these checks take about a second or two. The slower Windows feature query (is Hyper-V installed, is a restart pending, is this Windows Home) only runs when one of the quick checks fails, to explain why.

| Check                                                              | If it fails                                                                                                   |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Running as **Administrator** (where required)                      | Explains how to reopen PowerShell as admin and re-run the same command.                                       |
| **Hyper-V is enabled** (and the Windows edition supports it)       | Gives the exact `Enable-WindowsOptionalFeature` command, or says plainly that Windows Home can't run Hyper-V. |
| **Restart pending** after enabling Hyper-V                         | Tells you to reboot.                                                                                          |
| **Hypervisor is actually running**                                 | Points to a reboot, the `hypervisorlaunchtype` boot setting and BIOS/UEFI virtualization.                     |
| **Hyper-V Virtual Machine Management service (`vmms`)** is running | Starts it automatically if it is stopped; if that fails, gives manual steps.                                  |
| **Hyper-V PowerShell module** and a working connection to Hyper-V  | Gives the command to install the module or points at permissions.                                             |
| `start` only: **NetNat, OpenSSH client, `curl.exe`**               | Lists exactly which tools are missing and how to install them.                                                |

Example:

```
X AnsiBox must be run as Administrator (creating VMs, virtual switches and NAT requires it).

  How to fix:
    1. Close this window and open PowerShell as Administrator: right-click Start, then choose "Terminal (Admin)" or "Windows PowerShell (Admin)".
    2. Go back to this folder and re-run:  .\ansibox.ps1 start
```

`help` works without Administrator rights or Hyper-V, so you can read the usage anywhere.

## Troubleshooting

| Symptom                                                   | What to do                                                                                                                                                  |
| --------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Hyper-V is not enabled on this PC`                       | Run `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All`, reboot, and re-run.                                                    |
| `Hyper-V is installed, but the hypervisor is not running` | Reboot; then check `bcdedit /enum` for `hypervisorlaunchtype Auto` and that virtualization is on in BIOS/UEFI.                                              |
| `Another NAT already exists`                              | Windows allows one NAT. Remove it with `Remove-NetNat -Name '<name>'`, or reuse it via a matching `--subnet`/`--profile`.                                   |
| `Subnet ... is already in use`                            | Choose a different `--subnet`.                                                                                                                              |
| `Timed out waiting for SSH`                               | First boot can take 1-3 minutes (more on slow disks or networks). Check the VM console in Hyper-V Manager, and confirm the host adapter has the gateway IP. |
| `Ansible is not installed on control yet`                 | The package install may have failed. On the control node run `sudo cloud-init status --long`. On AlmaLinux, make sure the VMs have at least 1024 MB.        |
| `is still sparse/compressed/encrypted`                    | Set `LAB_HOME` to a plain NTFS folder and retry.                                                                                                            |
| `Checksum mismatch`                                       | The corrupt download is removed automatically; just re-run.                                                                                                 |
| The first `start` is very slow                            | Almost always the image download. It depends on your connection and is only done once per OS.                                                               |
| VM exists but on the wrong switch                         | Run `delete`, then `start` to rebuild it with a fixed IP.                                                                                                   |
| Host key warnings after rebuilding a VM                   | AnsiBox clears stale host keys for lab IPs automatically before connecting.                                                                                 |
| Want a different OS in an existing lab                    | A lab keeps one OS. Run `delete`, then `start --distro <os>`.                                                                                               |

## Cleaning up

```powershell
.\ansibox.ps1 delete --force            # remove VMs, disks, switch and NAT; keep cached images + keys
.\ansibox.ps1 delete --purge --force    # remove everything, including the cached images and keys
```

Keeping the cached images makes the next `start` much faster.

## Security notes

- The lab SSH key has **no passphrase** and is meant for throwaway lab VMs only. Don't reuse it elsewhere.
- VMs sit behind NAT on an internal switch and are not reachable from your LAN.
- Secure Boot is disabled on the VMs so the cloud image boots reliably.

## License

AnsiBox is released under the [MIT License](LICENSE). You are free to use, copy, modify and share it, as long as the copyright notice and license text are kept.
