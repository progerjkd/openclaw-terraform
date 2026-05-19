# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Terraform configuration to deploy **OpenClaw** (an AI assistant gateway) on AWS. It provisions an ARM64 EC2 spot instance (t4g.small), a persistent 30 GB EBS data volume, VPC/networking, IAM roles, and CloudWatch logging. A set of shell scripts wraps the AWS CLI for day-to-day start/stop operations.

## Common Commands

```bash
# Initial deploy
cp terraform.tfvars.example terraform.tfvars   # then fill in secrets
terraform init
terraform plan
terraform apply

# Start / stop instance (preferred over terraform)
./start.sh         # scales spot fleet to 1 and reattaches EBS
./stop.sh          # scales spot fleet to 0
./status.sh        # shows fleet state and current public IP
./attach-volume.sh # reattach EBS after a spot interruption

# Get connection info
terraform output -raw ssh_command
terraform output -raw ssh_tunnel_command
terraform output -raw gateway_token

# On the remote instance
tail -f /var/log/openclaw-bootstrap.log           # bootstrap progress
docker compose -f /opt/openclaw/docker-compose.yml ps
docker compose -f /opt/openclaw/docker-compose.yml logs -f openclaw-gateway
```

## Architecture

### Two deployment modes controlled by `use_spot_instances` (default: `true`)

| Mode | Resource | Notes |
|------|----------|-------|
| Spot | `aws_spot_fleet_request` + `aws_launch_template` | ~$3.60/mo; `target_capacity` managed by scripts, not Terraform |
| On-demand | `aws_instance` | ~$12/mo; EBS attached via `aws_volume_attachment` |

### EBS volume strategy
- **Root volume** (`/dev/sda1`, 20 GB, `delete_on_termination=true`) — OS + Docker daemon (moved to data volume)
- **Data volume** (`vol-*`, 30 GB, persistent) — mounted at `/opt/openclaw-data`; holds Docker/containerd roots, OpenClaw config, workspace, and channel credentials

Because spot instances terminate on stop/start, the data volume is **never** attached via Terraform for spot mode. Instead `attach-volume.sh` (and `user-data.sh` on boot) attach it via the AWS CLI.

### `user-data.sh` bootstrap flow (runs once on first boot, ~10–15 min)
1. Create 2 GB swap (t4g.small has only 2 GB RAM)
2. Install Docker, AWS CLI, awscli, unattended-upgrades
3. Self-attach the data EBS volume using IMDSv2 + the instance's IAM role
4. Move Docker and containerd data roots to `/opt/openclaw-data` so the root volume isn't exhausted
5. Clone the OpenClaw repo to `/opt/openclaw`, patch `Dockerfile` to set `NODE_OPTIONS=--max-old-space-size=1536`
6. Write `.env` and `docker-compose.override.yml` from Terraform template variables
7. `docker build` + `docker compose up -d openclaw-gateway`
8. Optionally install and authenticate Tailscale
9. Install CloudWatch agent (logs → `/aws/ec2/openclaw`)

### Key paths on the instance
| Path | Purpose |
|------|---------|
| `/opt/openclaw` | OpenClaw git repo + Docker Compose |
| `/opt/openclaw-data/config/openclaw.json` | Gateway config (allowInsecureAuth enabled) |
| `/opt/openclaw-data/config/.env` | All secrets/tokens |
| `/opt/openclaw-data/docker` | Docker image/layer storage |
| `/var/log/openclaw-bootstrap.log` | Full bootstrap log |

### `ignore_changes = [target_capacity]`
The spot fleet's `target_capacity` is intentionally ignored by Terraform because `start.sh` / `stop.sh` modify it out-of-band. Running `terraform apply` will not fight the scripts.

## `terraform.tfvars` Key Variables

| Variable | Required | Notes |
|----------|----------|-------|
| `ssh_public_key` | Yes | Your public key content |
| `anthropic_api_key` | Recommended | For Claude models |
| `allowed_ssh_cidrs` | Security | Default is `0.0.0.0/0` — restrict to your IP |
| `use_existing_vpc` | Optional | Set `existing_vpc_id` + `existing_subnet_id` if true |
| `tailscale_auth_key` | Optional | Enables Tailscale VPN for team access |

## Accessing the Control UI

The gateway binds to `lan` (all interfaces) on port 18789 but is **not** in the security group — accessible only via SSH tunnel or Tailscale:

```bash
ssh -fN -L 18789:localhost:18789 ubuntu@<public-ip>
# Then open http://localhost:18789/
# Enter the token from: terraform output -raw gateway_token
```
