#Requires -RunAsAdministrator
#Requires -Module Hyper-V

<#
.SYNOPSIS
    Provisions two Rocky Linux 10 VMs on Hyper-V for a dev lab.
    VM1: DevTools + Private Docker Registry
    VM2: Single-node RKE2 Kubernetes + Rancher

.NOTES
    Pre-requisites:
    - Hyper-V enabled on Windows host
    - Rocky Linux 10 ISO downloaded (set $ISOPath below)
    - Run from an elevated PowerShell session
#>

[CmdletBinding()]
param(
    [string]$ISOPath        = "C:\ISOs\Rocky-10.1-x86_64-minimal.iso",
    [string]$VMStoragePath  = "", # User decides where they want to store VM HDs
    [string]$SwitchName     = "LabSwitch",
    [string]$NATNetwork     = "192.168.100.0/24",
    [string]$GatewayIP      = "192.168.100.1",
    [string]$DevtoolsIP     = "192.168.100.10",
    [string]$K8sIP          = "192.168.100.20",
    [string]$DNS            = "8.8.8.8",
    [switch]$SkipVMCreation, # Set this if VMs exist, jump straight to IP display
    [string]$DefaultSwitchName = "Default Switch",
    [string]$Timezone          = "Australia/Sydney",
    [SecureString]$AnsiblePassword # prompted if not supplied
)

if (-not $AnsiblePassword) {
    $AnsiblePassword = Read-Host "Ansible user password" -AsSecureString
}
$ansiblePwPlain = [System.Net.NetworkCredential]::new('', $AnsiblePassword).Password

if (-not $VMStoragePath) {
    Write-Host "`nAvailable drives:" -ForegroundColor Cyan
    Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Used } |
        Sort-Object Root |
        ForEach-Object { Write-Host ("  {0,-6} {1,8:N1} GB free" -f $_.Root, ($_.Free / 1GB)) }
    $VMStoragePath = Read-Host "`nVM storage path (press Enter for C:\VMs)"
    if (-not $VMStoragePath) { $VMStoragePath = "C:\VMs" }
}

if ($NATNetwork -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    throw "NATNetwork must be CIDR like 192.168.100.0/24 (got '$NATNetwork')"
}
[byte]$null = ($NATNetwork -split '/', 2)[1]  # throws if not numeric/byte

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Colour helpers
function Write-Step  { param($msg) Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-Done  { param($msg) Write-Host "    [!] $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "    [!] $msg" -ForegroundColor Yellow }

# Creates a 50 MB FAT32 VHD labeled OEMDRV containing a kickstart file.
# Anaconda auto-detects ks.cfg on any block device with this label.
function New-OemdrvVhd {
    param([string]$VhdPath, [string]$KickstartContent)

    New-VHD -Path $VhdPath -SizeBytes 50MB -Fixed | Out-Null

    $tempKs = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempKs, $KickstartContent, [System.Text.Encoding]::ASCII)

    try {
        $dpAttach = @"
select vdisk file="$VhdPath"
attach vdisk
create partition primary
format fs=fat32 label="OEMDRV" quick
assign
exit
"@
        $dpAttach | diskpart | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DISKPART failed to format OEMDRV VHD at '$VhdPath'" }

        $driveLetter = (Get-DiskImage -ImagePath $VhdPath | Get-Disk |
                        Get-Partition | Get-Volume).DriveLetter
        if (-not $driveLetter) { throw "No drive letter was assigned to OEMDRV VHD" }

        Copy-Item -Path $tempKs -Destination "${driveLetter}:\ks.cfg"

        $dpDetach = @"
select vdisk file="$VhdPath"
detach vdisk
exit
"@
        $dpDetach | diskpart | Out-Null
    } finally {
        Remove-Item $tempKs -Force -ErrorAction SilentlyContinue
    }
}

# VM definitions
$VMs = @(
    @{
        Name        = "lab-devtools"
        CPU         = 4
        MemoryGB    = 8
        DiskGB      = 80
        IPAddress   = $DevtoolsIP
        Description = "DevTools + Docker Registry"
    },
    @{
        Name        = "lab-k8s"
        CPU         = 8
        MemoryGB    = 32
        DiskGB      = 120
        IPAddress   = $K8sIP
        Description = "RKE2 Single-node + Rancher"
    }
)

# Step 1: Internal NAT switch
Write-Step "Configuring Hyper-V NAT switch: $SwitchName"

if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Done "Switch created"
} else {
    Write-Warn "Switch '$SwitchName' already exists, skipping"
}

# Configure host NIC with gateway IP
$hostAdapter = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
if ($hostAdapter) {
    $existingIP = Get-NetIPAddress -InterfaceIndex $hostAdapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if (-not $existingIP) {
        $network, $prefixText = $NATNetwork -split '/', 2
        [byte]$prefix = $prefixText
        New-NetIPAddress -IPAddress $GatewayIP -PrefixLength $prefix -InterfaceIndex $hostAdapter.IfIndex | Out-Null
        Write-Done "Host adapter IP set to $GatewayIP"
    } else {
        Write-Warn "Host adapter already has IP $($existingIP.IPAddress)"
    }
}

# NAT
$natName = "LabNAT"
if (-not (Get-NetNat -Name $natName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix $NATNetwork | Out-Null
    Write-Done "NAT '$natName' created for $NATNetwork"
} else {
    Write-Warn "NAT '$natName' already exists"
}

# Step 2: Validate Default Switch
Write-Step "Validating '$DefaultSwitchName' switch exists"
if (-not (Get-VMSwitch -Name $DefaultSwitchName -ErrorAction SilentlyContinue)) {
    throw "Hyper-V switch '$DefaultSwitchName' not found. Ensure Hyper-V is fully initialized."
}
Write-Done "Switch '$DefaultSwitchName' found"

# Step 3: Create VMs
if (-not $SkipVMCreation) {
    foreach ($vm in $VMs) {
        Write-Step "Creating VM: $($vm.Name) - $($vm.Description)"

        $vmPath  = Join-Path $VMStoragePath $vm.Name
        $vhdPath = Join-Path $vmPath "$($vm.Name)-os.vhdx"

        if (Get-VM -Name $vm.Name -ErrorAction SilentlyContinue) {
            Write-Warn "VM '$($vm.Name)' already exists, skipping creation"
            continue
        }

        # Create VM directory
        New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

        # Create VHDX
        New-VHD -Path $vhdPath -SizeBytes ($vm.DiskGB * 1GB) -Dynamic | Out-Null
        Write-Done "VHDX created at $vhdPath ($($vm.DiskGB) GB)"

        # Create VM
        $newVM = New-VM `
            -Name        $vm.Name `
            -MemoryStartupBytes ($vm.MemoryGB * 1GB) `
            -VHDPath     $vhdPath `
            -Generation  2 `
            -SwitchName  $SwitchName `
            -Path        $VMStoragePath

        # CPU
        Set-VMProcessor -VM $newVM -Count $vm.CPU
        # Static memory
        Set-VMMemory -VM $newVM -DynamicMemoryEnabled $false `
            -StartupBytes ($vm.MemoryGB * 1GB)
        # Secure boot off (not required for Linux)
        Set-VMFirmware -VM $newVM -EnableSecureBoot Off
        # Mount ISO
        Add-VMDvdDrive -VM $newVM -Path $ISOPath
        $dvd = Get-VMDvdDrive -VM $newVM
        if (-not $dvd -or $dvd.Path -ne $ISOPath) {
            throw "ISO '$ISOPath' was not attached to VM '$($vm.Name)'"
        }
        Write-Done "ISO attached: $($dvd.Path)"
        # Boot order: DVD first
        $disk = Get-VMHardDiskDrive -VM $newVM
        Set-VMFirmware -VM $newVM -BootOrder $dvd, $disk

        Write-Done "VM '$($vm.Name)' created  $($vm.CPU) vCPU / $($vm.MemoryGB) GB RAM"

        # Default Switch NIC (internet via DHCP)
        Add-VMNetworkAdapter -VM $newVM -SwitchName $DefaultSwitchName
        $nicDefault = Get-VMNetworkAdapter -VM $newVM |
                      Where-Object { $_.SwitchName -eq $DefaultSwitchName }
        if (-not $nicDefault) {
            throw "Default Switch adapter was not added to VM '$($vm.Name)'"
        }
        Write-Done "Default Switch NIC added (internet via DHCP)"

        # Full unattended kickstart.
        # Hyper-V Gen 2 VMBus NICs have no PCI slot info, so systemd falls back
        # to eth0/eth1 naming — first NIC created (LabSwitch) = eth0, second = eth1
        $ksContent = @"
# Auto-generated by New-LabVMs.ps1 for $($vm.Name)

# --- Locale ---
lang en_US.UTF-8
keyboard --vckeymap=us --xlayouts='us'
timezone $Timezone --utc

# --- Network ---
network --bootproto=static --device=eth0 --ip=$($vm.IPAddress) --netmask=255.255.255.0 --gateway=$GatewayIP --nameserver=$DNS --activate --onboot=yes --hostname=$($vm.Name)
network --bootproto=dhcp --device=eth1 --activate --onboot=yes

# --- Disk (LVM, wipe entire disk) ---
zerombr
clearpart --all --initlabel
autopart --type=lvm

# --- Auth ---
rootpw --lock
user --name=ansible --groups=wheel --password=$ansiblePwPlain --plaintext

# --- Security ---
firewall --enabled --service=ssh
selinux --enforcing
services --enabled=sshd

# --- Packages ---
%packages
@^minimal-environment
openssh-server
%end

# --- Post-install ---
%post
echo "ansible ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/ansible
chmod 440 /etc/sudoers.d/ansible
%end

reboot
"@

        # OEMDRV VHD — Anaconda auto-detects ks.cfg on block devices labeled OEMDRV
        $oemdrvPath = Join-Path $vmPath "oemdrv.vhd"
        Write-Step "Creating OEMDRV kickstart disk for $($vm.Name)"
        New-OemdrvVhd -VhdPath $oemdrvPath -KickstartContent $ksContent
        Add-VMHardDiskDrive -VM $newVM -Path $oemdrvPath -ControllerType SCSI
        $oemdrvDisk = Get-VMHardDiskDrive -VM $newVM |
                      Where-Object { $_.Path -eq $oemdrvPath }
        if (-not $oemdrvDisk) {
            throw "OEMDRV disk was not attached to VM '$($vm.Name)'"
        }
        Write-Done "OEMDRV kickstart disk attached: $oemdrvPath"

        Write-Warn "  VM will install Rocky Linux automatically (no prompts)."
        Write-Warn "    When prompted at boot, select 'anaconda kickstart'."
        Write-Warn "    Installs, configures networking, then reboots automatically."
        Write-Warn "      eth0 (lab):      $($vm.IPAddress)/24  GW: $GatewayIP  DNS: $DNS"
        Write-Warn "      eth1 (internet): DHCP via Default Switch"
        Write-Warn "    SSH: ssh ansible@$($vm.IPAddress)  (use the password you set)"
        Write-Warn "    If kickstart is not auto-applied, add at the GRUB prompt:"
        Write-Warn "      inst.ks=hd:LABEL=OEMDRV:/ks.cfg"

    }
}

# Step 4: Update Windows hosts file
Write-Step "Updating Windows hosts file"

$hostsFile  = "$env:SystemRoot\System32\drivers\etc\hosts"
$labEntries = @(
    "$DevtoolsIP`tlab-devtools"
    "$K8sIP`tlab-k8s"
)

$hostsContent = [System.IO.File]::ReadAllText($hostsFile)
$newLines     = [System.Collections.Generic.List[string]]::new()

foreach ($entry in $labEntries) {
    $parts     = $entry -split '\t'
    $ip        = $parts[0]
    $hostnames = $parts[1..($parts.Count - 1)] -join ' '

    if ($hostsContent -notmatch [regex]::Escape($ip)) {
        $newLines.Add("")
        $newLines.Add("# Added by New-LabVMs.ps1 - Lab environment ($hostnames)")
        $newLines.Add($entry)
        Write-Done "Added: $entry"
    } else {
        Write-Warn "Already present, skipping: $entry"
    }
}

if ($newLines.Count -gt 0) {
    $newLines.Insert(0, "")
    [System.IO.File]::AppendAllLines($hostsFile, $newLines)
} else {
    Write-Warn "All lab entries already in hosts file"
}
