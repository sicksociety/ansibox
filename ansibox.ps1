#Requires -Version 5.1
# NOTE: there is deliberately no "#Requires -RunAsAdministrator" here. It would demand
# elevation for EVERY command (even 'ssh') and reject the script with a raw, hard-to-read
# error. Instead each command asks only for the rights it really needs - see the main
# section at the bottom, Assert-Administrator and Assert-HyperVAccess.
<#
.SYNOPSIS
    One-command Ansible home lab on Hyper-V.

.DESCRIPTION
    Builds a control node (Ansible preinstalled) plus worker nodes from an official
    cloud image. Two operating systems are supported:

        debian   Debian 13 "Trixie"  (official "genericcloud" image)
        rhel     AlmaLinux 9         (official "GenericCloud" image) - the Red Hat family:
                 free, no subscription or license, binary-compatible with RHEL.

    The OS is asked ONCE, the first time a lab is created (or pass --distro to skip the
    question). It is remembered for that lab until you run 'delete'.

    Every VM is a differencing disk on one shared base image per OS, so extra nodes cost
    almost no disk space.

    Simple verbs (start, stop, status, ssh, delete) and GNU-style flags.
    Both "--nodes 3" and "--nodes=3" work. Run "help" for the full manual and
    "help <command>" for the details of one command.

    Prerequisites are checked up front, with clear "how to fix" steps instead of
    stack traces: Administrator rights, Hyper-V enabled, the hypervisor running,
    the Hyper-V management service (vmms) running, and the required tools.

    Networking: the script creates its own internal Hyper-V switch + NAT and
    gives every VM a FIXED IP (static, via cloud-init network-config):

        172.16.10.1   host / gateway (vEthernet adapter on the host)
        172.16.10.2   lab-control
        172.16.10.3   lab-node1
        172.16.10.4   lab-node2   ...and so on

.EXAMPLE
    .\ansibox.ps1 start                          # asks for the OS, then 3 nodes: control + 2 workers
    .\ansibox.ps1 start --distro rhel            # AlmaLinux 9, no question
    .\ansibox.ps1 start --distro debian --nodes 4 --memory 2g
    .\ansibox.ps1 start --subnet 10.77.5.0/24    # use another /24
    .\ansibox.ps1 start --memory-mode dynamic    # skip the memory question
    .\ansibox.ps1 status
    .\ansibox.ps1 ssh -n node1
    .\ansibox.ps1 stop
    .\ansibox.ps1 delete --purge
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Print errors as one short line ("X message") instead of a PowerShell stack trace.
trap { Write-Host "X $($_.Exception.Message)" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------ command line
# PowerShell's param() can't bind GNU-style "--flag value", so $args is parsed by hand.
# Accepted forms:  --nodes 3   --nodes=3   -n 3     (switches: --purge, --force / -f)
function Get-Flag([string]$Name, $Default) {
    if ($Flags.ContainsKey($Name)) { return $Flags[$Name] }
    return $Default
}

function ConvertTo-Int([string]$Text, [string]$Flag) {
    $n = 0
    if (-not [int]::TryParse($Text, [ref]$n)) { throw "--$Flag expects a number, got '$Text'." }
    return $n
}

# Size format: <number>[b|k|m|g], optional trailing "b". A bare number is MB.
#   2048 = 2048mb = 2g = 2gb
# Gotcha: PowerShell itself turns an unquoted "2gb" / "512mb" into a plain byte count
# (2147483648 / 536870912) before the script sees it. No valid size in MB has 7+ digits,
# so a bare number that long is treated as bytes.
function ConvertTo-MB([string]$Text, [string]$Flag) {
    if ($Text -match '^\d{7,}$') { return [int][math]::Ceiling([double]$Text / 1MB) }
    if (-not ($Text -match '^(\d+(?:\.\d+)?)([bkmg]?)b?$')) {
        throw "--$Flag '$Text' is not a size. Use e.g. 2048, 2048mb or 2g."
    }
    $n  = [double]$Matches[1]
    $mb = switch ($Matches[2].ToLower()) {
        'b'     { $n / 1MB }
        'k'     { $n / 1KB }
        'g'     { $n * 1024 }
        default { $n }
    }
    return [int][math]::Ceiling($mb)
}

function Assert-Range([string]$Flag, [int]$Value, [int]$Min, [int]$Max, [string]$Unit = '') {
    if ($Value -lt $Min -or $Value -gt $Max) {
        throw ("--$Flag must be between $Min and $Max {0}(got $Value)." -f $(if ($Unit) { "$Unit " } else { '' }))
    }
}

# ------------------------------------------------------- supported operating systems
# One entry per OS family. Everything that differs between Debian and Red Hat style
# systems lives here, so the rest of the script stays distro-neutral:
#   image + checksum location, admin group, cloud-init packages, the Hyper-V guest
#   service, extra control-node setup, the default-route spelling and the package task
#   of the smoke-test playbook.
#
# 'rhel' = AlmaLinux 9: a free, 1:1 rebuild of RHEL (no subscription, no license), shipped
# as an official minimal cloud image with cloud-init. ansible-core comes straight from the
# AppStream repo, so no EPEL is needed. To use AlmaLinux 10 instead, change ImageBase and
# BaseId (note: the plain AlmaLinux 10 x86_64 image needs a CPU with x86-64-v3).
$DefaultDistro = 'debian'
$Distros = [ordered]@{
    debian = @{
        Name            = 'Debian 13 "Trixie"'
        Short           = 'Debian 13'
        Label           = 'Debian 13 "Trixie"'
        Aliases         = @('debian', 'deb', 'd')
        Detail          = @(
            'Debian family  |  apt  |  official "genericcloud" image (small download)',
            'Light and quick to boot - a great default for Ansible practice.'
        )
        BaseId          = 'debian-13'
        ImageBase       = 'https://cloud.debian.org/images/cloud/trixie/latest'
        ImageName       = 'debian-13-genericcloud-amd64.qcow2'
        SumsFile        = 'SHA512SUMS'
        Algo            = 'SHA512'
        AdminGroup      = 'sudo'
        DefaultRoute    = 'default'
        MinMemoryMB     = 512
        Packages        = @('hyperv-daemons')
        ControlPackages = @('ansible')
        RunCmd          = @('systemctl enable --now hv-kvp-daemon.service || true')
        # The Debian 'ansible' package already bundles ansible.posix, community.general, ...
        ControlRunCmd   = @()
        SmokeTask       = @(
            '    - name: Install htop',
            '      ansible.builtin.apt:',
            '        name: htop',
            '        state: present',
            '        update_cache: true'
        )
    }
    rhel = @{
        Name            = 'AlmaLinux 9 (Red Hat family)'
        Short           = 'AlmaLinux 9'
        Label           = 'AlmaLinux 9  (Red Hat family, RHEL-compatible)'
        Aliases         = @('rhel', 'redhat', 'red-hat', 'almalinux', 'alma', 'el', 'r')
        Detail          = @(
            'Red Hat family  |  dnf  |  official "GenericCloud" image (~560 MB download)',
            'Free: no subscription, no license - binary-compatible with RHEL.',
            'Same tooling as RHEL / Rocky / CentOS Stream: dnf, SELinux, systemd.'
        )
        BaseId          = 'almalinux-9'
        ImageBase       = 'https://repo.almalinux.org/almalinux/9/cloud/x86_64/images'
        ImageName       = 'AlmaLinux-9-GenericCloud-latest.x86_64.qcow2'
        SumsFile        = 'CHECKSUM'
        Algo            = 'SHA256'
        AdminGroup      = 'wheel'
        DefaultRoute    = '0.0.0.0/0'
        MinMemoryMB     = 1024
        Packages        = @()
        ControlPackages = @('ansible-core')
        # hyperv-daemons is installed here (not in 'packages:') so that a missing package
        # can never make cloud-init skip ansible-core.
        RunCmd          = @(
            'dnf -y install hyperv-daemons || true',
            'systemctl enable --now hypervkvpd.service || true'
        )
        # ansible-core ships only ansible.builtin. Debian's full 'ansible' package also bundles
        # ansible.posix (firewalld, selinux, seboolean, authorized_key, sysctl, mount) and
        # community.general, so install them here to make both labs behave the same.
        # System-wide path (on ansible-core's default collections path) = works for every user.
        # '|| true': a missing internet connection must not fail cloud-init; the collections
        # can be installed later by hand with: ansible-galaxy collection install ansible.posix
        ControlRunCmd   = @(
            'ansible-galaxy collection install -p /usr/share/ansible/collections ansible.posix community.general || true'
        )
        SmokeTask       = @(
            '    - name: Install tmux',
            '      ansible.builtin.dnf:',
            '        name: tmux',
            '        state: present',
            '        update_cache: true'
        )
    }
}

# Accepts the key or any alias (--distro rhel | redhat | almalinux | alma | debian ...)
function ConvertTo-DistroKey([string]$Text) {
    $t = $Text.Trim().ToLower()
    foreach ($k in $Distros.Keys) {
        if ($t -eq $k -or ($Distros[$k].Aliases -contains $t)) { return $k }
    }
    throw "--distro must be 'debian' or 'rhel' (also accepted: almalinux, alma, redhat). Got '$Text'."
}

$ValueFlags  = 'nodes', 'node', 'memory', 'memory-mode', 'cpus', 'disk-size', 'subnet', 'dns', 'profile', 'distro'
$SwitchFlags = 'force', 'purge', 'help'
# Short flags. -n is --nodes for 'start' but --node for 'ssh'.
$ShortFlags  = @{ p = 'profile'; f = 'force'; h = 'help'; n = 'nodes' }

$tokens  = @($args | ForEach-Object { "$_" })
$Command = 'help'
if ($tokens.Count -gt 0 -and $tokens[0] -notlike '-*') {
    $Command = $tokens[0].ToLower()
    $tokens  = @($tokens | Select-Object -Skip 1)
}
$CommandAliases = @{ up = 'start'; destroy = 'delete' }     # old names still work
if ($CommandAliases.ContainsKey($Command)) { $Command = $CommandAliases[$Command] }
if ($Command -eq 'ssh') { $ShortFlags['n'] = 'node' }

$Flags = @{}
$Rest  = @()
for ($i = 0; $i -lt $tokens.Count; $i++) {
    $t = $tokens[$i]
    if ($t -notmatch '^(--?)([A-Za-z][\w-]*)(?:=(.*))?$') { $Rest += $t; continue }

    $dashes = $Matches[1]; $name = $Matches[2]
    $val    = if ($Matches.ContainsKey(3)) { $Matches[3] } else { $null }

    if ($dashes -eq '--') { $long = $name }
    elseif ($ShortFlags.ContainsKey($name)) { $long = $ShortFlags[$name] }
    else { throw "Unknown flag '$t'. Try: .\ansibox.ps1 help" }

    if ($SwitchFlags -contains $long) { $Flags[$long] = $true }
    elseif ($ValueFlags -contains $long) {
        if ($null -eq $val) {
            if ($i + 1 -ge $tokens.Count) { throw "Flag --$long needs a value." }
            $i++
            $val = $tokens[$i]
        }
        $Flags[$long] = $val
    }
    else { throw "Unknown flag '$t'. Try: .\ansibox.ps1 help" }
}

# ---- flags -> the variables the rest of the script uses
$Nodes    = ConvertTo-Int (Get-Flag 'nodes' 3) 'nodes'          # total, control included
$Cpus     = ConvertTo-Int (Get-Flag 'cpus' 2) 'cpus'
$MemoryMB = ConvertTo-MB  (Get-Flag 'memory' 1024) 'memory'
$DiskGB   = [int][math]::Ceiling((ConvertTo-MB (Get-Flag 'disk-size' '10g') 'disk-size') / 1024)
Assert-Range 'nodes'     $Nodes    2   11
Assert-Range 'cpus'      $Cpus     1   8
Assert-Range 'memory'    $MemoryMB 512 16384 'MB'
Assert-Range 'disk-size' $DiskGB   4   200   'GB'
$Workers = $Nodes - 1

# OS requested on the command line (or $null = ask the first time the lab is created)
$DistroFlag = Get-Flag 'distro' $null
if ($null -ne $DistroFlag) { $DistroFlag = ConvertTo-DistroKey ([string]$DistroFlag) }

# Memory mode for the VMs this run creates. The script default is stored first in
# $DefaultMemoryMode; --memory-mode (or the question asked when VMs are created) overrides it
# for this run only. Nothing is saved, so the next run starts from the default again.
$DefaultMemoryMode = 'static'
$MemoryMode        = $DefaultMemoryMode
$memoryModeFlag    = Get-Flag 'memory-mode' $null
if ($null -ne $memoryModeFlag) {
    $memoryModeFlag = ([string]$memoryModeFlag).ToLower()
    if (@('static', 'dynamic') -notcontains $memoryModeFlag) {
        throw "--memory-mode must be 'static' or 'dynamic' (got '$memoryModeFlag')."
    }
    $MemoryMode = $memoryModeFlag
}
# Dynamic mode: starts at --memory, may shrink to 512 MB and grow to twice --memory (max 16 GB).
$DynMinMB = 512
$DynMaxMB = [math]::Min(16384, $MemoryMB * 2)

# --profile = the lab's name; it prefixes every VM (lab-control, lab-node1, ...)
$Prefix = [string](Get-Flag 'profile' 'lab')
if ($Prefix -notmatch '^[A-Za-z0-9]+$') { throw '--profile may only contain letters and digits.' }

# First three octets of the lab /24. .1 = host gateway, .2 = control, .3+ = nodes
$subnetText = [string](Get-Flag 'subnet' '172.16.10')
if ($subnetText -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})(?:\.0/24)?$') { $Subnet = $Matches[1] }
else { throw "--subnet must be a /24 such as 10.77.5.0/24 (got '$subnetText')." }

# DNS servers handed to the VMs (the internal switch has no DHCP/DNS of its own)
[string[]]$Dns = @((Get-Flag 'dns' '1.1.1.1,8.8.8.8') -split '[,\s]+' | Where-Object { $_ })

# Set the LAB_HOME environment variable to keep the lab data somewhere else
$LabPath = if ($env:LAB_HOME) { $env:LAB_HOME } else { Join-Path $env:USERPROFILE 'ansible-lab' }

$Force  = $Flags.ContainsKey('force')
$Purge  = $Flags.ContainsKey('purge')
# For 'ssh': which node to connect to (control, node1, node2, ...)
$Target = if ($Flags.ContainsKey('node')) { $Flags['node'] } elseif ($Rest.Count -gt 0) { $Rest[0] } else { 'control' }

# ---------------------------------------------------------------- constants
$ImgDir     = "$LabPath\images"
$VmDir      = "$LabPath\vms"
$KeyPath    = "$LabPath\lab_key"
$KnownHost  = "$LabPath\known_hosts"
$DistroFile = "$LabPath\$Prefix.distro"     # remembers which OS this lab was built with
$LabUser    = 'ansible'

# Filled in by Set-ActiveDistro once the OS of the lab is known (start only).
$DistroKey = $null
$Distro    = $null
$BaseVhdx  = $null

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

# ---- run timer: shown only by 'start' and 'delete' (the long-running commands)
# Started in the main section. Time spent waiting for the user to answer a question is
# NOT counted (Read-Answer pauses the timer), so the number reflects the work itself.
$CommandTimer = New-Object Diagnostics.Stopwatch

function Read-Answer([string]$Prompt) {
    $wasRunning = $CommandTimer.IsRunning
    $CommandTimer.Stop()
    try { return (Read-Host $Prompt) }
    finally { if ($wasRunning) { $CommandTimer.Start() } }
}

function Format-Elapsed([TimeSpan]$Span) {
    if ($Span.TotalHours   -ge 1) { return ('{0}h {1:00}m {2:00}s' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes, $Span.Seconds) }
    if ($Span.TotalMinutes -ge 1) { return ('{0}m {1:00}s' -f $Span.Minutes, $Span.Seconds) }
    return ('{0:0.0}s' -f $Span.TotalSeconds)
}

function Write-Elapsed {
    Write-Host ''
    Write-Host ("Total time: {0}" -f (Format-Elapsed $CommandTimer.Elapsed)) -ForegroundColor Cyan
}

# ------------------------------------------------------------------ help manual
#   .\ansibox.ps1 help             overview of everything
#   .\ansibox.ps1 help <command>   one command in detail   (also:  <command> --help)
function Write-HelpTitle([string]$Text) {
    Write-Host ''
    Write-Host $Text -ForegroundColor Yellow
}

# "  left-column   right text". Pass '' as $Left for a continuation line.
function Write-HelpRow([string]$Left, [string]$Right, [int]$Width = 24) {
    Write-Host '  ' -NoNewline
    Write-Host (($Left + '  ').PadRight($Width)) -NoNewline -ForegroundColor Cyan
    Write-Host $Right
}

function Write-HelpText([string[]]$Lines) {
    foreach ($line in $Lines) { Write-Host "  $line" }
}

function Write-HelpExample([string]$Cmd, [string]$Note = '') {
    Write-Host '  ' -NoNewline
    if ($Note) {
        Write-Host (('.\ansibox.ps1 ' + $Cmd + '  ').PadRight(52)) -NoNewline -ForegroundColor Green
        Write-Host "# $Note" -ForegroundColor DarkGray
    } else {
        Write-Host ('.\ansibox.ps1 ' + $Cmd) -ForegroundColor Green
    }
}

# Who needs what, shared by the overview and the per-command pages.
function Write-HelpRights {
    Write-HelpTitle 'ADMINISTRATOR RIGHTS  (asked only where they are really needed)'
    Write-HelpRow 'help, ssh' 'none' 30
    Write-HelpRow 'status, stop, start' "Administrator OR membership of the 'Hyper-V Administrators' group" 30
    Write-HelpRow '' 'start also needs Administrator if the lab network has to be recreated' 30
    Write-HelpRow 'start (new lab, --nodes)' 'Administrator: it creates the virtual switch, NAT and host IP address' 30
    Write-HelpRow 'delete' 'Administrator: it removes the virtual switch and NAT network' 30
    Write-HelpText @(
        '',
        'One-time setup so status / stop / start / ssh never need elevation',
        '(run in an elevated PowerShell, then sign out and back in):',
        '  Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-578) -Member $env:USERNAME'
    )
}

function Show-Usage {
    Write-Host ''
    Write-Host 'AnsiBox' -NoNewline -ForegroundColor Cyan
    Write-Host '  -  an Ansible lab on Hyper-V, in one command'

    Write-HelpTitle 'USAGE'
    Write-HelpText @(
        '.\ansibox.ps1 <command> [options]',
        '.\ansibox.ps1 help <command>        details, options and examples for one command'
    )

    Write-HelpTitle 'COMMANDS'
    Write-HelpRow 'start'  'Create the lab (a control node with Ansible + workers), or start it again if it exists'
    Write-HelpRow 'status' 'List the lab VMs: state, OS, IP address, CPUs, memory'
    Write-HelpRow 'ssh'    'Open an SSH session on a node (default: the control node)'
    Write-HelpRow 'stop'   'Shut the lab VMs down. Disks and data are kept'
    Write-HelpRow 'delete' 'Remove the lab VMs, their disks, the virtual switch and the NAT network'
    Write-HelpRow 'help'   'This page'

    Write-HelpTitle 'OPTIONS  (the ones for start are listed in: help start)'
    Write-HelpRow '-p, --profile <name>' 'Lab name and VM prefix (default: lab)'
    Write-HelpRow '-h, --help' 'Help for a command, for example:  .\ansibox.ps1 start --help'
    Write-HelpRow '--flag value' 'Both "--nodes 3" and "--nodes=3" work'

    Write-HelpTitle 'QUICK START'
    Write-HelpText @(
        '1. In an Administrator PowerShell, create the lab (the OS image downloads once):',
        '       .\ansibox.ps1 start',
        '2. Connect to the control node:',
        '       .\ansibox.ps1 ssh',
        '3. On the control node, check the nodes and run the sample playbook:',
        '       cd ~/lab && ansible all -m ping',
        '       ansible-playbook site.yml',
        '4. Pause for the day, resume later, or throw the lab away:',
        '       .\ansibox.ps1 stop        .\ansibox.ps1 start        .\ansibox.ps1 delete'
    )

    Write-HelpTitle 'EXAMPLES'
    Write-HelpExample 'start'                                   'asks for the OS, then control + 2 workers'
    Write-HelpExample 'start --distro rhel'                      'AlmaLinux 9 (Red Hat family), no question'
    Write-HelpExample 'start --distro debian --nodes 4 --memory 2g' 'control + 3 workers, 2 GB each'
    Write-HelpExample 'ssh node1'                                'same as: ssh -n node1'
    Write-HelpExample 'status'
    Write-HelpExample 'delete --purge'                          'also removes the key and the cached images'

    Write-HelpTitle 'NETWORK  (fixed IP addresses, the same on every run)'
    Write-HelpRow "$Subnet.1" 'your PC, the gateway of the lab network' 16
    Write-HelpRow "$Subnet.2" "$Prefix-control  (Ansible is installed here, your files are in ~/lab)" 16
    Write-HelpRow "$Subnet.3" "$Prefix-node1" 16
    Write-HelpRow "$Subnet.4" "$Prefix-node2, and so on" 16

    Write-HelpRights

    Write-HelpTitle 'GOOD TO KNOW'
    Write-HelpText @(
        '- A lab uses one operating system (debian or rhel) until you delete it.',
        '- Only one lab network can exist at a time: Windows allows a single NAT network.',
        '- The OS image is downloaded once and cached, even after delete (delete --purge removes it).',
        '- Your files in ~/lab on the control node are never overwritten by a later start.',
        '- start and delete print the total time they took.'
    )

    Write-HelpTitle 'FILES'
    Write-HelpRow 'Lab data' "$LabPath   (set the LAB_HOME environment variable to move it)" 12
    Write-HelpRow 'On control' '~/lab/inventory.ini, ansible.cfg, site.yml' 12
    Write-Host ''
}

function Show-CommandHelp([string]$Name) {
    switch ($Name) {
        'start' {
            Write-HelpTitle 'START'
            Write-HelpText @(
                'Creates the lab the first time. If the lab already exists it powers the VMs on again',
                'and, if Windows lost it (for example after a reboot), recreates the host network.',
                'Prints the total time when it is done.'
            )
            Write-HelpTitle 'USAGE'
            Write-HelpText '.\ansibox.ps1 start [options]'
            Write-HelpTitle 'OPTIONS'
            Write-HelpRow '--nodes <n>' 'Total nodes, control included: 2 to 11 (default 3 = control + 2 workers).' 22
            Write-HelpRow '' 'On an existing lab it adds the missing nodes. Nodes are never removed.' 22
            Write-HelpRow '--distro <os>' 'debian (Debian 13) or rhel (AlmaLinux 9, a free RHEL clone).' 22
            Write-HelpRow '' 'Asked once if omitted. A lab uses one OS until delete.' 22
            Write-HelpRow '--memory <size>' 'RAM per VM: 512 MB to 16 GB (default 1024). Sizes: 2048, 2048mb, 2g.' 22
            Write-HelpRow '' 'A bare number is MB.' 22
            Write-HelpRow '--memory-mode <m>' 'static (default): fixed RAM per VM.' 22
            Write-HelpRow '' 'dynamic: Hyper-V resizes it between 512 MB and twice --memory.' 22
            Write-HelpRow '' 'Asked when VMs are created if omitted. Never saved.' 22
            Write-HelpRow '--cpus <n>' 'Virtual CPUs per VM: 1 to 8 (default 2).' 22
            Write-HelpRow '--disk-size <size>' 'Disk per VM: 4 to 200 GB (default 10g). Applied when the OS base image' 22
            Write-HelpRow '' 'is first prepared; to change it later use: delete --purge.' 22
            Write-HelpRow '--subnet <cidr>' 'The lab /24 network (default 172.16.10.0/24).' 22
            Write-HelpRow '--dns <list>' 'DNS servers for the VMs, comma separated (default 1.1.1.1,8.8.8.8).' 22
            Write-HelpRow '-p, --profile <name>' 'Lab name and VM prefix (default: lab).' 22
            Write-HelpTitle 'NOTES'
            Write-HelpText @(
                '- Sizing options (--memory, --cpus, ...) apply to the VMs this run creates;',
                '  existing VMs keep their settings.',
                '- Files you edited in ~/lab on the control node are kept. If a generated file',
                '  differs from yours, the new version is saved next to it as <name>.new.',
                '- Creating a lab, or repairing the host network, needs Administrator.',
                '  Resuming a healthy lab needs Administrator or Hyper-V Administrators membership.'
            )
            Write-HelpTitle 'EXAMPLES'
            Write-HelpExample 'start'
            Write-HelpExample 'start --distro rhel'
            Write-HelpExample 'start --distro debian --nodes 4 --memory 2g'
            Write-HelpExample 'start --memory-mode dynamic'
            Write-HelpExample 'start --subnet 10.77.5.0/24'
            Write-HelpExample 'start --nodes 5' 'add nodes to an existing lab'
        }
        'status' {
            Write-HelpTitle 'STATUS'
            Write-HelpText @(
                'Lists the lab VMs with their state, operating system, IP address, CPUs and memory.',
                'The memory column is the startup memory.'
            )
            Write-HelpTitle 'USAGE'
            Write-HelpText '.\ansibox.ps1 status [-p <name>]'
            Write-HelpTitle 'NOTES'
            Write-HelpText '- Needs Administrator or membership of the Hyper-V Administrators group.'
            Write-HelpTitle 'EXAMPLES'
            Write-HelpExample 'status'
        }
        'ssh' {
            Write-HelpTitle 'SSH'
            Write-HelpText @(
                'Opens an SSH session on a node as the user "ansible", with the lab key.',
                'Without a node name it connects to the control node.'
            )
            Write-HelpTitle 'USAGE'
            Write-HelpText @(
                '.\ansibox.ps1 ssh [-n <node>]',
                '.\ansibox.ps1 ssh [<node>]'
            )
            Write-HelpTitle 'OPTIONS'
            Write-HelpRow '-n, --node <node>' 'control (default), node1, node2, ... or the full VM name.' 20
            Write-HelpTitle 'NOTES'
            Write-HelpText @(
                '- Needs no Administrator rights: the IP address of a node is fixed by its name.',
                '- If you also have Hyper-V access it first checks that the VM exists and is running.',
                '- Not connecting? Check the lab with: .\ansibox.ps1 status   (and start it with: start).'
            )
            Write-HelpTitle 'EXAMPLES'
            Write-HelpExample 'ssh'                'the control node'
            Write-HelpExample 'ssh -n node1'
            Write-HelpExample 'ssh node2'
        }
        'stop' {
            Write-HelpTitle 'STOP'
            Write-HelpText @(
                'Shuts down every running lab VM. Disks and data are kept;',
                '".\ansibox.ps1 start" brings the lab back.'
            )
            Write-HelpTitle 'USAGE'
            Write-HelpText '.\ansibox.ps1 stop [-p <name>]'
            Write-HelpTitle 'NOTES'
            Write-HelpText '- Needs Administrator or membership of the Hyper-V Administrators group.'
            Write-HelpTitle 'EXAMPLES'
            Write-HelpExample 'stop'
        }
        'delete' {
            Write-HelpTitle 'DELETE'
            Write-HelpText @(
                'Removes the lab: its VMs and disks, the virtual switch and the NAT network, and the',
                'remembered OS choice. The SSH key and the downloaded OS images are kept, so the next',
                'start is faster. Asks for confirmation. Prints the total time when it is done.'
            )
            Write-HelpTitle 'USAGE'
            Write-HelpText '.\ansibox.ps1 delete [--purge] [--force]'
            Write-HelpTitle 'OPTIONS'
            Write-HelpRow '--purge' 'Also delete everything in the lab data folder: the SSH key and the' 24
            Write-HelpRow '' 'cached OS images (the next start downloads the image again).' 24
            Write-HelpRow '-f, --force' 'Do not ask for confirmation.' 24
            Write-HelpRow '-p, --profile <name>' 'Lab name and VM prefix (default: lab).' 24
            Write-HelpTitle 'NOTES'
            Write-HelpText @(
                '- Needs Administrator: it removes the virtual switch and the NAT network.',
                "- Only VMs named $Prefix-control and $Prefix-node<N> are removed; other VMs are left alone."
            )
            Write-HelpTitle 'EXAMPLES'
            Write-HelpExample 'delete'
            Write-HelpExample 'delete --force'
            Write-HelpExample 'delete --purge --force'
        }
    }
    Write-Host ''
}

# 'help', 'help <command>' and '<command> --help' all end up here.
function Show-Help([string]$Topic) {
    if (-not $Topic -and $Rest.Count -gt 0) { $Topic = [string]$Rest[0] }
    if (-not $Topic) { Show-Usage; return }
    $name = $Topic.ToLower()
    if ($CommandAliases.ContainsKey($name)) { $name = $CommandAliases[$name] }
    if ($name -eq 'help') { Show-Usage; return }
    if (@('start', 'status', 'ssh', 'stop', 'delete') -notcontains $name) {
        throw "No help for '$Topic'. Commands: start, status, ssh, stop, delete. Try: .\ansibox.ps1 help"
    }
    Show-CommandHelp $name
}

# ------------------------------------------------------------ interactive menus
# Can we ask the user something? (not when input is redirected, e.g. CI / piped runs)
function Test-CanAsk {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

# One reusable, framed multiple-choice question. ASCII only on purpose: box-drawing
# characters get mangled by Windows PowerShell 5.1 when a script has no BOM.
#   $Options: array of @{ Value; Label; Aliases; Detail = @('line', ...) }
#   Enter alone returns $Default. Typing the number, the value or any alias also works.
#
#   +----------------------------------------------------------------+
#   |  Choose your lab operating system                              |
#   +----------------------------------------------------------------+
#   Asked once - the lab keeps this OS until you run "delete".
#
#    [1]  Debian 13 "Trixie"   (default)
#         Debian family  |  apt  |  ...
#
#    [2]  AlmaLinux 9  (Red Hat family, RHEL-compatible)
#         ...
#
#   > Choose 1 / 2  (Enter = Debian 13 "Trixie"):
function Read-Choice {
    param(
        [string]$Title,
        [string]$Subtitle,
        [hashtable[]]$Options,
        [string]$Default
    )

    $inner = [math]::Max(64, $Title.Length + 6)
    $bar   = '+' + ('-' * $inner) + '+'
    $head  = ("  $Title").PadRight($inner)
    Write-Host ''
    Write-Host "  $bar" -ForegroundColor Cyan
    Write-Host '  |' -NoNewline -ForegroundColor Cyan
    Write-Host $head -NoNewline -ForegroundColor Yellow
    Write-Host '|' -ForegroundColor Cyan
    Write-Host "  $bar" -ForegroundColor Cyan
    if ($Subtitle) { Write-Host "  $Subtitle" -ForegroundColor Gray }
    Write-Host ''

    $defaultLabel = ''
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $o = $Options[$i]
        $isDefault = ($o.Value -eq $Default)
        if ($isDefault) { $defaultLabel = $o.Label }

        Write-Host '   ' -NoNewline
        Write-Host ('[{0}]' -f ($i + 1)) -NoNewline -ForegroundColor Yellow
        Write-Host "  $($o.Label)" -NoNewline -ForegroundColor White
        if ($isDefault) { Write-Host '   (default)' -NoNewline -ForegroundColor Green }
        Write-Host ''
        foreach ($d in $o.Detail) { Write-Host "        $d" -ForegroundColor DarkGray }
        Write-Host ''
    }

    $numbers = (1..$Options.Count) -join ' / '
    while ($true) {
        $ans = ([string](Read-Answer "  > Choose $numbers  (Enter = $defaultLabel)")).Trim().ToLower()
        if ($ans -eq '') { return $Default }
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $o = $Options[$i]
            $accepted = @("$($i + 1)", ([string]$o.Value).ToLower()) + @($o.Aliases)
            if ($accepted -contains $ans) { return $o.Value }
        }
        Write-Warn2 "Please type $numbers, or just press Enter for the default."
    }
}

# Which OS should this (new) lab use? Built from the $Distros catalog.
function Read-DistroChoice {
    if (-not (Test-CanAsk)) { return $DefaultDistro }

    $opts = @()
    foreach ($k in $Distros.Keys) {
        $d = $Distros[$k]
        $opts += , @{ Value = $k; Label = $d.Label; Aliases = $d.Aliases; Detail = $d.Detail }
    }
    return (Read-Choice -Title 'Choose your lab operating system' `
                        -Subtitle 'Asked once - the lab keeps this OS until you run "delete".' `
                        -Options $opts -Default $DefaultDistro)
}

# Static vs dynamic memory for the VMs this run is about to create.
#   - --memory-mode on the command line wins: nothing is asked.
#   - Otherwise the user is asked; just pressing Enter keeps the script default.
#   - With nobody to ask (input redirected, CI) the default is used.
# The answer lives in $MemoryMode for this run only. It is never saved.
function Read-MemoryMode {
    if ($Flags.ContainsKey('memory-mode')) { return $MemoryMode }
    if (-not (Test-CanAsk)) { return $DefaultMemoryMode }

    $opts = @(
        @{ Value = 'static';  Label = 'Static';  Aliases = @('s', 'static')
           Detail = @("Fixed $MemoryMB MB of RAM per VM",
                      'Predictable: what you set is what every VM gets.') },
        @{ Value = 'dynamic'; Label = 'Dynamic'; Aliases = @('d', 'dynamic')
           Detail = @("Starts at $MemoryMB MB; Hyper-V resizes it between $DynMinMB and $DynMaxMB MB",
                      'Idle VMs give RAM back to the host.') }
    )
    return (Read-Choice -Title 'Memory mode for the new VMs' `
                        -Subtitle 'How should Hyper-V hand out RAM? (applies to this run only)' `
                        -Options $opts -Default $DefaultMemoryMode)
}

# ------------------------------------------------------ OS selection / persistence
function Get-SavedDistroKey {
    if (-not (Test-Path $DistroFile)) { return $null }
    $t = ([string](Get-Content $DistroFile -Raw -ErrorAction SilentlyContinue)).Trim().ToLower()
    if ($Distros.Contains($t)) { return $t }
    return $null
}

# The OS of an existing lab. Labs built before multi-OS support have no marker file: Debian.
function Get-LabDistroKey {
    $saved = Get-SavedDistroKey
    if ($saved) { return $saved }
    return 'debian'
}

function Save-DistroChoice {
    New-Item -ItemType Directory -Force $LabPath | Out-Null
    [IO.File]::WriteAllText($DistroFile, $DistroKey, (New-Object Text.UTF8Encoding($false)))
}

function Set-ActiveDistro([string]$Key) {
    $script:DistroKey = $Key
    $script:Distro    = $Distros[$Key]
    $script:BaseVhdx  = "$ImgDir\$($Distro.BaseId)-base.vhdx"
}

# Decide the OS for 'start':
#   - lab already has VMs  -> keep its OS (a lab never mixes distros); a conflicting --distro is an error
#   - brand-new lab        -> --distro if given, otherwise ask (default Debian when nobody can answer)
function Resolve-Distro {
    $existing = Get-LabVms
    if ($existing) {
        $current = Get-LabDistroKey
        if ($DistroFlag -and $DistroFlag -ne $current) {
            throw "This lab already runs $($Distros[$current].Name), and a lab uses a single OS. Run '.\ansibox.ps1 delete' first if you want $($Distros[$DistroFlag].Name)."
        }
        return $current
    }
    if ($DistroFlag) { return $DistroFlag }
    return (Read-DistroChoice)
}

# ------------------------------------------------------ prerequisite checks
# Every failed check goes through Stop-Prereq: a one-line problem plus numbered
# "How to fix" steps. The trap at the top prints it as a single red "X ..." message,
# never a PowerShell stack trace.
function Stop-Prereq([string]$Problem, [string[]]$Fix = @()) {
    $msg = $Problem
    if ($Fix.Count -gt 0) {
        $msg += "`n`n  How to fix:"
        $i = 1
        foreach ($f in $Fix) { $msg += "`n    $i. $f"; $i++ }
    }
    throw $msg
}

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Only called by the commands/steps that really need elevation; $Reason says why.
function Assert-Administrator([string]$Reason = 'it changes system-level settings') {
    if (-not (Test-IsAdministrator)) {
        Stop-Prereq "'$Command' needs Administrator rights: $Reason." @(
            'Close this window and open PowerShell as Administrator: right-click Start, then choose "Terminal (Admin)" or "Windows PowerShell (Admin)".',
            "Go back to this folder and re-run:  .\ansibox.ps1 $Command"
        )
    }
}

# Members of the local 'Hyper-V Administrators' group (well-known SID S-1-5-32-578, so it
# works on any Windows language) can list, start and stop VMs without elevation.
function Test-IsHyperVAdmin {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-578'))
    } catch { return $false }
}

function Test-HasHyperVAccess { return ((Test-IsAdministrator) -or (Test-IsHyperVAdmin)) }

# For commands that only manage existing VMs (status, stop, start/resume).
function Assert-HyperVAccess {
    if (Test-HasHyperVAccess) { return }
    Stop-Prereq "'$Command' needs permission to manage Hyper-V virtual machines." @(
        'Quick way: open PowerShell as Administrator and re-run this command.',
        'One-time fix, so status/stop/start/ssh never need Administrator again: in an elevated PowerShell run  Add-LocalGroupMember -Group (Get-LocalGroup -SID S-1-5-32-578) -Member $env:USERNAME  then sign out and back in.',
        "Re-run:  .\ansibox.ps1 $Command"
    )
}

# Explains WHY Hyper-V is unavailable: Windows Home, feature not enabled, or restart pending.
# Get-WindowsOptionalFeature -Online goes through DISM and can take 10-60 seconds, so this is
# only called AFTER a quick check has already failed - never on the healthy path.
# It throws (through Stop-Prereq) when it finds the cause, and returns quietly otherwise so the
# caller can report its own, more specific message.
function Assert-HyperVFeature {
    $enableFeature = 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All'

    $feature = $null
    try { $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop } catch { }

    if ($null -eq $feature) {
        # Could not query the feature. Windows Home is the one case we can name for sure.
        $edition = ''
        try { $edition = [string](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
        if ($edition -match 'Home') {
            Stop-Prereq "This PC runs '$edition', which does not include Hyper-V." @(
                'Upgrade to Windows 10/11 Pro, Enterprise or Education.',
                'Hyper-V cannot be enabled on Windows Home editions.'
            )
        }
        return
    }

    $state = [string]$feature.State
    if ($state -eq 'EnablePending') {
        Stop-Prereq 'Hyper-V was enabled but Windows has not finished installing it - a restart is pending.' @(
            'Restart the PC.',
            "Re-run:  .\ansibox.ps1 $Command"
        )
    }
    if ($state -ne 'Enabled') {
        Stop-Prereq 'Hyper-V is not enabled on this PC.' @(
            "Run in this elevated PowerShell:  $enableFeature",
            'Restart the PC when prompted.',
            'Make sure virtualization (Intel VT-x / AMD-V) is turned on in your BIOS/UEFI settings.',
            "Re-run:  .\ansibox.ps1 $Command"
        )
    }
}

# Is the hypervisor actually running, is the management service up, and can we talk to it?
# These checks are quick. Only when one of them fails do we run the slow feature query
# (Assert-HyperVFeature) to explain why. Each step stops with a specific, actionable message.
function Assert-HyperV {
    Write-Step 'Checking Hyper-V'
    $enableFeature = 'Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -All'

    # 1. The hypervisor itself must be running (needs a reboot after enabling the feature)
    $hypervisorPresent = $null
    try { $hypervisorPresent = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).HypervisorPresent } catch { }
    if ($hypervisorPresent -eq $false) {
        Assert-HyperVFeature    # not installed? restart pending? Windows Home? (slow, failure path only)
        Stop-Prereq 'Hyper-V is installed, but the hypervisor is not running.' @(
            'Restart the PC - Windows needs a reboot after Hyper-V is enabled.',
            'If it still fails after a restart, check the boot setting:  bcdedit /enum | findstr hypervisorlaunchtype  (it should say Auto). Fix with:  bcdedit /set hypervisorlaunchtype auto  and restart.',
            'Make sure virtualization (Intel VT-x / AMD-V) is enabled in your BIOS/UEFI settings.'
        )
    }

    # 2. The Hyper-V Virtual Machine Management service
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc) {
        Assert-HyperVFeature
        Stop-Prereq 'The Hyper-V Virtual Machine Management service (vmms) was not found.' @(
            "Run in this elevated PowerShell:  $enableFeature",
            'Restart the PC, then re-run this command.'
        )
    }
    if ($svc.Status -ne 'Running') {
        Assert-Administrator 'the Hyper-V Virtual Machine Management service (vmms) is stopped and starting a service is an admin task'
        Write-Warn2 'Hyper-V Virtual Machine Management service is stopped - starting it'
        try {
            Start-Service -Name vmms -ErrorAction Stop
            $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
        } catch {
            $startError = $_.Exception.Message
            Assert-HyperVFeature
            Stop-Prereq "Could not start the Hyper-V Virtual Machine Management service: $startError" @(
                'Try starting it yourself:  Start-Service vmms',
                'Inspect it with:  Get-Service vmms | Format-List *',
                'If you just enabled Hyper-V, restart the PC and try again.'
            )
        }
    }

    # 3. PowerShell module
    if (-not (Get-Command New-VM -ErrorAction SilentlyContinue)) {
        Assert-HyperVFeature
        Stop-Prereq 'The Hyper-V PowerShell module is not installed.' @(
            'Run in this elevated PowerShell:  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell',
            'Open a new elevated PowerShell window and re-run this command.'
        )
    }

    # 4. Can we actually talk to Hyper-V?
    try { $null = Get-VM -ErrorAction Stop }
    catch {
        $vmError = $_.Exception.Message
        Assert-HyperVFeature
        Stop-Prereq "Cannot talk to Hyper-V: $vmError" @(
            'Make sure this is an elevated (Administrator) PowerShell window, or that your account is in the Hyper-V Administrators group (see: .\ansibox.ps1 help).',
            'If you just enabled Hyper-V, restart the PC.',
            'Check the service:  Get-Service vmms'
        )
    }
    Write-Ok 'Hyper-V is enabled and running'
}

# Tooling needed only by 'start' when it builds a lab: NAT cmdlets, OpenSSH client, curl.
function Test-Prerequisites {
    Write-Step 'Checking prerequisites'
    if (-not (Get-Command New-NetNat -ErrorAction SilentlyContinue)) {
        Stop-Prereq 'NetNat cmdlets (New-NetNat) not found - they give the lab its internet access.' @(
            'Check that the module exists:  Get-Module -ListAvailable NetNat',
            'Use a supported Windows 10/11 Pro, Enterprise or Education edition with Hyper-V enabled.'
        )
    }
    $missing = @('ssh', 'scp', 'ssh-keygen', 'curl.exe') |
               Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }
    if ($missing) {
        Stop-Prereq "Required tool(s) not found: $($missing -join ', ')." @(
            'Install the Windows OpenSSH Client: Settings > System > Optional features > Add a feature > "OpenSSH Client".',
            'Or from an elevated PowerShell:  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0',
            'curl.exe ships with Windows 10 (1803+) and 11 - run Windows Update if it is missing.',
            'Open a new PowerShell window afterwards so the updated PATH is picked up.'
        )
    }
    Write-Ok 'NetNat and OpenSSH client OK'
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
            throw "Subnet $Subnet.0/24 is already in use on this machine (interface '$(@($clash)[0].InterfaceAlias)'). Pick another with --subnet."
        }
        Write-Step "Assigning $GatewayIp/$NetPrefix to the host adapter"
        New-NetIPAddress -InterfaceAlias $alias -IPAddress $GatewayIp -PrefixLength $NetPrefix | Out-Null
    }

    $cidr = "$Subnet.0/$NetPrefix"
    $nats = @(Get-NetNat -ErrorAction SilentlyContinue)
    $mine = $nats | Where-Object { $_.Name -eq $NatName }
    if ($mine) {
        if ($mine.InternalIPInterfaceAddressPrefix -ne $cidr) {
            throw "NAT '$NatName' exists for $($mine.InternalIPInterfaceAddressPrefix), not $cidr. Run '.\ansibox.ps1 delete' first."
        }
    } else {
        if ($nats.Count -gt 0) {
            throw "Another NAT already exists ('$($nats[0].Name)', $($nats[0].InternalIPInterfaceAddressPrefix)). Windows supports only one NAT network per host. Remove it (Remove-NetNat -Name '$($nats[0].Name)') or reuse it with a matching --subnet / --profile."
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

# Read-only: is the lab network intact (switch + gateway address on the host adapter + NAT)?
# 'start' uses it when resuming a lab: a healthy network needs no admin rights at all.
# Anything that cannot be verified counts as "not healthy" (the safe direction: it then asks
# for Administrator instead of failing half-way).
function Test-LabNetworkHealthy {
    try {
        $alias = "vEthernet ($SwitchName)"
        if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) { return $false }
        $gw = Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -eq $GatewayIp }
        if (-not $gw) { return $false }
        $nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
        if (-not $nat) { return $false }
        return ($nat.InternalIPInterfaceAddressPrefix -eq "$Subnet.0/$NetPrefix")
    } catch { return $false }
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
        throw "'$Path' is still sparse/compressed/encrypted. Set LAB_HOME to a plain NTFS folder (not compressed or encrypted) and retry."
    }
}

# Find the expected checksum of $FileName in a checksum file. Understands both layouts:
#   GNU  (Debian SHA512SUMS):   <hash>  <file>
#   BSD  (AlmaLinux CHECKSUM):  SHA256 (<file>) = <hash>      (comment lines are ignored)
function Get-ExpectedHash([string[]]$Lines, [string]$FileName, [string]$Algo) {
    $name = [regex]::Escape($FileName)
    foreach ($ln in $Lines) {
        if ($ln -match "^\s*$Algo\s*\($name\)\s*=\s*([0-9a-fA-F]{32,})\s*$") { return $Matches[1].ToLower() }
        if ($ln -match "^\s*([0-9a-fA-F]{32,})\s+\*?$name\s*$")             { return $Matches[1].ToLower() }
    }
    return $null
}

# Builds the shared base disk of the selected OS (one VHDX per OS, built once).
function Initialize-BaseDisk {
    if (Test-Path $BaseVhdx) { return }
    New-Item -ItemType Directory -Force $ImgDir | Out-Null
    $imageName = $Distro.ImageName
    $qcow      = "$ImgDir\$imageName"

    if (-not (Test-Path $qcow)) {
        Write-Step "Downloading $imageName (one time)"
        & curl.exe -fL --progress-bar -o $qcow "$($Distro.ImageBase)/$imageName"
        if ($LASTEXITCODE -ne 0) { Remove-Item $qcow -ErrorAction SilentlyContinue; throw 'Image download failed.' }
    }

    Write-Step "Verifying $($Distro.Algo) checksum"
    $sums = & curl.exe -fsSL "$($Distro.ImageBase)/$($Distro.SumsFile)"
    if ($LASTEXITCODE -ne 0) { throw "Could not download $($Distro.SumsFile) to verify the image." }
    $expected = Get-ExpectedHash -Lines @($sums) -FileName $imageName -Algo $Distro.Algo
    if (-not $expected) { throw "Could not find $imageName in $($Distro.SumsFile)." }
    $actual = (Get-FileHash $qcow -Algorithm $Distro.Algo).Hash.ToLower()
    if ($expected -ne $actual) {
        Remove-Item $qcow -Force
        throw 'Checksum mismatch: the upstream image changed (the "latest" alias is rebuilt regularly) or the download was corrupted. The cached copy was removed - re-run to fetch a fresh one.'
    }
    Write-Ok 'Checksum OK'

    Write-Step 'Converting qcow2 -> VHDX (one time)'
    $qemu = Get-QemuImg
    # NOTE: the temp file must keep a .vhdx extension - the Hyper-V disk cmdlets
    # (Get-VHD / Resize-VHD) key off the extension.
    $tmp  = "$ImgDir\$($Distro.BaseId)-base.building.vhdx"
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

# cloud-init user-data. Package names, admin group and Hyper-V guest service come from the
# selected OS entry in $Distros (Debian: sudo/apt/ansible, Red Hat family: wheel/dnf/ansible-core).
function New-UserData([string]$HostName, [bool]$IsControl, [string]$PubKey) {
    $pkgs = @($Distro.Packages)
    if ($IsControl) { $pkgs += @($Distro.ControlPackages) }

    $l = @(
        '#cloud-config',
        "hostname: $HostName",
        'users:',
        "  - name: $LabUser",
        '    gecos: Ansible lab user',
        "    groups: [$($Distro.AdminGroup)]",
        '    sudo: ALL=(ALL) NOPASSWD:ALL',
        '    shell: /bin/bash',
        '    lock_passwd: true',
        '    ssh_authorized_keys:',
        "      - $PubKey",
        'package_update: true'
    )
    if ($pkgs.Count -gt 0) {
        $l += 'packages:'
        foreach ($p in $pkgs) { $l += "  - $p" }
    }
    $l += 'runcmd:'
    foreach ($c in $Distro.RunCmd) { $l += "  - $c" }
    if ($IsControl) {
        foreach ($c in @($Distro.ControlRunCmd)) { $l += "  - $c" }
    }
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
        "      - to: $($Distro.DefaultRoute)",
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
            Write-Warn2 "$Name exists but is on switch '$sn' (expected '$SwitchName'). Run '.\ansibox.ps1 delete' and then 'start' to rebuild it with a fixed IP."
        } else {
            Write-Warn2 "$Name already exists - keeping it"
        }
        return
    }
    Write-Step "Creating $Name ($(Get-LabIp $Name))"
    $dir = "$VmDir\$Name"
    # No VM with this name exists (checked above), so a folder here is a leftover of an
    # earlier failed run. Start clean, otherwise New-VHD fails with "file already exists".
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    New-Item -ItemType Directory -Force $dir | Out-Null

    try {
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
        # Memory mode (static or dynamic) was chosen once for this run - see Read-MemoryMode.
        if ($MemoryMode -eq 'dynamic') {
            Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true `
                         -MinimumBytes ($DynMinMB * 1MB) -StartupBytes ($MemoryMB * 1MB) -MaximumBytes ($DynMaxMB * 1MB)
        } else {
            Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
        }
        Set-VMNetworkAdapter -VMName $Name -StaticMacAddress $mac
        Set-VMFirmware -VMName $Name -EnableSecureBoot Off
        Add-VMDvdDrive -VMName $Name -Path $iso
        Set-VMFirmware -VMName $Name -FirstBootDevice (Get-VMHardDiskDrive -VMName $Name)
    }
    catch {
        # Roll back: a half-built VM (e.g. without its seed ISO) would be "kept" on the next
        # run and never get its IP. Remove the VM and its folder, then report the real error.
        $err = $_
        Write-Warn2 "Creating $Name failed - rolling back"
        try {
            $vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
            if ($vm) {
                if ($vm.State -ne 'Off') { Stop-VM -Name $Name -TurnOff -Force -ErrorAction SilentlyContinue }
                Remove-VM -Name $Name -Force -ErrorAction SilentlyContinue
            }
        } catch { }
        Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        throw $err
    }
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

# SSH answers as soon as cloud-init has created the user and key, which is BEFORE its package
# stage (hyperv-daemons, ansible) finishes. Until then the package manager holds its lock
# (apt/dpkg or dnf), so a playbook run right after 'start' could fail. Block until cloud-init
# is done, with an upper limit.
function Wait-CloudInit([string]$Name, [string]$Ip, [int]$TimeoutSec = 900) {
    $rc = Invoke-Remote $Ip "timeout $TimeoutSec cloud-init status --wait >/dev/null 2>&1"
    # 0 = done, 2 = done with recoverable warnings (not worth alarming anyone about)
    if ($rc -eq 0 -or $rc -eq 2) { return }
    if ($rc -eq 124) {
        Write-Warn2 "${Name}: cloud-init still running after $TimeoutSec s. Check with: sudo cloud-init status --long"
    } else {
        Write-Warn2 "${Name}: cloud-init reported errors (exit $rc). Check with: sudo cloud-init status --long"
    }
}

# Push a generated file to ~/lab on the control node WITHOUT clobbering the user's edits:
#   - missing        -> copy it
#   - identical      -> nothing to do
#   - exists, differs -> keep the user's file, save ours next to it as <name>.new and say so
function Send-LabFile([string]$Ip, [string]$LocalPath, [string]$RemoteName) {
    $ErrorActionPreference = 'Continue'
    $remote = "lab/$RemoteName"
    if ((Invoke-Remote $Ip "test -e $remote") -ne 0) {
        Copy-ToRemote $Ip $LocalPath $remote
        return
    }
    $localHash  = (Get-FileHash $LocalPath -Algorithm SHA256).Hash.ToLower()
    $remoteOut  = & ssh @BatchOpts "$LabUser@$Ip" "sha256sum $remote" 2>$null
    $remoteHash = if ($LASTEXITCODE -eq 0 -and $remoteOut) { (([string]($remoteOut | Select-Object -First 1)) -split '\s+')[0].ToLower() } else { '' }
    if ($remoteHash -eq $localHash) { return }
    Copy-ToRemote $Ip $LocalPath "$remote.new"
    Write-Warn2 "~/lab/$RemoteName already exists and differs - kept yours, new version saved as ~/lab/$RemoteName.new"
}

function Set-ControlNode([string]$ControlIp, [hashtable]$WorkerIps, [string]$ControlName) {
    Write-Step 'Configuring the control node'
    if ((Invoke-Remote $ControlIp 'command -v ansible >/dev/null') -ne 0) {
        Write-Warn2 'Ansible is not installed on control yet (the package install may have failed). Check: sudo cloud-init status --long'
    }

    $inv = @("[control]", "$ControlName ansible_connection=local", "", "[nodes]")
    foreach ($n in ($WorkerIps.Keys | Sort-Object)) { $inv += "$n ansible_host=$($WorkerIps[$n])" }
    $inv += @("", "[all:vars]",
              "ansible_user=$LabUser",
              "ansible_ssh_private_key_file=~/.ssh/id_ed25519",
              "ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'",
              "ansible_python_interpreter=/usr/bin/python3")

    $cfg = @('[defaults]', 'inventory = ./inventory.ini', 'host_key_checking = False', 'interpreter_python = auto_silent')

    # The package task differs per OS family (apt vs dnf); everything else is shared.
    $play = @(
        '---',
        '- name: Smoke test for the lab',
        '  hosts: nodes',
        '  become: true',
        '  tasks'  + ':'
    ) + @($Distro.SmokeTask) + @(
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
    # The private key is always (re)pushed - it never changes. The lab files are not overwritten.
    Send-LabFile $ControlIp "$tmp\inventory.ini" 'inventory.ini'
    Send-LabFile $ControlIp "$tmp\ansible.cfg"   'ansible.cfg'
    Send-LabFile $ControlIp "$tmp\site.yml"      'site.yml'
    [void](Invoke-Remote $ControlIp 'chmod 600 ~/.ssh/id_ed25519')
    Remove-Item $tmp -Recurse -Force
}

# A VM belongs to the lab only if it is named exactly <prefix>-control or <prefix>-nodeN.
# A bare "<prefix>-*" wildcard would also catch unrelated VMs (e.g. "lab-sql") and
# 'delete' would remove them.
function Test-LabVmName([string]$Name) {
    return ($Name -match ('^' + [regex]::Escape($Prefix) + '-(control|node\d+)$'))
}
function Get-LabVms {
    @(Get-VM -Name "$Prefix-*" -ErrorAction SilentlyContinue | Where-Object { Test-LabVmName $_.Name })
}
# VM folders under $VmDir that follow the lab naming (also finds leftovers of a failed build).
function Get-LabVmDirs {
    if (-not (Test-Path $VmDir)) { return @() }
    @(Get-ChildItem $VmDir -Directory -ErrorAction SilentlyContinue | Where-Object { Test-LabVmName $_.Name })
}

# ------------------------------------------------------------------ actions
function Invoke-Up {
    Assert-Administrator 'creating a lab sets up the virtual switch, the NAT network and the host IP address'
    Test-Prerequisites

    # Which OS? Asked once, when the lab is first created (or taken from --distro / the existing
    # lab). Done before the long steps so the rest of the run is unattended.
    Set-ActiveDistro (Resolve-Distro)
    Save-DistroChoice
    Write-Ok "OS: $($Distro.Name)"
    if ($MemoryMB -lt $Distro.MinMemoryMB) {
        Write-Warn2 "$($Distro.Short) needs about $($Distro.MinMemoryMB) MB per VM to install packages reliably (you asked for $MemoryMB MB). Consider --memory $($Distro.MinMemoryMB)."
    }

    # Ask about memory next. Only asked when this run will actually create VMs;
    # existing VMs keep their settings.
    $labNames = @("$Prefix-control") + @(1..$Workers | ForEach-Object { "$Prefix-node$_" })
    $newVms   = @($labNames | Where-Object { -not (Get-VM -Name $_ -ErrorAction SilentlyContinue) })
    if ($newVms.Count -gt 0) {
        $script:MemoryMode = Read-MemoryMode
        if ($MemoryMode -eq 'dynamic') {
            Write-Ok "Memory: dynamic ($DynMinMB MB minimum, $MemoryMB MB at start, $DynMaxMB MB maximum)"
        } else {
            Write-Ok "Memory: static ($MemoryMB MB per VM)"
        }
    }

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

    Write-Step 'Waiting for cloud-init to finish on every node (installs packages, up to a few minutes)'
    foreach ($n in @($control) + $workers) {
        Wait-CloudInit $n $ips[$n]
        Write-Ok "$n  cloud-init done"
    }

    $workerIps = @{}
    foreach ($w in $workers) { $workerIps[$w] = $ips[$w] }
    Set-ControlNode -ControlIp $ips[$control] -WorkerIps $workerIps -ControlName $control

    Write-Host ''
    Write-Host "Lab is ready.  ($($Distro.Name))" -ForegroundColor Green
    Write-Host "  Connect:   .\ansibox.ps1 ssh      (or: ssh -i `"$KeyPath`" $LabUser@$($ips[$control]))"
    Write-Host "  Then run:  cd ~/lab && ansible all -m ping"
    Write-Host "             ansible-playbook site.yml"
    Write-Host "  Tear down: .\ansibox.ps1 delete"
    Write-Elapsed
}

function Invoke-Status {
    $vms = Get-LabVms
    if (-not $vms) { Write-Host 'No lab VMs found. Run: .\ansibox.ps1 start'; return }
    $os = $Distros[(Get-LabDistroKey)].Short
    $vms | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            State    = $_.State
            OS       = $os
            IP       = Get-LabIp $_.Name
            CPUs     = $_.ProcessorCount
            MemoryMB = [int]($_.MemoryStartup / 1MB)
        }
    } | Format-Table -AutoSize
}

function Invoke-SshAction {
    if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
        Stop-Prereq "The 'ssh' client was not found." @(
            'Install the Windows OpenSSH Client: Settings > System > Optional features > Add a feature > "OpenSSH Client".',
            'Open a new PowerShell window afterwards so the updated PATH is picked up.'
        )
    }
    $name = $Target
    if ($name -notlike "$Prefix-*") { $name = "$Prefix-$name" }

    # The IP is fixed by the VM name, so plain SSH needs no Hyper-V call and no elevation.
    # When we are allowed to ask Hyper-V (admin / Hyper-V Administrators), check first so the
    # error is precise; otherwise just connect and explain if that fails.
    $canAsk = (Test-HasHyperVAccess) -and [bool](Get-Command Get-VM -ErrorAction SilentlyContinue)
    if ($canAsk) {
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) { throw "VM '$name' not found. Try: .\ansibox.ps1 status" }
        if ($vm.State -ne 'Running') { throw "$name is not running. Try: .\ansibox.ps1 start" }
    }
    $ip = Get-LabIp $name
    Clear-KnownHost $ip
    & ssh @BaseOpts -o ConnectTimeout=10 "$LabUser@$ip"
    if ($LASTEXITCODE -eq 255) {
        Write-Warn2 "Could not connect to $name ($ip). Is the lab running? Try: .\ansibox.ps1 start  (and .\ansibox.ps1 status)"
    }
}

function Invoke-Destroy {
    $vms  = Get-LabVms
    $dirs = Get-LabVmDirs
    $haveNet = [bool](Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue) -or
               [bool](Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)
    if (-not $vms -and -not $dirs -and -not $haveNet -and -not $Purge) { Write-Host 'Nothing to destroy.'; return }

    if (-not $Force) {
        $list = if ($vms) { ' [' + ((@($vms) | ForEach-Object { $_.Name }) -join ', ') + ']' } else { '' }
        $what = if ($Purge) { "ALL lab VMs$list, the lab switch/NAT and everything in $LabPath (keys + cached images)" } else { "all lab VMs$list, their disks and the lab switch/NAT" }
        $ans = Read-Answer "This will delete $what. Continue? [y/N]"
        if ($ans -notmatch '^(y|yes)$') { Write-Host 'Aborted.'; return }
    }

    foreach ($vm in $vms) {
        Write-Step "Removing $($vm.Name)"
        if ($vm.State -ne 'Off') { Stop-VM -Name $vm.Name -TurnOff -Force }
        Remove-VM -Name $vm.Name -Force
        Remove-Item "$VmDir\$($vm.Name)" -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Folders with no VM behind them (left by a failed 'start') are removed too.
    foreach ($d in (Get-LabVmDirs)) { Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-LabNetwork
    Remove-Item $KnownHost -Force -ErrorAction SilentlyContinue
    # Forget the OS choice: the next 'start' asks again.
    Remove-Item $DistroFile -Force -ErrorAction SilentlyContinue

    if ($Purge -and (Test-Path $LabPath)) {
        Write-Step "Purging $LabPath"
        # Base disks (one per OS) are marked read-only; clear that so they can be deleted.
        Get-ChildItem "$ImgDir\*-base.vhdx" -ErrorAction SilentlyContinue |
            ForEach-Object { Set-ItemProperty $_.FullName -Name IsReadOnly -Value $false }
        Remove-Item $LabPath -Recurse -Force
    }
    Write-Ok 'Done.'
    Write-Elapsed
}

function Invoke-Start {
    # Switch/NAT are recreated if the host lost them (e.g. after a reboot). Only that repair
    # needs Administrator; with a healthy network, powering the VMs on needs no elevation.
    if (-not (Test-LabNetworkHealthy)) {
        Assert-Administrator 'the lab network (virtual switch / NAT / host address) is missing or incomplete and has to be recreated'
        Initialize-LabNetwork
    }
    Get-LabVms | Where-Object State -ne 'Running' | Start-VM
    Write-Ok 'Started.'
    Write-Elapsed
}

# 'start' creates the lab if it doesn't exist and resumes it if it does.
# Resuming only powers the VMs on; it does not touch the files in ~/lab on the control node.
function Invoke-StartCmd {
    if ((Get-LabVms) -and -not $Flags.ContainsKey('nodes')) { Invoke-Start } else { Invoke-Up }
}

# --------------------------------------------------------------------- main
$CommandTimer.Start()
# 'help', 'help <command>' and '<command> --help' all show the manual.
$HelpTopic = $null
if ($Flags.ContainsKey('help')) {
    if ($Command -ne 'help') { $HelpTopic = $Command }
    $Command = 'help'
}

if (@('start', 'stop', 'status', 'ssh', 'delete', 'help') -notcontains $Command) {
    throw "Unknown command '$Command'. Try: .\ansibox.ps1 help"
}

# 'help' works anywhere. Every other command asks only for the rights it really needs:
#   ssh              nothing: plain SSH to a fixed IP, no Hyper-V call at all
#   status, stop     permission to manage VMs: Administrator OR the 'Hyper-V Administrators' group
#   start            the same to resume; Administrator is asked later, only if the lab network
#                    has to be recreated (Invoke-Start) or a lab has to be built (Invoke-Up)
#   delete           Administrator: it removes the virtual switch and the NAT network
switch ($Command) {
    'help'   { }
    'ssh'    { }
    'delete' { Assert-Administrator 'deleting a lab removes its virtual switch and NAT network'; Assert-HyperV }
    default  { Assert-HyperVAccess; Assert-HyperV }      # start, status, stop
}

switch ($Command) {
    'start'  { Invoke-StartCmd }
    'status' { Invoke-Status }
    'ssh'    { Invoke-SshAction }
    'stop'   { Get-LabVms | Where-Object State -eq 'Running' | Stop-VM; Write-Ok 'Stopped.' }
    'delete' { Invoke-Destroy }
    'help'   { Show-Help $HelpTopic }
    default  { throw "Unknown command '$Command'. Try: .\ansibox.ps1 help" }
}
