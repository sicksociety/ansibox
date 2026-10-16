# AnsiBox

**One-command Ansible home lab on Hyper-V — a "minikube" for Ansible.**

AnsiBox builds a small lab on your Windows machine: one **control node** with Ansible preinstalled, plus as many **worker nodes** as you want. Every VM is created from the official Debian 13 (trixie) `genericcloud` image. The CLI deliberately mirrors minikube (`start`, `stop`, `status`, `ssh`, `delete`, and familiar flags such as `--nodes`, `--cpus`, `--memory`, `--disk-size`).

```powershell
.\ansibox.ps1 start
.\ansibox.ps1 ssh
# then, on the control node:
cd ~/lab && ansible all -m ping
```

## Features

- **One command to a working lab.** `start` downloads the image, builds the network, creates the VMs, waits for SSH and configures the control node.
- **Tiny disk footprint.** Every VM is a Hyper-V differencing disk on one shared, read-only base image, so extra nodes cost almost no disk space.
- **Fixed IPs.** Static addressing via cloud-init network-config, so your inventory never changes between restarts.
- **Self-contained networking.** Creates its own internal Hyper-V switch and NAT. VMs get internet access and your existing network settings are not touched.
- **Ready-to-use Ansible.** The control node gets an inventory, an `ansible.cfg`, an SSH key and a smoke-test playbook.
- **Verified download.** The base image is checked against Debian's published SHA512 sums.
- **minikube-style CLI.** `--nodes 3` and `--nodes=3` both work; `up` and `destroy` still work as aliases for `start` and `delete`.

## Requirements

| Requirement             | Notes                                                                                                                                                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Windows with Hyper-V    | Pro, Enterprise or Education. Enable with `Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All`, then reboot.                           |
| PowerShell 5.1 or newer | Run from an **elevated (Administrator)** prompt. AnsiBox checks this itself and tells you how to relaunch if you forget.                                     |
| NetNat cmdlets          | `New-NetNat` must be available (needed for the lab's internet access).                                                                                       |
| Windows OpenSSH Client  | `ssh`, `scp` and `ssh-keygen` (Settings > Optional features).                                                                                                |
| `curl.exe`              | Ships with current Windows 10/11.                                                                                                                            |
| `qemu-img`              | Used once to convert the qcow2 image to VHDX. If missing, AnsiBox tries to install QEMU via `winget`; otherwise get it from <https://qemu.weilnetz.de/w64/>. |
| Internet access         | For the one-time image download (about a few hundred MB) and for package installs inside the VMs.                                                            |

## Quick start

Open an elevated PowerShell in the folder containing `ansibox.ps1`:

```powershell
# If scripts are blocked on your machine:
Set-ExecutionPolicy -Scope Process Bypass

.\ansibox.ps1 start                 # control + 2 workers (3 nodes)
.\ansibox.ps1 status                # see names, state, IPs
.\ansibox.ps1 ssh                   # shell on the control node
```

On the control node:

```bash
cd ~/lab
ansible all -m ping
ansible-playbook site.yml           # installs htop on the workers and says hello
```

The first `start` takes a while (download, conversion, first boot, package installs). Later starts are fast.

## Commands

| Command  | What it does                                                                    |
| -------- | ------------------------------------------------------------------------------- |
| `start`  | Creates the lab if it doesn't exist; otherwise powers the existing VMs back on. |
| `stop`   | Gracefully shuts down all running lab VMs.                                      |
| `status` | Shows each VM's name, state, IP, CPU count and memory.                          |
| `ssh`    | Connects to a node over SSH (default: `control`).                               |
| `delete` | Removes the lab's VMs, disks, switch and NAT.                                   |
| `help`   | Prints usage (also `-h` / `--help`).                                            |

### `start`

```powershell
.\ansibox.ps1 start
.\ansibox.ps1 start --nodes 4 --memory 2g
.\ansibox.ps1 start --cpus 4 --disk-size 20g
.\ansibox.ps1 start --subnet 10.77.5.0/24
```

`start` behaves like minikube's:

- **No lab yet** -> builds everything.
- **Lab exists, no `--nodes` flag** -> just powers the VMs on (and recreates the switch/NAT if the host lost them, e.g. after a reboot). Files in `~/lab` on the control node are left alone.
- **Lab exists, `--nodes` passed** -> re-runs the full build: existing VMs are kept, missing nodes are added, and the control node's `~/lab/inventory.ini`, `ansible.cfg` and `site.yml` are **regenerated (overwritten)**.

### `ssh`

```powershell
.\ansibox.ps1 ssh                   # control node
.\ansibox.ps1 ssh -n node1          # a worker
.\ansibox.ps1 ssh node2             # positional also works
```

### `delete`

```powershell
.\ansibox.ps1 delete                # asks for confirmation
.\ansibox.ps1 delete --force        # no prompt
.\ansibox.ps1 delete --purge        # also wipes the lab folder (keys + cached image)
```

## Flags

| Flag              | Default           | Range          | Description                                                       |
| ----------------- | ----------------- | -------------- | ----------------------------------------------------------------- |
| `--nodes`         | `3`               | 2-11           | Total node count, **control included** (3 = control + 2 workers). |
| `--cpus`          | `2`               | 1-8            | vCPUs per VM.                                                     |
| `--memory`        | `1024`            | 512-16384 MB   | RAM per VM.                                                       |
| `--disk-size`     | `10g`             | 4-200 GB       | Virtual disk size per VM.                                         |
| `--subnet`        | `172.16.10.0/24`  | any /24        | Lab network.                                                      |
| `--dns`           | `1.1.1.1,8.8.8.8` | -              | DNS servers handed to the VMs (comma or space separated).         |
| `-p`, `--profile` | `lab`             | letters/digits | Lab name; prefixes every VM and the switch/NAT.                   |
| `-n`              | -                 | -              | `--nodes` for `start`, `--node` for `ssh` (as in minikube).       |
| `-f`, `--force`   | off               | -              | Skip the confirmation prompt on `delete`.                         |
| `--purge`         | off               | -              | With `delete`, also remove the lab folder.                        |
| `-h`, `--help`    | -                 | -              | Show usage.                                                       |

Flags accept `--flag value`, `--flag=value`, and the short forms above.

### Size format

Sizes follow minikube: `<number>[b|k|m|g]` with an optional trailing `b`. A bare number is **megabytes**, so `2048`, `2048mb` and `2g` are all the same.

> PowerShell converts an unquoted `2gb` or `512mb` into a byte count before the script sees it. AnsiBox detects such large bare numbers and treats them as bytes, so all of these work.

### Notes on what applies when

- `--cpus` and `--memory` apply to VMs **as they are created**. Existing VMs keep their settings.
- `--disk-size` is applied **once**, when the shared base disk is built. To change it later, use `delete --purge` and start again.

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
- User `ansible` with passwordless `sudo` and key-only SSH (password login locked)
- `hyperv-daemons` installed and `hv-kvp-daemon` enabled
- Configured on first boot through a cloud-init NoCloud seed ISO (built with the IMAPI2 COM API that ships with Windows, so no extra ISO tools are needed)

**Control node (`lab-control`)**

- `ansible` installed from Debian packages
- The lab's private key copied to `~/.ssh/id_ed25519`
- `~/lab/` containing:
  - `inventory.ini` - `[control]` (local connection) and `[nodes]` groups
  - `ansible.cfg` - points at the inventory, disables host key checking
  - `site.yml` - a smoke-test playbook that installs `htop` on the workers and prints a hello message

## Where files live

Lab data is stored in `%USERPROFILE%\ansible-lab` by default. Set the `LAB_HOME` environment variable to put it somewhere else (like `MINIKUBE_HOME`).

```
ansible-lab\
  images\    cached Debian qcow2 + converted base VHDX
  vms\       one folder per VM (differencing disk, seed ISO)
  lab_key    private SSH key for the lab (lab_key.pub = public key)
  known_hosts
```

Connect without the helper:

```powershell
ssh -i "$env:USERPROFILE\ansible-lab\lab_key" ansible@172.16.10.2
```

`LAB_HOME` must be a plain NTFS folder (not compressed or encrypted); Hyper-V can't attach such VHDX files.

## Built-in prerequisite checks

Before any command except `help`, AnsiBox verifies that the machine is ready and stops with a short, readable message if it isn't. You never get a raw PowerShell stack trace.

| Check                                                              | If it fails                                                                                                   |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Running as **Administrator**                                       | Explains how to reopen PowerShell as admin and re-run the same command.                                       |
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
| `Ansible is not installed on control yet`                 | The apt install may have failed. On the control node run `sudo cloud-init status --long`.                                                                   |
| `is still sparse/compressed/encrypted`                    | Set `LAB_HOME` to a plain NTFS folder and retry.                                                                                                            |
| `Checksum mismatch`                                       | The corrupt download is removed automatically; just re-run.                                                                                                 |
| VM exists but on the wrong switch                         | Run `delete`, then `start` to rebuild it with a fixed IP.                                                                                                   |
| Host key warnings after rebuilding a VM                   | AnsiBox clears stale host keys for lab IPs automatically before connecting.                                                                                 |

## Cleaning up

```powershell
.\ansibox.ps1 delete --force            # remove VMs, disks, switch and NAT; keep cached image + keys
.\ansibox.ps1 delete --purge --force    # remove everything, including the cached image and keys
```

Keeping the cached image makes the next `start` much faster.

## Security notes

- The lab SSH key has **no passphrase** and is meant for throwaway lab VMs only. Don't reuse it elsewhere.
- VMs sit behind NAT on an internal switch and are not reachable from your LAN.
- Secure Boot is disabled on the VMs so the cloud image boots reliably.

## License

Add your preferred license here.
