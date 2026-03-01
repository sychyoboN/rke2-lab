# Hyper-V Lab — Rocky Linux 10 DevTools + RKE2/Rancher

Automated build of two Rocky Linux 10 VMs on Hyper-V using **PowerShell** (VM provisioning) + **Ansible** (configuration management).

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows Hyper-V Host                                           │
│                                                                 │
│  ┌─────────────────────────┐   ┌───────────────────────────┐   │
│  │  lab-devtools            │   │  lab-k8s                  │   │
│  │  192.168.100.10          │   │  192.168.100.20           │   │
│  │                          │   │                           │   │
│  │  • Git                   │   │  • RKE2 (k8s v1.30)      │   │
│  │  • Docker CE             │   │  • Single-node control    │   │
│  │  • Docker Compose        │   │    plane + worker         │   │
│  │  • Helm                  │   │  • Rancher Manager 2.9    │   │
│  │  • kubectl               │   │  • cert-manager           │   │
│  │  • Docker Registry :5000 │   │                           │   │
│  └──────────┬──────────────┘   └──────────────┬────────────┘   │
│             └──────────────────────────────────┘               │
│                      LabSwitch (192.168.100.0/24)               │
│                      NAT → Internet                             │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Windows 10/11 or Windows Server with **Hyper-V enabled**
- **Rocky Linux 10 minimal ISO** downloaded: `C:\ISOs\Rocky-10.1-x86_64-minimal.iso`
  - Download: https://rockylinux.org/download
- **Ansible** available on WSL2 or a separate Linux machine
- PowerShell 7+ (recommended) or Windows PowerShell 5.1

## Directory Structure

```
├── powershell/
│   ├── New-LabVMs.ps1          # Creates Hyper-V VMs + NAT switch + hosts entries
│   └── Setup-AnsibleSSH.ps1   # SSH key setup for Ansible auth
├── ansible.cfg
├── site.yml                    # Main playbook
├── requirements.yml            # Ansible Galaxy collections
├── hosts.yml                   # Inventory
├── group_vars/
│   └── all.yml                 # Versions, IPs, passwords
└── roles/
    ├── common/                 # Baseline: SELinux, sysctl, packages
    ├── devtools/               # Git, Docker, Helm, kubectl
    ├── registry/               # Private Docker registry (port 5000)
    ├── rke2/                   # RKE2 server install + kubeconfig
    └── rancher/                # cert-manager + Rancher Manager
```

## Step-by-Step Deployment

### Step 1 — Create the VMs (PowerShell, run as Administrator)

```powershell
# Adjust ISOPath if your ISO is elsewhere
.\powershell\New-LabVMs.ps1 -ISOPath "C:\ISOs\Rocky-10.1-x86_64-minimal.iso"
```

This creates:
- Hyper-V internal switch `LabSwitch` with NAT (192.168.100.0/24)
- `lab-devtools` — 4 vCPU / 8 GB RAM / 80 GB VHDX
- `lab-k8s` — 4 vCPU / 16 GB RAM / 120 GB VHDX
- Both VMs boot the Rocky Linux 10 minimal ISO
- Windows hosts file entries for `lab-devtools` and `lab-k8s` / `rancher.lab.local` are added automatically

### Step 2 — Install Rocky Linux 10 on each VM

Boot each VM in Hyper-V and complete the text/graphical installer:

**For BOTH VMs:**
- Partitioning: Automatic
- Minimal install (no GUI needed)
- **Network & Hostname:**
  - `lab-devtools`: static IP `192.168.100.10/24`, GW `192.168.100.1`, DNS `8.8.8.8`
  - `lab-k8s`: static IP `192.168.100.20/24`, GW `192.168.100.1`, DNS `8.8.8.8`
- Create user `ansible` with a password, **add to wheel group**
- After first boot, enable passwordless sudo:
  ```bash
  echo 'ansible ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/ansible
  sudo chmod 0440 /etc/sudoers.d/ansible
  ```
- Enable SSH: `sudo systemctl enable --now sshd`

### Step 3 — Set up SSH key authentication

```powershell
.\powershell\Setup-AnsibleSSH.ps1
```

This generates `~/.ssh/lab_rsa` and installs the public key on both VMs.

### Step 4 — Run Ansible (from WSL2 or Linux)

```bash
# Copy SSH key into WSL
cp /mnt/c/Users/jorda/.ssh/lab_rsa ~/.ssh/lab_rsa
chmod 600 ~/.ssh/lab_rsa

# Install Ansible if needed
pip install ansible

# Install required Ansible Galaxy collections
ansible-galaxy collection install -r requirements.yml --force

# Test connectivity
ansible all -m ping

# Run the full playbook
ansible-playbook site.yml
```

Total runtime: approximately **15–25 minutes** (mostly RKE2 + Rancher startup).

### Step 5 — Access Rancher

> The hosts file entries (`lab-devtools`, `lab-k8s`, `rancher.lab.local`) were added automatically by `New-LabVMs.ps1` in Step 1.

Open: **https://rancher.lab.local**
Bootstrap password: `Admin1234!` (change in `group_vars/all.yml` before deploying!)

## Using the Private Registry

From any machine that can reach `192.168.100.10`:

```bash
# Tag and push an image
docker tag myimage:latest 192.168.100.10:5000/myimage:latest
docker push 192.168.100.10:5000/myimage:latest

# Pull it
docker pull 192.168.100.10:5000/myimage:latest

# List all images in the registry
curl http://192.168.100.10:5000/v2/_catalog

# List tags for an image
curl http://192.168.100.10:5000/v2/myimage/tags/list
```

On the k8s node, Kubernetes is pre-configured to mirror pulls through the registry.

## Running Individual Roles

```bash
# Only configure devtools
ansible-playbook site.yml --limit devtools

# Only deploy RKE2 (skip Rancher)
ansible-playbook site.yml --limit k8s_nodes --skip-tags rancher

# Re-run just the registry setup
ansible-playbook site.yml --tags registry
```

## Customisation

All versions and IPs are in `group_vars/all.yml`:

| Variable | Default | Description |
|---|---|---|
| `rke2_version` | v1.30.4+rke2r1 | RKE2 / Kubernetes version |
| `rancher_version` | 2.9.2 | Rancher Manager version |
| `cert_manager_version` | v1.15.3 | cert-manager version |
| `helm_version` | v3.16.1 | Helm version |
| `kubectl_version` | v1.30.4 | kubectl version |
| `rancher_hostname` | rancher.lab.local | Rancher ingress hostname |
| `rancher_bootstrap_password` | Admin1234! | **Change this!** |
| `private_registry_port` | 5000 | Registry listen port |

## Troubleshooting

**RKE2 won't start:**
```bash
sudo journalctl -u rke2-server -f
sudo /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get pods -A
```

**Rancher pods crashing:**
```bash
kubectl get pods -n cattle-system
kubectl describe pod -n cattle-system <pod-name>
```

**Registry unreachable:**
```bash
# On lab-devtools
sudo docker compose -f /opt/registry/docker-compose.yml ps
sudo systemctl status lab-registry
curl http://localhost:5000/v2/
```

**Ansible can't connect:**
```bash
ssh -i ~/.ssh/lab_rsa ansible@192.168.100.10
ansible all -m ping -vvv
```
