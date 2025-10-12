# OCI Setup Guide for BNGdrasil

**Complete step-by-step guide to deploy BNGdrasil infrastructure on Oracle Cloud Infrastructure using Terraform**

---

## 📋 Table of Contents

1. [Prerequisites](#prerequisites)
2. [OCI Account Setup](#oci-account-setup)
3. [Local Environment Setup](#local-environment-setup)
4. [Terraform Configuration](#terraform-configuration)
5. [Infrastructure Deployment](#infrastructure-deployment)
6. [Verification and Testing](#verification-and-testing)
7. [Next Steps](#next-steps)

---

## Prerequisites

### Required Accounts

- **2 OCI accounts** (for Free Tier maximization):
  - Account 1: Chuncheon region (ap-chuncheon-1)
  - Account 2: Osaka region (ap-osaka-1)
- **Email addresses**: 2 different emails for account registration
- **Credit card**: For account verification (no charges within Free Tier)

### Required Software

- **Terraform** >= 1.0
- **Git**
- **SSH client**
- **Text editor** (vim, VS Code, etc.)

---

## OCI Account Setup

### Step 1: Create OCI Accounts

#### Account 1 - Chuncheon Region

1. Go to [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/)
2. Click **Start for free**
3. Fill in registration information:
   - Email: `your-email-1@example.com`
   - Country/Territory: **South Korea**
   - Choose **Home Region**: **South Korea Central (Chuncheon)**
4. Complete email verification
5. Enter credit card information (for verification only)
6. Complete account creation

#### Account 2 - Osaka Region

1. Repeat the process with a different email
2. Registration information:
   - Email: `your-email-2@example.com`
   - Country/Territory: **Japan**
   - Choose **Home Region**: **Japan East (Osaka)**
3. Complete account creation

### Step 2: Verify Free Tier Resources

Login to each account and verify:

```
Resources Available per Account:
- ARM Ampere A1 Compute: 4 OCPUs, 24 GB RAM
- Block Storage: 200 GB
- Outbound Data Transfer: 10 TB/month
- Load Balancer: 1 instance (10 Mbps)
```

### Step 3: Create Compartments

For each account:

1. Navigate to **Identity & Security** → **Compartments**
2. Click **Create Compartment**
3. Enter:
   - Name: `bngdrasil-compartment`
   - Description: `BNGdrasil infrastructure resources`
4. Click **Create Compartment**
5. **Copy the Compartment OCID** (you'll need this later)

### Step 4: Generate API Keys

#### For Chuncheon Account:

```bash
# Create .oci directory
mkdir -p ~/.oci
cd ~/.oci

# Generate API key pair
openssl genrsa -out chuncheon_api_key.pem 2048
openssl rsa -pubout -in chuncheon_api_key.pem -out chuncheon_api_key_public.pem

# Set proper permissions
chmod 600 chuncheon_api_key.pem
```

#### For Osaka Account:

```bash
cd ~/.oci

# Generate API key pair
openssl genrsa -out osaka_api_key.pem 2048
openssl rsa -pubout -in osaka_api_key.pem -out osaka_api_key_public.pem

# Set proper permissions
chmod 600 osaka_api_key.pem
```

### Step 5: Upload API Keys to OCI Console

#### For Chuncheon Account:

1. Login to OCI Console (Chuncheon account)
2. Click **Profile icon** → **User Settings**
3. In left sidebar, click **API Keys**
4. Click **Add API Key**
5. Select **Paste Public Key**
6. Paste content from `chuncheon_api_key_public.pem`:
   ```bash
   cat ~/.oci/chuncheon_api_key_public.pem
   ```
7. Click **Add**
8. **Copy the Configuration File Preview** - you'll need:
   - `user` OCID
   - `fingerprint`
   - `tenancy` OCID
   - `region`

#### For Osaka Account:

Repeat the same process for the Osaka account with `osaka_api_key_public.pem`

### Step 6: Create SSH Key for VM Access

```bash
# Generate SSH key pair for VM access
ssh-keygen -t rsa -b 4096 -f ~/.ssh/bngdrasil_vm_key

# Don't set a passphrase (press Enter twice)

# Copy public key content
cat ~/.ssh/bngdrasil_vm_key.pub
# Save this output - you'll paste it in terraform.tfvars
```

---

## Local Environment Setup

### Step 1: Install Terraform

#### macOS:

```bash
brew install terraform
```

#### Linux (Ubuntu/Debian):

```bash
wget -O- https://apt.releases.hashicorp.com/gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update
sudo apt install terraform
```

#### Verify Installation:

```bash
terraform version
# Should output: Terraform v1.x.x
```

### Step 2: Install Additional Tools

```bash
# macOS
brew install jq

# Linux
sudo apt install jq
```

### Step 3: Clone BNGdrasil Repository

```bash
cd ~/projects  # Or your preferred directory
git clone https://github.com/BNGdrasil/BNGdrasil.git
cd BNGdrasil/infra
```

---

## Terraform Configuration

### Step 1: Create terraform.tfvars

```bash
cd ~/projects/BNGdrasil/infra

# Copy example file
cp terraform.tfvars.example terraform.tfvars

# Edit the file
vim terraform.tfvars
```

### Step 2: Fill in terraform.tfvars

Open `terraform.tfvars` and fill in the following:

```hcl
# ========================================
# Chuncheon Region (Account 1)
# ========================================
tenancy_ocid_chuncheon     = "ocid1.tenancy.oc1..aaaaaaaa..."
# ↑ From OCI Console: Profile → Tenancy → OCID

user_ocid_chuncheon        = "ocid1.user.oc1..aaaaaaaa..."
# ↑ From OCI Console: Profile → User Settings → OCID

fingerprint_chuncheon      = "xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx"
# ↑ From API Keys section after uploading public key

private_key_path_chuncheon = "~/.oci/chuncheon_api_key.pem"
# ↑ Path to your private key file

region_chuncheon           = "ap-chuncheon-1"
# ↑ Region identifier

compartment_id_chuncheon   = "ocid1.compartment.oc1..aaaaaaaa..."
# ↑ From Compartments section

# ========================================
# Osaka Region (Account 2)
# ========================================
tenancy_ocid_osaka     = "ocid1.tenancy.oc1..aaaaaaaa..."
user_ocid_osaka        = "ocid1.user.oc1..aaaaaaaa..."
fingerprint_osaka      = "yy:yy:yy:yy:yy:yy:yy:yy:yy:yy:yy:yy:yy:yy:yy:yy"
private_key_path_osaka = "~/.oci/osaka_api_key.pem"
region_osaka           = "ap-osaka-1"
compartment_id_osaka   = "ocid1.compartment.oc1..aaaaaaaa..."

# ========================================
# General Configuration
# ========================================
instance_shape = "VM.Standard.A1.Flex"
# ↑ ARM-based instance type (Free Tier eligible)

ssh_public_key = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC..."
# ↑ Paste output from: cat ~/.ssh/bngdrasil_vm_key.pub

domain_name    = "bnbong.xyz"
# ↑ Your domain name (or change to your own)

# ========================================
# Service Configuration
# ========================================
postgres_user     = "bnbong"

postgres_password = "MySecurePassword123!@#"
# ↑ CHANGE THIS! Minimum 16 characters recommended

jwt_secret_key    = "your-super-secret-jwt-key-min-32-chars-change-this"
# ↑ CHANGE THIS! Minimum 32 characters required
```

### Step 3: Verify Configuration

```bash
# Check that your API keys exist
ls -la ~/.oci/

# Should show:
# chuncheon_api_key.pem
# chuncheon_api_key_public.pem
# osaka_api_key.pem
# osaka_api_key_public.pem
```

---

## Infrastructure Deployment

### Step 1: Initialize Terraform

```bash
cd ~/projects/BNGdrasil/infra

# Initialize Terraform (downloads provider plugins)
make init

# Or manually:
terraform init
```

**Expected Output:**
```
Initializing the backend...
Initializing provider plugins...
- Finding oracle/oci versions matching "~> 5.0"...
- Installing oracle/oci v5.x.x...

Terraform has been successfully initialized!
```

### Step 2: Validate Configuration

```bash
# Validate Terraform files
make validate

# Or manually:
terraform validate
```

### Step 3: Plan Deployment

```bash
# Generate and review execution plan
make plan

# Or manually:
terraform plan
```

**Review the Plan:**
- Check that it will create **6 VMs** (3 in Chuncheon, 3 in Osaka)
- Verify **VCN and subnet** configurations
- Confirm **Security Lists** settings
- Review **OCPU and RAM** allocations

### Step 4: Deploy Infrastructure

```bash
# Apply the Terraform configuration
make apply

# Or manually:
terraform apply
```

When prompted:
```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes  ← Type 'yes' and press Enter
```

**Deployment Time:** Approximately 10-15 minutes

**What's Being Created:**

1. **Chuncheon Region:**
   - VCN (Virtual Cloud Network)
   - Public Subnet (10.0.1.0/24)
   - Private Subnet (10.0.2.0/24)
   - Internet Gateway
   - NAT Gateway
   - Security Lists
   - VM1: Frontend (1 OCPU, 6GB RAM)
   - VM2: Core APIs (1 OCPU, 6GB RAM)
   - VM3: Wegis AI (2 OCPU, 12GB RAM)

2. **Osaka Region:**
   - VCN
   - Private Subnet (10.1.2.0/24)
   - NAT Gateway
   - Security Lists
   - VM4: Database (1 OCPU, 6GB RAM)
   - VM5: Monitoring (2 OCPU, 12GB RAM)
   - VM6: Backup (1 OCPU, 6GB RAM)

---

## Verification and Testing

### Step 1: Check Terraform Outputs

```bash
# Display all outputs
make output

# Or manually:
terraform output
```

**Expected Output:**
```
vm1_public_ip  = "129.154.XXX.XXX"
vm2_public_ip  = "129.154.XXX.XXX"
vm3_private_ip = "10.0.2.5"
vm4_private_ip = "10.1.2.5"
vm5_private_ip = "10.1.2.6"
vm6_private_ip = "10.1.2.7"

ssh_connections = {
  "vm1" = "ssh ubuntu@129.154.XXX.XXX"
  "vm2" = "ssh ubuntu@129.154.XXX.XXX"
  "vm3" = "ssh -J ubuntu@129.154.XXX.XXX ubuntu@10.0.2.5"
  ...
}
```

### Step 2: Test SSH Connections

#### Test VM1 (Public):

```bash
# Save VM1 public IP
export VM1_IP=$(terraform output -raw vm1_public_ip)

# Test SSH connection
ssh -i ~/.ssh/bngdrasil_vm_key ubuntu@$VM1_IP

# Once connected:
ubuntu@vm1:~$ hostname
# Should output: vm1

ubuntu@vm1:~$ docker ps
# Should show running containers

ubuntu@vm1:~$ exit
```

#### Test VM2 (Public):

```bash
# Save VM2 public IP
export VM2_IP=$(terraform output -raw vm2_public_ip)

# Test SSH connection
ssh -i ~/.ssh/bngdrasil_vm_key ubuntu@$VM2_IP

# Check services
ubuntu@vm2:~$ docker ps
ubuntu@vm2:~$ curl http://localhost:8000/health
ubuntu@vm2:~$ exit
```

#### Test VM3 (Private via Jump Host):

```bash
# Connect via VM2 as jump host
ssh -i ~/.ssh/bngdrasil_vm_key -J ubuntu@$VM2_IP ubuntu@10.0.2.5

# Check Wegis service
ubuntu@vm3:~$ docker ps
ubuntu@vm3:~$ exit
```

### Step 3: Verify Services

```bash
# Check all VM statuses
make health

# View VM1 logs
make logs-vm1

# View VM2 logs
make logs-vm2
```

### Step 4: Verify in OCI Console

1. **Chuncheon Account:**
   - Go to **Compute** → **Instances**
   - Should see: vm1-frontend-proxy, vm2-core-apis, vm3-wegis-ai
   - Check that all are **Running**

2. **Osaka Account:**
   - Go to **Compute** → **Instances**
   - Should see: vm4-database, vm5-monitoring, vm6-backup-dr
   - Check that all are **Running**

---

## Next Steps

### 1. Configure SSH Config (Optional but Recommended)

Add to `~/.ssh/config`:

```
# BNGdrasil VMs
Host bnbong-vm1
    HostName 129.154.XXX.XXX  # Replace with actual IP
    User ubuntu
    IdentityFile ~/.ssh/bngdrasil_vm_key

Host bnbong-vm2
    HostName 129.154.XXX.XXX  # Replace with actual IP
    User ubuntu
    IdentityFile ~/.ssh/bngdrasil_vm_key

Host bnbong-vm3
    HostName 10.0.2.5
    User ubuntu
    IdentityFile ~/.ssh/bngdrasil_vm_key
    ProxyJump bnbong-vm2
```

Now you can connect with:
```bash
ssh bnbong-vm1
ssh bnbong-vm2
ssh bnbong-vm3
```

### 2. Deploy Applications

See [DEPLOYMENT.md](../DEPLOYMENT.md) for application deployment instructions.

### 3. Configure DNS

If you have a domain, configure DNS records:

```
A     bnbong.xyz          → <VM1_PUBLIC_IP>
A     api.bnbong.xyz      → <VM2_PUBLIC_IP>
A     playground.bnbong.xyz → <VM1_PUBLIC_IP>
```

### 4. Setup Monitoring

Access Grafana via SSH tunnel:

```bash
# Create tunnel to VM5
ssh -L 3000:localhost:3000 -J ubuntu@<VM2_IP> ubuntu@<VM5_PRIVATE_IP>

# Open browser to:
http://localhost:3000

# Login: admin / admin
```

---

## Troubleshooting

### Issue: Terraform can't find OCI provider

**Solution:**
```bash
rm -rf .terraform
terraform init
```

### Issue: "Error 401: The required information to complete authentication was not provided"

**Solution:** Check that API keys are correctly configured:
```bash
# Verify fingerprint matches
cat ~/.oci/chuncheon_api_key_public.pem | openssl rsa -pubin -outform DER | openssl md5 -c

# Compare with fingerprint in OCI Console
```

### Issue: "Out of capacity" when creating instances

**Solution:** OCI Free Tier resources may be temporarily unavailable. Try:
1. Wait 30 minutes and try again
2. Try a different Availability Domain
3. Contact OCI support for Free Tier availability

### Issue: Can't SSH to VMs

**Solution:**
```bash
# Check Security Lists in OCI Console
# Ensure port 22 is open for your IP

# Check that you're using correct key
ssh -i ~/.ssh/bngdrasil_vm_key -v ubuntu@<VM_IP>
```

### Issue: Services not starting on VMs

**Solution:**
```bash
# SSH to VM
ssh ubuntu@<VM_IP>

# Check systemd service
sudo systemctl status bnbong-vm1.service

# View logs
sudo journalctl -u bnbong-vm1.service -f

# Restart service
sudo systemctl restart bnbong-vm1.service
```

---

## Resource Management

### View Current Resources

```bash
# List all managed resources
terraform state list

# Show detailed resource info
make show

# Resource summary
make summary
```

### Modify Resources

To change VM configurations, edit `infra/variables.tf`:

```hcl
variable "vm_configs" {
  default = {
    vm1 = {
      ocpus = 1  # Change to 2 to increase CPU
      memory_in_gbs = 6  # Change to 12 to increase RAM
      ...
    }
  }
}
```

Then apply changes:
```bash
terraform plan
terraform apply
```

### Destroy Infrastructure

**⚠️ WARNING: This will delete ALL resources!**

```bash
# Review what will be destroyed
terraform plan -destroy

# Destroy all resources
make destroy

# Confirm with: yes
```

---

## Cost Monitoring

### Check Free Tier Usage

1. Login to each OCI account
2. Go to **Governance & Administration** → **Cost Management** → **Cost Analysis**
3. View **Cost and Usage Reports**

**Free Tier Limits (per account):**
- ✅ ARM A1: 4 OCPU, 24GB RAM (Always Free)
- ✅ Block Storage: 200GB (Always Free)
- ✅ Outbound Traffic: 10TB/month (Always Free)
- ⚠️ Additional resources will incur charges

### Set Up Budget Alerts

1. Go to **Governance & Administration** → **Budgets**
2. Create **Budget Alert**
3. Set threshold: $1.00
4. Add your email for notifications

---

## Additional Resources

- [Terraform OCI Provider Docs](https://registry.terraform.io/providers/oracle/oci/latest/docs)
- [OCI Free Tier FAQ](https://www.oracle.com/cloud/free/faq/)
- [BNGdrasil Architecture Overview](../README.md)
- [Application Deployment Guide](../DEPLOYMENT.md)

---

## Summary Checklist

- [  ] Created 2 OCI accounts (Chuncheon, Osaka)
- [ ] Generated API keys for both accounts
- [ ] Uploaded public keys to OCI Console
- [ ] Created SSH key for VM access
- [ ] Installed Terraform locally
- [ ] Configured `terraform.tfvars`
- [ ] Ran `terraform init`
- [ ] Ran `terraform plan` (reviewed resources)
- [ ] Ran `terraform apply` (deployed infrastructure)
- [ ] Verified all 6 VMs are running
- [ ] Tested SSH connections to VMs
- [ ] Checked services are running
- [ ] Configured DNS (optional)
- [ ] Set up monitoring access
