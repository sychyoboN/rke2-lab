# Hyper-V Lab — Rocky Linux 10 DevTools + RKE2/Rancher/ArgoCD

Automated build of two Rocky Linux 10 VMs on Hyper-V using **PowerShell** (VM provisioning) + **Ansible** (configuration management).

```
┌─────────────────────────────────────────────────────────────────┐
│  Windows Hyper-V Host                                           │
│                                                                 │
│  ┌──────────────────────────┐   ┌───────────────────────────┐   │
│  │  lab-devtools            │   │  lab-k8s                  │   │
│  │  192.168.100.10          │   │  192.168.100.20           │   │
│  │                          │   │                           │   │
│  │  • Git                   │   │  • RKE2 (single-node)     │   │
│  │  • Docker CE             │   │  • Single-node control    │   │
│  │  • Docker Compose        │   │    plane + worker         │   │
│  │  • Helm                  │   │  • Rancher Manager 2.9    │   │
│  │  • kubectl               │   │  • cert-manager           │   │
│  │  • k9s                   │   │                           │   │
│  │  • Docker Registry :5000 │   │  • ArgoCD                 │   │
│  │  • Pi-hole DNS :53/:8080 │   │                           │   │
│  └──────────┬───────────────┘   └──────────────┬────────────┘   │
│             └──────────────────────────────────┘                │
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
│   ├── New-LabVMs.ps1          # Creates Hyper-V VMs + NAT switch + kickstart disks
│   └── Setup-AnsibleSSH.ps1   # SSH key setup for Ansible auth
├── ansible.cfg
├── site.yml                    # Main playbook
├── requirements.yml            # Ansible Galaxy collections
├── hosts.yml                   # Inventory
├── group_vars/
│   └── all.yml                 # Versions, IPs, passwords
└── roles/
    ├── common/                 # Baseline: SELinux, sysctl, packages, /etc/hosts
    ├── devtools/               # Git, Docker, Helm, kubectl, k9s, argocd, kubeseal
    ├── registry/               # Private Docker registry (port 5000)
    ├── pihole/                 # Pi-hole DNS server (port 53 / web UI 8080)
    ├── rke2/                   # RKE2 server install + kubeconfig
    ├── rancher/                # cert-manager + Rancher Manager
    └── argocd/                 # ArgoCD GitOps engine
```

## Step-by-Step Deployment

### Step 1 — Create the VMs (PowerShell, run as Administrator)

```powershell
# Adjust ISOPath if your ISO is elsewhere
.\powershell\New-LabVMs.ps1 -ISOPath "C:\ISOs\Rocky-10.1-x86_64-minimal.iso"
# Ansible user password: Admin1234!
```

This creates:
- Hyper-V internal switch `LabSwitch` with NAT (192.168.100.0/24)
- `lab-devtools` — 4 vCPU / 8 GB RAM / 80 GB VHDX
- `lab-k8s` — 8 vCPU / 32 GB RAM / 120 GB VHDX
- Both VMs boot the Rocky Linux 10 minimal ISO with an attached OEMDRV kickstart disk
- Windows hosts file entries for `lab-devtools` and `lab-k8s` are added automatically

### Step 2 — Run the Rocky Linux installer on each VM

Boot each VM in Hyper-V and start the unattended kickstart install:

**For BOTH VMs:**
- At the boot menu, select `anaconda kickstart`
- The kickstart automatically configures:
  - Minimal Rocky Linux 10 install
  - Static lab NIC on `eth0`
    - `lab-devtools`: `192.168.100.10/24`, GW `192.168.100.1`, DNS `8.8.8.8`
    - `lab-k8s`: `192.168.100.20/24`, GW `192.168.100.1`, DNS `8.8.8.8`
  - DHCP internet NIC on `eth1` via Hyper-V `Default Switch`
  - `ansible` user with passwordless sudo
  - `sshd` enabled at boot
- After the first reboot, verify you can log in:
  ```bash
  ssh ansible@192.168.100.10
  ssh ansible@192.168.100.20
  ```

### Step 3 — Set up SSH key authentication

```powershell
.\powershell\Setup-AnsibleSSH.ps1
```

This generates `~/.ssh/lab_rsa` and installs the public key on both VMs.

### Step 4 — Run Ansible (from WSL2 or Linux)

```bash
# Copy SSH key into WSL
cp "/mnt/c/Users/<user profile>/.ssh/lab_rsa" ~/.ssh/lab_rsa
chmod 600 ~/.ssh/lab_rsa

# Point Ansible at the repo config when running from a Windows-mounted path
export ANSIBLE_CONFIG=/mnt/c/Users/<user profile>/OneDrive/Documents/01_VS_CODE/rke2-lab/ansible.cfg

# Install Ansible if needed
pip install ansible

# Install required Ansible Galaxy collections
ansible-galaxy collection install -r requirements.yml

# Test connectivity
ansible all -m ping

# Run the full playbook
ansible-playbook site.yml
```

Total runtime: approximately **20–30 minutes** (mostly RKE2 + Rancher + ArgoCD startup).

### Step 5 — Access Rancher

`rancher.lab` is published through Pi-hole DNS for the lab network and is also added to `/etc/hosts` on the lab VMs by Ansible.

Open: **https://rancher.lab**
Bootstrap password: `Admin1234!` (change in `group_vars/all.yml` before deploying!)

### Step 6 — Access ArgoCD

Open: **http://argocd.lab**

| Field | Value |
|---|---|
| Username | `admin` |
| Password | Printed at the end of the Ansible run — or retrieve manually: |

```bash
kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
  get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

> Change the password after first login via **User Info → Update Password**, then delete the `argocd-initial-admin-secret` secret.

### ArgoCD local widget user

The Ansible role also creates a local ArgoCD user named `homepage` with `login` and `apiKey` enabled and maps it to the built-in readonly role.

Set a password for that user after deployment:

```bash
argocd login argocd.lab --username admin --insecure
argocd account update-password \
  --account homepage \
  --current-password "<homepage user's current password if already set>" \
  --new-password "<new homepage password>"
```

Generate a token for Homepage after the password is set:

```bash
argocd login argocd.lab --username homepage --insecure
argocd account generate-token --account homepage
```

Use that token in your Homepage ArgoCD widget configuration.

### Step 7 — Access Pi-hole

Open: **http://192.168.100.10:8080/admin**
Password: `Admin1234!` (change `pihole_web_password` in `group_vars/all.yml`)

Pi-hole is automatically configured as the DNS server for both lab VMs. To use it from **Windows or WSL** and get full `*.lab` resolution without a hosts file:

**Windows:** Control Panel → Network adapter → IPv4 → set Preferred DNS to `192.168.100.10`

**WSL2:**
```bash
# /etc/resolv.conf (prevent WSL from overwriting it first)
echo '[network]' | sudo tee /etc/wsl.conf
echo 'generateResolvConf = false' | sudo tee -a /etc/wsl.conf

sudo tee /etc/resolv.conf <<EOF
nameserver 192.168.100.10
nameserver 1.1.1.1
search lab
EOF
```

Pi-hole resolves these `lab` names out of the box:

| Hostname | IP |
|---|---|
| `lab-devtools` / `lab-devtools.lab` | 192.168.100.10 |
| `lab-k8s` / `lab-k8s.lab` | 192.168.100.20 |
| `rancher.lab` | 192.168.100.20 |
| `argocd.lab` | 192.168.100.20 |

> Add new Pi-hole DNS names in `group_vars/all.yml` under `pihole_dns_records`, then re-run `--tags pihole`.
>
> `grafana.lab` and `sample-app.lab` are currently added only to `/etc/hosts` on the lab VMs by `roles/common/tasks/main.yml`.

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
```

On the k8s node, Kubernetes is pre-configured to mirror pulls through the registry.

## Running Individual Roles

```bash
# Only configure devtools
ansible-playbook site.yml --tags devtools,registry

# Only deploy Pi-hole (and reconfigure DNS on all hosts)
ansible-playbook site.yml --tags pihole

# Only deploy RKE2 (skip Rancher + ArgoCD)
ansible-playbook site.yml --tags rke2

# Re-run just Rancher
ansible-playbook site.yml --tags rancher

# Re-run just ArgoCD
ansible-playbook site.yml --tags argocd

# Re-run just the registry setup
ansible-playbook site.yml --tags registry
```

## Customisation

All versions and IPs are in `group_vars/all.yml`:

| Variable | Default | Description |
|---|---|---|
| `rke2_version` | v1.34.5+rke2r1 | RKE2 / Kubernetes version |
| `rancher_version` | 2.13.3 | Rancher Manager version |
| `cert_manager_version` | v1.19.4 | cert-manager version |
| `helm_version` | v4.1.3 | Helm version |
| `kubectl_version` | v1.34.5 | kubectl version |
| `k9s_version` | v0.50.18 | k9s version on `lab-devtools` |
| `argocd_cli_version` | v2.14.20 | ArgoCD CLI version on `lab-devtools` |
| `kubeseal_version` | 0.28.0 | kubeseal version on `lab-devtools` |
| `rancher_hostname` | rancher.lab | Rancher ingress hostname |
| `rancher_bootstrap_password` | Admin1234! | **Change this!** |
| `argocd_chart_version` | 7.7.3 | ArgoCD Helm chart version |
| `argocd_hostname` | argocd.lab | ArgoCD ingress hostname |
| `pihole_version` | 2025.03.0 | Pi-hole container tag |
| `pihole_web_port` | 8080 | Pi-hole web UI port |
| `pihole_web_password` | Admin1234! | **Change this!** |
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

**ArgoCD not reachable:**
```bash
kubectl get pods -n argocd
kubectl get ingress -n argocd
kubectl describe pod -n argocd -l app.kubernetes.io/name=argocd-server
```

**Pi-hole not resolving / port 53 in use:**
```bash
# On lab-devtools
sudo systemctl status lab-pihole
sudo docker compose -f /opt/pihole/docker-compose.yml logs
# Test DNS resolution
dig @192.168.100.10 rancher.lab
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
