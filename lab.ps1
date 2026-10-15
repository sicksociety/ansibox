#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    One-command Ansible home lab on Hyper-V (a "minikube start" for Ansible).

.DESCRIPTION
    Builds a control node (Ansible preinstalled) plus N worker nodes from the
    official Debian 13 "genericcloud" image. Every VM is a differencing disk on
    one shared base image, so extra nodes cost almost no disk space.

    Networking: the script creates its own internal Hyper-V switch + NAT and
    gives every VM a FIXED IP (static, via cloud-init network-config):

        172.16.10.1   host / gateway (vEthernet adapter on the host)
        172.16.10.2   lab-control
        172.16.10.3   lab-node1
        172.16.10.4   lab-node2   ...and so on

.EXAMPLE
    .\lab.ps1 up                     # control + 2 workers
    .\lab.ps1 up -Workers 3 -MemoryMB 2048
    .\lab.ps1 up -Subnet 10.77.5     # use another /24
    .\lab.ps1 status
    .\lab.ps1 ssh control
    .\lab.ps1 destroy
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'status', 'ssh', 'stop', 'start', 'destroy', 'help')]
    [string]$Action = 'help',

    # For 'ssh': which node to connect to (control, node1, node2, ...)
    [Parameter(Position = 1)]
    [string]$Target = 'control',

    [ValidateRange(1, 10)] [int]$Workers = 2,
    [ValidateRange(512, 16384)] [int]$MemoryMB = 1024,
    [ValidateRange(1, 8)] [int]$Cpus = 2,
    [ValidateRange(4, 200)] [int]$DiskGB = 10,

    [string]$LabPath = (Join-Path $env:USERPROFILE 'ansible-lab'),
    [string]$Prefix = 'lab',

    # First three octets of the lab /24. .1 = host gateway, .2 = control, .3+ = nodes
    [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}$')]
    [string]$Subnet = '172.16.10',

    # DNS servers handed to the VMs (the internal switch has no DHCP/DNS of its own)
    [string[]]$Dns = @('1.1.1.1', '8.8.8.8'),

    # destroy: skip confirmation / also delete keys and the cached image
    [switch]$Force,
    [switch]$Purge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- constants
$ImageBase = 'https://cloud.debian.org/images/cloud/trixie/latest'
$ImageName = 'debian-13-genericcloud-amd64.qcow2'
$ImgDir    = "$LabPath\images"
$VmDir     = "$LabPath\vms"
$KeyPath   = "$LabPath\lab_key"
$KnownHost = "$LabPath\known_hosts"
$BaseVhdx  = "$ImgDir\debian-13-base.vhdx"
$LabUser   = 'ansible'

$SwitchName = "$Prefix-net"
$NatName    = "$Prefix-nat"
$GatewayIp  = "$Subnet.1"
$NetPrefix  = 24

$BaseOpts  = @('-i', $KeyPath,
               '-o', 'StrictHostKeyChecking=accept-new',
               '-o', "UserKnownHostsFile=$KnownHost",
               '-o', 'LogLevel=ERROR')
$BatchOpts = $BaseOpts + @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=5')

# ------------------------------------------------------------------ helpers
function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    $msg" -ForegroundColor Yellow }

function Show-Usage {
@"
Ansible lab on Hyper-V

  .\lab.ps1 up [-Workers 2] [-MemoryMB 1024] [-Cpus 2] [-DiskGB 10] [-Subnet 172.16.10]
  .\lab.ps1 status
  .\lab.ps1 ssh [control|node1|node2|...]
  .\lab.ps1 stop | start
  .\lab.ps1 destroy [-Force] [-Purge]

Fixed IPs:  $Subnet.1 host/gateway, $Subnet.2 control, $Subnet.3 node1, $Subnet.4 node2, ...

Run from an elevated (Administrator) PowerShell.
Lab data lives in: $LabPath
"@ | Write-Host
}

function Test-Prerequisites {
    Write-Step 'Checking prerequisites'
    if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
        throw "Hyper-V PowerShell module not found. Enable it with:`n  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All`nthen reboot."
    }
    if (-not (Get-Command New-NetNat -ErrorAction SilentlyContinue)) {
        throw 'NetNat cmdlets (New-NetNat) not found - needed to give the lab internet access.'
    }
    foreach ($t in 'ssh', 'scp', 'ssh-keygen', 'curl.exe') {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
            throw "'$t' not found. Install the Windows OpenSSH Client (Settings > Optional features)."
        }
    }
    Write-Ok 'Hyper-V, NetNat and OpenSSH client OK'
}

# --- fixed addressing ------------------------------------------------------
# control -> .2 ; nodeN -> .(2+N)
function Get-LabLastOctet([string]$Name) {
    $suffix = $Name.Substring($Prefix.Length + 1)
    if ($suffix -eq 'control') { return 2 }
    if ($suffix -match '^node(\d+)$') { return (2 + [int]$Matches[1]) }
    throw "Don't know which IP to use for '$Name'."
}
function Get-LabIp([string]$Name)  { return "$Subnet.$(Get-LabLastOctet $Name)" }
# Static MAC (Hyper-V OUI 00:15:5D) so cloud-init can match the NIC reliably
function Get-LabMac([string]$Name) { return ('00155D100A{0:X2}' -f (Get-LabLastOctet $Name)) }

# --- internal switch + host gateway IP + NAT -------------------------------
function Initialize-LabNetwork {
    $alias = "vEthernet ($SwitchName)"

    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        Write-Step "Creating internal switch '$SwitchName'"
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue)) {
        if ($sw.Elapsed.TotalSeconds -gt 30) { throw "Host adapter '$alias' did not appear." }
        Start-Sleep -Seconds 1
    }

    $hasGw = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
             Where-Object { $_.IPAddress -eq $GatewayIp }
    if (-not $hasGw) {
        $clash = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Where-Object { $_.IPAddress -like "$Subnet.*" -and $_.InterfaceAlias -ne $alias }
        if ($clash) {
            throw "Subnet $Subnet.0/24 is already in use on this machine (interface '$(@($clash)[0].InterfaceAlias)'). Pick another with -Subnet."
        }
        Write-Step "Assigning $GatewayIp/$NetPrefix to the host adapter"
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $GatewayIp -PrefixLength $NetPrefix | Out-Null
    }

    $cidr = "$Subnet.0/$NetPrefix"
    $nats = @(Get-NetNat -ErrorAction SilentlyContinue)
    $mine = $nats | Where-Object { $_.Name -eq $NatName }
    if ($mine) {
        if ($mine.InternalIPInterfaceAddressPrefix -ne $cidr) {
            throw "NAT '$NatName' exists for $($mine.InternalIPInterfaceAddressPrefix), not $cidr. Run '.\lab.ps1 destroy' first."
        }
    } else {
        if ($nats.Count -gt 0) {
            throw "Another NAT already exists ('$($nats[0].Name)', $($nats[0].InternalIPInterfaceAddressPrefix)). Windows supports only one NAT network per host. Remove it (Remove-NetNat -Name '$($nats[0].Name)') or reuse it with a matching -Subnet / -Prefix."
        }
        Write-Step "Creating NAT '$NatName' for $cidr"
        New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $cidr | Out-Null
    }
    Write-Ok "Network ready: $cidr via $GatewayIp (switch '$SwitchName')"
}

function Remove-LabNetwork {
    if (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue) {
        Write-Step "Removing NAT '$NatName'"
        Remove-NetNat -Name $NatName -Confirm:$false
    }
    if (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) {
        Write-Step "Removing switch '$SwitchName'"
        Remove-VMSwitch -Name $SwitchName -Force
    }
}

function Get-QemuImg {
    $cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $p = "$env:ProgramFiles\qemu\qemu-img.exe"
    if (Test-Path $p) { return $p }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Step 'Installing QEMU (only needed for qemu-img) via winget'
        winget install --id SoftwareFreedomConservancy.QEMU -e --accept-package-agreements --accept-source-agreements | Out-Host
        if (Test-Path $p) { return $p }
    }
    throw 'qemu-img not found. Install QEMU for Windows (https://qemu.weilnetz.de/w64/) and re-run.'
}

function Initialize-SshKey {
    if (Test-Path $KeyPath) { return }
    Write-Step 'Generating lab SSH key'
    New-Item -ItemType Directory -Force $LabPath | Out-Null
    # Start-Process keeps the empty passphrase argument intact on PS 5.1 and 7
    Start-Process -FilePath 'ssh-keygen' -Wait -NoNewWindow `
        -ArgumentList ('-t ed25519 -q -C ansible-lab -f "{0}" -N ""' -f $KeyPath)
    if (-not (Test-Path $KeyPath)) { throw 'ssh-keygen failed.' }
}

# qemu-img on Windows writes the VHDX as an NTFS *sparse* file. Hyper-V refuses to
# resize or attach VHDX files that are sparse, compressed or encrypted
# (error 0xC03A001A), so normalise the file before using it.
function Repair-VhdxFile([string]$Path) {
    $ErrorActionPreference = 'Continue'
    $sparse = [IO.FileAttributes]::SparseFile
    $comp   = [IO.FileAttributes]::Compressed
    $enc    = [IO.FileAttributes]::Encrypted

    $attr = (Get-Item -LiteralPath $Path).Attributes
    if (($attr -band $sparse) -ne 0) { & fsutil sparse setflag $Path 0 | Out-Null }
    if (($attr -band $comp)   -ne 0) { & compact /u $Path | Out-Null }
    if (($attr -band $enc)    -ne 0) { & cipher /d $Path | Out-Null }

    $attr = (Get-Item -LiteralPath $Path).Attributes
    if ((($attr -band $sparse) -ne 0) -or (($attr -band $comp) -ne 0)) {
        # Fallback: stream the file into a brand-new (fully allocated) file.
        Write-Warn2 'Could not clear the sparse/compressed flag - rewriting the disk as a normal file'
        $copy = "$Path.copy.vhdx"
        Remove-Item -LiteralPath $copy -Force -ErrorAction SilentlyContinue
        $in  = [IO.File]::OpenRead($Path)
        try {
            $out = [IO.File]::Create($copy)
            try { $in.CopyTo($out, 4MB) } finally { $out.Dispose() }
        } finally { $in.Dispose() }
        Remove-Item -LiteralPath $Path -Force
        Move-Item -LiteralPath $copy -Destination $Path
        $attr = (Get-Item -LiteralPath $Path).Attributes
    }
    if ((($attr -band $sparse) -ne 0) -or (($attr -band $comp) -ne 0) -or (($attr -band $enc) -ne 0)) {
        throw "'$Path' is still sparse/compressed/encrypted. Move -LabPath to a plain NTFS folder (not compressed or encrypted) and retry."
    }
}

function Initialize-BaseDisk {
    if (Test-Path $BaseVhdx) { return }
    New-Item -ItemType Directory -Force $ImgDir | Out-Null
    $qcow = "$ImgDir\$ImageName"

    if (-not (Test-Path $qcow)) {
        Write-Step "Downloading $ImageName (one time)"
        & curl.exe -fL --progress-bar -o $qcow "$ImageBase/$ImageName"
        if ($LASTEXITCODE -ne 0) { Remove-Item $qcow -ErrorAction SilentlyContinue; throw 'Image download failed.' }
    }

    Write-Step 'Verifying SHA512 checksum'
    $sums = & curl.exe -fsSL "$ImageBase/SHA512SUMS"
    $line = $sums | Where-Object { $_ -match ([regex]::Escape($ImageName) + '$') } | Select-Object -First 1
    if (-not $line) { throw 'Could not find the image in SHA512SUMS.' }
    $expected = ($line -split '\s+')[0].ToLower()
    $actual   = (Get-FileHash $qcow -Algorithm SHA512).Hash.ToLower()
    if ($expected -ne $actual) {
        Remove-Item $qcow -Force
        throw 'Checksum mismatch - corrupted download removed. Re-run to retry.'
    }
    Write-Ok 'Checksum OK'

    Write-Step 'Converting qcow2 -> VHDX (one time)'
    $qemu = Get-QemuImg
    # NOTE: the temp file must keep a .vhdx extension - the Hyper-V disk cmdlets
    # (Get-VHD / Resize-VHD) key off the extension.
    $tmp  = "$ImgDir\debian-13-base.building.vhdx"
    Remove-Item $tmp -ErrorAction SilentlyContinue
    & $qemu convert -O vhdx -o subformat=dynamic -p $qcow $tmp
    if ($LASTEXITCODE -ne 0) { throw 'qemu-img convert failed.' }
    Repair-VhdxFile $tmp

    # Grow the virtual disk BEFORE creating differencing children.
    # cloud-init expands the partition and filesystem on first boot.
    if (($DiskGB * 1GB) -gt (Get-VHD $tmp).Size) { Resize-VHD -Path $tmp -SizeBytes ($DiskGB * 1GB) }
    Move-Item $tmp $BaseVhdx
    Set-ItemProperty $BaseVhdx -Name IsReadOnly -Value $true
    Write-Ok "Base disk ready: $BaseVhdx"
}

# --- cloud-init seed ISO built with the IMAPI2 COM API that ships with Windows
function Initialize-IsoWriter {
    if ('IsoWriter' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public class IsoWriter {
    public static void Write(string path, object stream, int blockSize, int totalBlocks) {
        IStream src = (IStream)stream;
        byte[] buf = new byte[blockSize];
        IntPtr p = Marshal.AllocHGlobal(4);
        try {
            using (FileStream o = File.Create(path)) {
                while (totalBlocks-- > 0) {
                    src.Read(buf, blockSize, p);
                    o.Write(buf, 0, Marshal.ReadInt32(p));
                }
            }
        } finally { Marshal.FreeHGlobal(p); }
    }
}
'@
}

function New-SeedIso([string]$Dir, [string]$UserData, [string]$MetaData, [string]$NetworkConfig) {
    Initialize-IsoWriter
    $stage = "$Dir\seed"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $stage | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)   # no BOM, LF endings
    [IO.File]::WriteAllText("$stage\user-data",      $UserData,      $utf8)
    [IO.File]::WriteAllText("$stage\meta-data",      $MetaData,      $utf8)
    [IO.File]::WriteAllText("$stage\network-config", $NetworkConfig, $utf8)

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.FileSystemsToCreate = 3          # ISO9660 + Joliet
    $fsi.VolumeName = 'cidata'            # cloud-init NoCloud looks for this label
    $fsi.Root.AddTree($stage, $false)
    $res = $fsi.CreateResultImage()
    $iso = "$Dir\seed.iso"
    [IsoWriter]::Write($iso, $res.ImageStream, $res.BlockSize, $res.TotalBlocks)
    Remove-Item $stage -Recurse -Force
    return $iso
}

function New-UserData([string]$HostName, [bool]$IsControl, [string]$PubKey) {
    $l = @(
        '#cloud-config',
        "hostname: $HostName",
        'users:',
        "  - name: $LabUser",
        '    gecos: Ansible lab user',
        '    groups: [sudo]',
        '    sudo: ALL=(ALL) NOPASSWD:ALL',
        '    shell: /bin/bash',
        '    lock_passwd: true',
        '    ssh_authorized_keys:',
        "      - $PubKey",
        'package_update: true',
        'packages:',
        '  - hyperv-daemons'
    )
    if ($IsControl) { $l += '  - ansible' }
    $l += 'runcmd:'
    $l += '  - systemctl enable --now hv-kvp-daemon.service || true'
    return (($l -join "`n") + "`n")
}

# cloud-init network-config v2: static address, matched by the VM's static MAC
function New-NetworkConfig([string]$Ip, [string]$Mac) {
    $macColon = (($Mac.ToLower() -replace '(..)(?=.)', '$1:'))
    $l = @(
        'version: 2',
        'ethernets:',
        '  lan0:',
        '    match:',
        "      macaddress: `"$macColon`"",
        '    set-name: eth0',
        '    dhcp4: false',
        '    dhcp6: false',
        '    addresses:',
        "      - $Ip/$NetPrefix",
        '    routes:',
        '      - to: default',
        "        via: $GatewayIp",
        '    nameservers:',
        '      addresses:'
    )
    foreach ($d in $Dns) { $l += "        - $d" }
    return (($l -join "`n") + "`n")
}

function New-LabVm([string]$Name, [bool]$IsControl) {
    if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
        $sn = (Get-VMNetworkAdapter -VMName $Name | Select-Object -First 1).SwitchName
        if ($sn -ne $SwitchName) {
            Write-Warn2 "$Name exists but is on switch '$sn' (expected '$SwitchName'). Run '.\lab.ps1 destroy' and then 'up' to rebuild it with a fixed IP."
        } else {
            Write-Warn2 "$Name already exists - keeping it"
        }
        return
    }
    Write-Step "Creating $Name ($(Get-LabIp $Name))"
    $dir = "$VmDir\$Name"
    New-Item -ItemType Directory -Force $dir | Out-Null

    $ip   = Get-LabIp  $Name
    $mac  = Get-LabMac $Name
    $pub  = (Get-Content "$KeyPath.pub" -Raw).Trim()
    $ud   = New-UserData -HostName $Name -IsControl $IsControl -PubKey $pub
    $md   = "instance-id: $Name-$([guid]::NewGuid().ToString('N').Substring(0,8))`nlocal-hostname: $Name`n"
    $nc   = New-NetworkConfig -Ip $ip -Mac $mac
    $iso  = New-SeedIso -Dir $dir -UserData $ud -MetaData $md -NetworkConfig $nc

    $disk = "$dir\disk.vhdx"
    New-VHD -Path $disk -ParentPath $BaseVhdx -Differencing | Out-Null

    New-VM -Name $Name -Generation 2 -MemoryStartupBytes ($MemoryMB * 1MB) `
           -VHDPath $disk -SwitchName $SwitchName -Path $VmDir | Out-Null
    Set-VM -Name $Name -ProcessorCount $Cpus -AutomaticStopAction ShutDown
    Set-VMNetworkAdapter -VMName $Name -StaticMacAddress $mac
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off
    Add-VMDvdDrive -VMName $Name -Path $iso
    Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name)
}

# The same IP can come back with a new host key after destroy/up of a single VM.
# Drop any stale host key for that IP before connecting.
function Clear-KnownHost([string]$Ip) {
    $ErrorActionPreference = 'Continue'
    if (Test-Path $KnownHost) { & ssh-keygen -R $Ip -f $KnownHost *>$null }
}

function Wait-Ssh([string]$Ip, [int]$TimeoutSec = 300) {
    $ErrorActionPreference = 'Continue'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
        & ssh @BatchOpts "$LabUser@$Ip" 'true' 2>$null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for SSH on $Ip."
}

function Invoke-Remote([string]$Ip, [string]$Cmd) {
    $ErrorActionPreference = 'Continue'
    & ssh @BatchOpts "$LabUser@$Ip" $Cmd
    return $LASTEXITCODE
}

function Copy-ToRemote([string]$Ip, [string]$Local, [string]$Remote) {
    $ErrorActionPreference = 'Continue'
    & scp @BatchOpts $Local "${LabUser}@${Ip}:$Remote" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "scp of $Local failed." }
}

function Set-ControlNode([string]$ControlIp, [hashtable]$WorkerIps, [string]$ControlName) {
    Write-Step 'Configuring the control node (waiting for cloud-init to install Ansible)'
    [void](Invoke-Remote $ControlIp 'cloud-init status --wait >/dev/null 2>&1')
    if ((Invoke-Remote $ControlIp 'command -v ansible >/dev/null') -ne 0) {
        Write-Warn2 'Ansible is not installed on control yet (apt may have failed). Check: sudo cloud-init status --long'
    }

    $inv = @("[control]", "$ControlName ansible_connection=local", "", "[nodes]")
    foreach ($n in ($WorkerIps.Keys | Sort-Object)) { $inv += "$n ansible_host=$($WorkerIps[$n])" }
    $inv += @("", "[all:vars]",
              "ansible_user=$LabUser",
              "ansible_ssh_private_key_file=~/.ssh/id_ed25519",
              "ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'",
              "ansible_python_interpreter=/usr/bin/python3")

    $cfg = @('[defaults]', 'inventory = ./inventory.ini', 'host_key_checking = False', 'interpreter_python = auto_silent')

    $play = @(
        '---',
        '- name: Smoke test for the lab',
        '  hosts: nodes',
        '  become: true',
        '  tasks:',
        '    - name: Install htop',
        '      ansible.builtin.apt:',
        '        name: htop',
        '        state: present',
        '        update_cache: true',
        '    - name: Say hello',
        '      ansible.builtin.debug:',
        '        msg: "Hello from {{ inventory_hostname }} ({{ ansible_distribution }} {{ ansible_distribution_version }})"'
    )

    $tmp = "$LabPath\push"
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText("$tmp\inventory.ini", (($inv  -join "`n") + "`n"), $utf8)
    [IO.File]::WriteAllText("$tmp\ansible.cfg",   (($cfg  -join "`n") + "`n"), $utf8)
    [IO.File]::WriteAllText("$tmp\site.yml",      (($play -join "`n") + "`n"), $utf8)

    [void](Invoke-Remote $ControlIp 'mkdir -p ~/lab ~/.ssh')
    Copy-ToRemote $ControlIp $KeyPath           '.ssh/id_ed25519'
    Copy-ToRemote $ControlIp "$tmp\inventory.ini" 'lab/inventory.ini'
    Copy-ToRemote $ControlIp "$tmp\ansible.cfg"   'lab/ansible.cfg'
    Copy-ToRemote $ControlIp "$tmp\site.yml"      'lab/site.yml'
    [void](Invoke-Remote $ControlIp 'chmod 600 ~/.ssh/id_ed25519')
    Remove-Item $tmp -Recurse -Force
}

function Get-LabVms { @(Get-VM -Name "$Prefix-*" -ErrorAction SilentlyContinue) }

# ------------------------------------------------------------------ actions
function Invoke-Up {
    Test-Prerequisites
    Initialize-SshKey
    Initialize-BaseDisk
    Initialize-LabNetwork

    $control = "$Prefix-control"
    $workers = 1..$Workers | ForEach-Object { "$Prefix-node$_" }

    New-LabVm -Name $control -IsControl $true
    foreach ($w in $workers) { New-LabVm -Name $w -IsControl $false }

    Write-Step 'Starting VMs'
    foreach ($n in @($control) + $workers) {
        if ((Get-VM -Name $n).State -ne 'Running') { Start-VM -Name $n }
    }

    Write-Step 'Waiting for SSH on the fixed IPs (first boot takes 1-3 minutes)'
    $ips = @{}
    foreach ($n in @($control) + $workers) {
        $ips[$n] = Get-LabIp $n
        Clear-KnownHost $ips[$n]
        Wait-Ssh $ips[$n]
        Write-Ok "$n  $($ips[$n])"
    }

    $workerIps = @{}
    foreach ($w in $workers) { $workerIps[$w] = $ips[$w] }
    Set-ControlNode -ControlIp $ips[$control] -WorkerIps $workerIps -ControlName $control

    Write-Host ''
    Write-Host 'Lab is ready.' -ForegroundColor Green
    Write-Host "  Connect:   .\lab.ps1 ssh control      (or: ssh -i `"$KeyPath`" $LabUser@$($ips[$control]))"
    Write-Host "  Then run:  cd ~/lab && ansible all -m ping"
    Write-Host "             ansible-playbook site.yml"
    Write-Host "  Tear down: .\lab.ps1 destroy"
}

function Invoke-Status {
    $vms = Get-LabVms
    if (-not $vms) { Write-Host 'No lab VMs found. Run: .\lab.ps1 up'; return }
    $vms | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            State    = $_.State
            IP       = Get-LabIp $_.Name
            CPUs     = $_.ProcessorCount
            MemoryMB = [int]($_.MemoryStartup / 1MB)
        }
    } | Format-Table -AutoSize
}

function Invoke-SshAction {
    $name = $Target
    if ($name -notlike "$Prefix-*") { $name = "$Prefix-$name" }
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if (-not $vm) { throw "VM '$name' not found. Try: .\lab.ps1 status" }
    if ($vm.State -ne 'Running') { throw "$name is not running. Try: .\lab.ps1 start" }
    $ip = Get-LabIp $name
    Clear-KnownHost $ip
    & ssh @BaseOpts "$LabUser@$ip"
}

function Invoke-Destroy {
    $vms = Get-LabVms
    $haveNet = [bool](Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) -or
               [bool](Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)
    if (-not $vms -and -not $haveNet -and -not $Purge) { Write-Host 'Nothing to destroy.'; return }

    if (-not $Force) {
        $what = if ($Purge) { "ALL lab VMs, the lab switch/NAT and everything in $LabPath (keys + cached image)" } else { 'all lab VMs, their disks and the lab switch/NAT' }
        $ans = Read-Host "This will delete $what. Continue? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }

    foreach ($vm in $vms) {
        Write-Step "Removing $($vm.Name)"
        if ($vm.State -ne 'Off') { Stop-VM -Name $vm.Name -TurnOff -Force }
        Remove-VM -Name $vm.Name -Force
        Remove-Item "$VmDir\$($vm.Name)" -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-LabNetwork
    Remove-Item $KnownHost -Force -ErrorAction SilentlyContinue

    if ($Purge -and (Test-Path $LabPath)) {
        Write-Step "Purging $LabPath"
        if (Test-Path $BaseVhdx) { Set-ItemProperty $BaseVhdx -Name IsReadOnly -Value $false }
        Remove-Item $LabPath -Recurse -Force
    }
    Write-Ok 'Done.'
}

function Invoke-Start {
    Initialize-LabNetwork      # switch/NAT are recreated if the host lost them (e.g. after a reboot)
    Get-LabVms | Where-Object State -ne 'Running' | Start-VM
    Write-Ok 'Started.'
}

# --------------------------------------------------------------------- main
switch ($Action) {
    'up'      { Invoke-Up }
    'status'  { Invoke-Status }
    'ssh'     { Invoke-SshAction }
    'stop'    { Get-LabVms | Where-Object State -eq 'Running' | Stop-VM; Write-Ok 'Stopped.' }
    'start'   { Invoke-Start }
    'destroy' { Invoke-Destroy }
    default   { Show-Usage }
}
