# OpenClaw Terraform — AWS Deployment

Deploy OpenClaw on AWS EC2 (t4g.small ARM64) with Docker, optional Tailscale VPN for team access, and persistent data volumes.

## Architecture

```
┌─────────────────────────────────────────────────┐
│              AWS t4g.small (ARM64)              │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │  Docker: OpenClaw Gateway (port 18789)    │  │
│  │  • WhatsApp / Telegram / Discord / Slack  │  │
│  │  • Control UI (private)                   │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  ┌──────────────┐   ┌────────────────────────┐  │
│  │  EBS Root    │   │  EBS Data Volume       │  │
│  │  20 GB (OS)  │   │  30 GB (config + data) │  │
│  └──────────────┘   └────────────────────────┘  │
│                                                 │
│  Tailscale VPN (optional) ← Team access         │
│  SSH (port 22) ← Admin access                   │
└─────────────────────────────────────────────────┘

Team interaction:
  PM   → WhatsApp/Telegram app (no VPN needed)
  Dev1 → Telegram/Slack app   (no VPN needed)
  Dev2 → Discord/Slack app    (no VPN needed)

Admin tasks (Control UI):
  → SSH tunnel or Tailscale VPN
```

## Cost Estimate

| Resource             | Monthly Cost |
|----------------------|-------------|
| EC2 t4g.small (24/7) | ~$12.26     |
| EBS root (20 GB gp3) | ~$1.60      |
| EBS data (30 GB gp3) | ~$2.40      |
| Data transfer (est.)  | ~$1.00      |
| Tailscale (3 users)   | Free        |
| **Total**            | **~$17/mo** |

## Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.0 installed
- SSH key pair (or generate one)
- (Optional) Tailscale account with auth key

## Quick Start

```bash
cd openclaw-terraform

# 1. Copy and edit variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values (API keys, SSH key, etc.)

# 2. Initialize Terraform
terraform init

# 3. Preview changes
terraform plan

# 4. Deploy
terraform apply

# 5. Get connection info
terraform output ssh_command
terraform output ssh_tunnel_command
terraform output -raw gateway_token
```

## Post-Deployment Setup

### 1. Wait for Bootstrap (~10-15 minutes)

The instance runs a bootstrap script on first launch. Monitor progress:

```bash
# SSH into instance
ssh -i ~/.ssh/openclaw-key.pem ubuntu@$(terraform output -raw instance_public_ip)

# Watch bootstrap log
tail -f /var/log/openclaw-bootstrap.log

# Check Docker status
docker compose -f /opt/openclaw/docker-compose.yml ps
```

### 2. Access Control UI

```bash
# Option A: SSH tunnel (free)
ssh -L 18789:localhost:18789 -i ~/.ssh/openclaw-key.pem ubuntu@$(terraform output -raw instance_public_ip)
# Then browse to http://localhost:18789/

# Option B: Tailscale (if enabled)
# Browse to http://<tailscale-ip>:18789/
```

Enter your gateway token in Settings (retrieve with `terraform output -raw gateway_token`).

### 3. Configure Channels

```bash
# SSH into instance first, then:

# WhatsApp (scan QR code)
docker compose -f /opt/openclaw/docker-compose.yml run --rm openclaw-cli channels login

# Telegram (if token not set in terraform.tfvars)
docker compose -f /opt/openclaw/docker-compose.yml run --rm openclaw-cli channels add --channel telegram --token "BOT_TOKEN"

# Discord
docker compose -f /opt/openclaw/docker-compose.yml run --rm openclaw-cli channels add --channel discord --token "BOT_TOKEN"
```

### 4. Share with Team

Once channels are configured:
- Share the **WhatsApp bot phone number** or **Telegram bot @username** with your PM and devs
- They message the bot directly from their apps — no VPN or special setup needed

## Team Access

| Who  | How                        | VPN Needed? |
|------|----------------------------|-------------|
| PM   | WhatsApp/Telegram on phone | No          |
| Dev1 | Telegram/Slack on laptop   | No          |
| Dev2 | Discord/Slack on laptop    | No          |
| Admin| Control UI (browser)       | Yes (SSH tunnel or Tailscale) |

## Using an Existing VPC

If your AWS account already has a VPC:

```hcl
# terraform.tfvars
use_existing_vpc   = true
existing_vpc_id    = "vpc-0abc123def456789"
existing_subnet_id = "subnet-0abc123def456789"
```

## Operations

### View Logs
```bash
# On instance
docker compose -f /opt/openclaw/docker-compose.yml logs -f openclaw-gateway

# Or via CloudWatch
aws logs tail /aws/ec2/openclaw --follow
```

### Restart OpenClaw
```bash
docker compose -f /opt/openclaw/docker-compose.yml restart openclaw-gateway
```

### Update OpenClaw
```bash
cd /opt/openclaw
git pull
docker compose build
docker compose up -d openclaw-gateway
```

### Backup Data
```bash
# On instance
tar -czf /tmp/openclaw-backup-$(date +%Y%m%d).tar.gz /opt/openclaw-data/

# Copy to local machine
scp -i ~/.ssh/openclaw-key.pem ubuntu@<ip>:/tmp/openclaw-backup-*.tar.gz ./
```

### Stop/Start Instance (Save Costs)

```bash
# Stop (EBS charges still apply ~$4/mo)
aws ec2 stop-instances --instance-ids $(terraform output -raw instance_id)

# Start
aws ec2 start-instances --instance-ids $(terraform output -raw instance_id)
```

> Note: Public IP changes on stop/start unless you set `allocate_elastic_ip = true`.
> WhatsApp sessions may need re-authentication after extended downtime.

## Destroy

```bash
terraform destroy
```

> Warning: This deletes everything including the data volume. Back up first!

## File Structure

```
openclaw-terraform/
├── main.tf                    # AWS resources (EC2, VPC, SG, EBS, IAM)
├── variables.tf               # Input variable definitions
├── outputs.tf                 # Output values (IPs, commands, token)
├── user-data.sh               # EC2 bootstrap script
├── terraform.tfvars.example   # Example configuration (commit this)
├── terraform.tfvars           # Your configuration (DO NOT commit)
├── .gitignore                 # Excludes secrets and state
└── README.md                  # This file
```

## Security Notes

- Gateway binds to `127.0.0.1` — not publicly accessible
- SSH access restricted to `allowed_ssh_cidrs` (change from `0.0.0.0/0`!)
- IMDSv2 enforced (prevents SSRF token theft)
- EBS volumes encrypted at rest
- Docker runs as non-root user (uid 1000)
- Automatic security updates enabled
- No RBAC in OpenClaw — all users with gateway access have full permissions
