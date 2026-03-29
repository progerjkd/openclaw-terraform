#!/bin/bash
#
# OpenClaw Bootstrap Script for AWS EC2 (ARM64)
# Automatically sets up Docker, OpenClaw, and optional Tailscale
#

set -e  # Exit on any error

# Log all output
exec > >(tee /var/log/openclaw-bootstrap.log)
exec 2>&1

echo "================================================"
echo "OpenClaw Bootstrap Script Started"
echo "Timestamp: $(date)"
echo "Architecture: $(uname -m)"
echo "================================================"

# Add swap space (required for Docker build on t4g.small - 2GB RAM is not enough)
echo "[0/10] Setting up swap space..."
fallocate -l 2G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
echo "Swap enabled: $(free -h | grep Swap)"

# Update system
echo "[1/10] Updating system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# Install essential packages
echo "[2/10] Installing essential packages..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl \
    git \
    ca-certificates \
    gnupg \
    lsb-release \
    htop \
    vim \
    unattended-upgrades

# Setup unattended upgrades for security (non-interactive)
echo "[3/10] Configuring automatic security updates..."
echo 'Unattended-Upgrade::Allowed-Origins {
    "$${distro_id}:$${distro_codename}";
    "$${distro_id}:$${distro_codename}-security";
    "$${distro_id}ESMApps:$${distro_codename}-apps-security";
    "$${distro_id}ESM:$${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";' > /etc/apt/apt.conf.d/50unattended-upgrades-local

# Install Docker
echo "[4/10] Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu
    systemctl enable docker
    systemctl start docker
    echo "Docker installed successfully"
else
    echo "Docker already installed"
fi

# Verify Docker ARM64 support
echo "Docker version: $(docker --version)"
echo "Docker info:"
docker info | grep -i architecture

# Setup data volume
echo "[5/10] Setting up data volume..."
DATA_MOUNT="/opt/openclaw-data"

# On Nitro instances, /dev/sdf maps to /dev/nvme*n1 but the exact name varies.
# Find the EBS data volume by excluding any disk that has mounted partitions.
echo "Block device layout:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# Check if data volume is already mounted from a previous run
if findmnt -rn "$DATA_MOUNT" &>/dev/null; then
    DATA_DEVICE=$(findmnt -rn -o SOURCE "$DATA_MOUNT")
    echo "Data volume already mounted: $DATA_DEVICE at $DATA_MOUNT"
else
    DATA_DEVICE=""
    ATTEMPTS=0
    MAX_ATTEMPTS=30
    while [ -z "$DATA_DEVICE" ] && [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
        for dev in /dev/nvme*n1; do
            [ -b "$dev" ] || continue
            # Skip any disk that has children (partitions) mounted somewhere
            if lsblk -ln "$dev" | awk 'NR>1 && $NF ~ /^\// {found=1} END {exit !found}' 2>/dev/null; then
                continue
            fi
            # Skip if the disk itself is mounted
            if findmnt -rn -S "$dev" &>/dev/null; then
                continue
            fi
            DATA_DEVICE="$dev"
            break
        done
        if [ -z "$DATA_DEVICE" ]; then
            ATTEMPTS=$((ATTEMPTS + 1))
            echo "Waiting for data volume to attach... (attempt $ATTEMPTS/$MAX_ATTEMPTS)"
            sleep 5
        fi
    done

    if [ -z "$DATA_DEVICE" ]; then
        echo "ERROR: Data volume not found after $MAX_ATTEMPTS attempts. Using root filesystem."
        mkdir -p "$DATA_MOUNT"
    else
        echo "Found data device: $DATA_DEVICE"

        # Create filesystem if needed
        if ! blkid "$DATA_DEVICE" &> /dev/null; then
            echo "Creating filesystem on $DATA_DEVICE..."
            mkfs.ext4 "$DATA_DEVICE"
        fi

        # Mount
        mkdir -p "$DATA_MOUNT"
        mount "$DATA_DEVICE" "$DATA_MOUNT"

        # Add to fstab for persistence
        DEVICE_UUID=$(blkid -s UUID -o value "$DATA_DEVICE")
        if ! grep -q "$DEVICE_UUID" /etc/fstab; then
            echo "UUID=$DEVICE_UUID $DATA_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
        fi
    fi
fi

# Set permissions
chown -R ubuntu:ubuntu "$DATA_MOUNT"

# Clone OpenClaw repository
echo "[6/10] Cloning OpenClaw repository..."
OPENCLAW_DIR="/opt/openclaw"
if [ -d "$OPENCLAW_DIR/.git" ]; then
    echo "OpenClaw repository already exists, pulling latest..."
    cd "$OPENCLAW_DIR"
    git pull || true
else
    rm -rf "$OPENCLAW_DIR"
    git clone ${openclaw_repo_url} "$OPENCLAW_DIR"
fi
chown -R ubuntu:ubuntu "$OPENCLAW_DIR"

# Create OpenClaw config directory
echo "[7/10] Creating OpenClaw configuration..."
CONFIG_DIR="$DATA_MOUNT/config"
WORKSPACE_DIR="$DATA_MOUNT/workspace"

mkdir -p "$CONFIG_DIR"
mkdir -p "$WORKSPACE_DIR"
chown -R 1000:1000 "$CONFIG_DIR" "$WORKSPACE_DIR"  # Docker runs as uid 1000

# Create gateway config (allowInsecureAuth for SSH tunnel access, filename must be openclaw.json)
cat > "$CONFIG_DIR/openclaw.json" <<'OCJSON'
{"gateway":{"controlUi":{"allowInsecureAuth":true,"dangerouslyDisableDeviceAuth":true}}}
OCJSON
chown 1000:1000 "$CONFIG_DIR/openclaw.json"

# Create .env file
cat > "$CONFIG_DIR/.env" <<EOF
# OpenClaw Configuration
# Generated by Terraform on $(date)

# Gateway Configuration
OPENCLAW_GATEWAY_TOKEN=${gateway_token}
OPENCLAW_GATEWAY_BIND=lan
OPENCLAW_GATEWAY_PORT=18789

# Paths
OPENCLAW_CONFIG_DIR=$CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$WORKSPACE_DIR

# AI Provider Keys
%{ if anthropic_api_key != "" ~}
ANTHROPIC_API_KEY=${anthropic_api_key}
%{ endif ~}
%{ if openai_api_key != "" ~}
OPENAI_API_KEY=${openai_api_key}
%{ endif ~}

# Channel Tokens
%{ if telegram_bot_token != "" ~}
TELEGRAM_BOT_TOKEN=${telegram_bot_token}
%{ endif ~}
%{ if discord_bot_token != "" ~}
DISCORD_BOT_TOKEN=${discord_bot_token}
%{ endif ~}

# Credential Storage
GOG_KEYRING_PASSWORD=$(openssl rand -base64 32)

# Node Environment
NODE_ENV=production
EOF

# Copy .env to OpenClaw directory
cp "$CONFIG_DIR/.env" "$OPENCLAW_DIR/.env"
chown ubuntu:ubuntu "$OPENCLAW_DIR/.env"

# Create docker-compose override for data volume paths
cat > "$OPENCLAW_DIR/docker-compose.override.yml" <<EOF
version: '3.8'

services:
  openclaw-gateway:
    environment:
      - OPENCLAW_CONFIG_DIR=$CONFIG_DIR
      - OPENCLAW_WORKSPACE_DIR=$WORKSPACE_DIR
    volumes:
      - $CONFIG_DIR:/home/node/.openclaw
      - $WORKSPACE_DIR:/home/node/.openclaw/workspace
    restart: unless-stopped
    command:
      [
        "node",
        "dist/index.js",
        "gateway",
        "--allow-unconfigured",
        "--bind",
        "lan",
        "--port",
        "18789",
      ]

  openclaw-cli:
    environment:
      - OPENCLAW_CONFIG_DIR=$CONFIG_DIR
      - OPENCLAW_WORKSPACE_DIR=$WORKSPACE_DIR
    volumes:
      - $CONFIG_DIR:/home/node/.openclaw
      - $WORKSPACE_DIR:/home/node/.openclaw/workspace
EOF

chown ubuntu:ubuntu "$OPENCLAW_DIR/docker-compose.override.yml"

# Build Docker image
echo "[8/10] Building OpenClaw Docker image (this may take 10-15 minutes)..."
cd "$OPENCLAW_DIR"
# Patch Dockerfile to increase Node.js heap size for low-RAM instances (t4g.small = 2GB)
sudo -u ubuntu sed -i '/^RUN pnpm build/i ENV NODE_OPTIONS="--max-old-space-size=1536"' Dockerfile
sudo -u ubuntu docker build -t openclaw:local -f Dockerfile .

# Start OpenClaw
echo "[9/10] Starting OpenClaw with Docker Compose..."
sudo -u ubuntu docker compose up -d openclaw-gateway

# Wait for gateway to start
echo "Waiting for OpenClaw gateway to start..."
sleep 10

# Check status
sudo -u ubuntu docker compose ps

# Install Tailscale (optional)
%{ if enable_tailscale ~}
echo "[10/10] Installing and configuring Tailscale..."
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh

    # Authenticate Tailscale
    %{ if tailscale_auth_key != "" ~}
    tailscale up --authkey=${tailscale_auth_key} --hostname=openclaw-aws
    echo "Tailscale IP: $(tailscale ip -4)"
    %{ else ~}
    echo "Tailscale installed but not authenticated (no auth key provided)"
    echo "Run manually: tailscale up"
    %{ endif ~}
else
    echo "Tailscale already installed"
fi
%{ else ~}
echo "[10/10] Tailscale installation skipped (not enabled)"
%{ endif ~}

# Create systemd service for monitoring and auto-restart
echo "Creating OpenClaw systemd service..."
cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$OPENCLAW_DIR
ExecStart=/usr/bin/docker compose up -d openclaw-gateway
ExecStop=/usr/bin/docker compose down
User=ubuntu
Group=ubuntu

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw.service

# Setup CloudWatch Logs (optional)
echo "Installing CloudWatch agent..."
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb
rm amazon-cloudwatch-agent.deb

# Create CloudWatch config
mkdir -p /opt/aws/amazon-cloudwatch-agent/etc/
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<EOF
{
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/openclaw-bootstrap.log",
            "log_group_name": "/aws/ec2/openclaw",
            "log_stream_name": "{instance_id}/bootstrap",
            "timezone": "UTC"
          },
          {
            "file_path": "/opt/openclaw-data/config/logs/*.log",
            "log_group_name": "/aws/ec2/openclaw",
            "log_stream_name": "{instance_id}/openclaw",
            "timezone": "UTC"
          }
        ]
      }
    }
  }
}
EOF

# Start CloudWatch agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# Final status
echo "================================================"
echo "OpenClaw Bootstrap Complete!"
echo "================================================"
echo ""
echo "Gateway Token: ${gateway_token}"
echo "Config Directory: $CONFIG_DIR"
echo "Workspace Directory: $WORKSPACE_DIR"
echo ""
echo "Access Control UI:"
echo "  1. SSH tunnel: ssh -L 18789:localhost:18789 ubuntu@<instance-ip>"
echo "  2. Browse to: http://localhost:18789/"
%{ if enable_tailscale && tailscale_auth_key != "" ~}
echo "  3. Or via Tailscale: http://$(tailscale ip -4):18789/"
%{ endif ~}
echo ""
echo "Check status:"
echo "  docker compose -f $OPENCLAW_DIR/docker-compose.yml ps"
echo "  docker compose -f $OPENCLAW_DIR/docker-compose.yml logs -f"
echo ""
echo "View this log:"
echo "  tail -f /var/log/openclaw-bootstrap.log"
echo ""
echo "================================================"

# Send completion notification to CloudWatch
echo "Bootstrap completed successfully at $(date)"
