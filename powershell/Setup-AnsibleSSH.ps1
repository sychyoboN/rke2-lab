#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Generates an SSH key pair and copies the public key to both lab VMs
    so Ansible can authenticate without passwords.

.NOTES
    Run this AFTER the VMs are installed and have network access.
    Requires OpenSSH client (available in Windows 10/11 by default).
#>

param(
    [string]$KeyPath    = "$env:USERPROFILE\.ssh\lab_rsa",
    [string]$AnsibleUser = "ansible",
    [string[]]$VMIPs    = @("192.168.100.10", "192.168.100.20")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param($msg) Write-Host "`n[+] $msg" -ForegroundColor Cyan }
function Write-Done { param($msg) Write-Host "    [!] $msg" -ForegroundColor Green }

# ── Generate key pair ─────────────────────────────────────────────────────────
Write-Step "Generating SSH key pair for Ansible"

$keyDir = Split-Path $KeyPath -Parent
if (-not (Test-Path $keyDir)) {
    New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    Write-Done "Created $keyDir"
}

if (-not (Test-Path $KeyPath)) {
    & ssh-keygen -t rsa -b 4096 -f $KeyPath -N '""' -C "ansible-lab"
    if ($LASTEXITCODE -ne 0) { throw "ssh-keygen failed with exit code $LASTEXITCODE" }
    Write-Done "Key generated at $KeyPath"
} else {
    Write-Host "    Key already exists at $KeyPath" -ForegroundColor Yellow
}

$pubKey = Get-Content "$KeyPath.pub"

# ── Copy public key to each VM ────────────────────────────────────────────────
foreach ($ip in $VMIPs) {
    Write-Step "Copying public key to $AnsibleUser@$ip"

    # Remove stale known_hosts entries so re-runs work after VM rebuilds
    try { & ssh-keygen -R $ip 2>&1 | Out-Null } catch { <# not in known_hosts - fine #> }

    Write-Host "    You will be prompted for the ansible user password." -ForegroundColor Yellow

    # Create .ssh dir and append key (idempotent: skip if key already present)
    $cmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF '$pubKey' ~/.ssh/authorized_keys 2>/dev/null || echo '$pubKey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    & ssh -o StrictHostKeyChecking=accept-new "$AnsibleUser@$ip" $cmd

    if ($LASTEXITCODE -eq 0) {
        Write-Done "Public key installed on $ip"
    } else {
        Write-Host "    Failed to copy key to $ip - check SSH access" -ForegroundColor Red
    }
}

# ── Test connectivity ─────────────────────────────────────────────────────────
Write-Step "Testing SSH connectivity (key auth)"
foreach ($ip in $VMIPs) {
    $result = & ssh -i $KeyPath -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$AnsibleUser@$ip" "hostname" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Done "$ip -> $result"
    } else {
        Write-Host "    FAILED for $ip" -ForegroundColor Red
    }
}

Write-Step "Done! Run Ansible from WSL or a Linux machine:"
Write-Host ""
Write-Host "  # From WSL, copy the key and fix permissions:"
Write-Host "  cp /mnt/c/Users/$env:USERNAME/.ssh/lab_rsa ~/.ssh/lab_rsa"
Write-Host "  chmod 600 ~/.ssh/lab_rsa"
Write-Host ""
Write-Host "  # WSL mounts Windows drives world-writable (777) so Ansible ignores"
Write-Host "  # ansible.cfg there. Point ANSIBLE_CONFIG at the file explicitly:"
Write-Host "  export ANSIBLE_CONFIG=/mnt/c/Users/$env:USERNAME/OneDrive/Documents/01_VS_CODE/rke2-lab/ansible.cfg"
Write-Host ""
Write-Host "  # Then run the playbook:"
Write-Host "  cd /mnt/c/Users/$env:USERNAME/OneDrive/Documents/01_VS_CODE/rke2-lab"
Write-Host "  ansible-galaxy collection install -r requirements.yml"
Write-Host "  ansible-playbook site.yml"
Write-Host ""
Write-Host "  # Permanent fix: add to /etc/wsl.conf then run 'wsl --shutdown':"
Write-Host "  #   [automount]"
Write-Host "  #   options = metadata,umask=022,fmask=011"
Write-Host ""
