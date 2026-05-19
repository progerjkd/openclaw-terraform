#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGION="us-east-1"

# Load AWS_PROFILE from terraform.tfvars if not already set in environment
if [[ -z "${AWS_PROFILE:-}" ]]; then
  _profile=$(grep -E '^\s*aws_profile\s*=' "$SCRIPT_DIR/terraform.tfvars" 2>/dev/null | sed 's/.*"\([^"]*\)".*/\1/')
  [[ -n "$_profile" ]] && export AWS_PROFILE="$_profile"
  unset _profile
fi

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "Usage: ./update.sh <version>"
  echo "Example: ./update.sh 2026.5.12"
  echo ""
  echo "Latest releases: https://github.com/openclaw/openclaw/releases"
  exit 1
fi

TERRAFORM=$(command -v terraform 2>/dev/null || echo /opt/homebrew/bin/terraform)
if [[ ! -x "$TERRAFORM" ]]; then
  echo "Error: terraform not found. Install via: brew install terraform"
  exit 1
fi

# Resolve instance IP
SPOT_FLEET_ID=$("$TERRAFORM" output -raw spot_fleet_id 2>/dev/null || echo "")
if [[ -n "$SPOT_FLEET_ID" ]]; then
  INSTANCE_ID=$(aws ec2 describe-spot-fleet-instances \
    --spot-fleet-request-id "$SPOT_FLEET_ID" \
    --region "$REGION" \
    --query 'ActiveInstances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")
  if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
    echo "Error: no running spot instance found. Run ./start.sh first."
    exit 1
  fi
else
  INSTANCE_ID=$("$TERRAFORM" output -raw instance_id 2>/dev/null) || {
    echo "Error: could not read instance_id from terraform output."
    exit 1
  }
fi

IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

if [[ -z "$IP" || "$IP" == "None" ]]; then
  echo "Error: could not determine instance IP."
  exit 1
fi

echo "Updating OpenClaw to $VERSION on $IP..."
echo ""

ssh ubuntu@"$IP" bash -s <<ENDSSH
set -e

echo "Pulling ghcr.io/openclaw/openclaw:$VERSION..."
docker pull ghcr.io/openclaw/openclaw:$VERSION

echo "Writing docker-compose.yml..."
cat > /opt/openclaw/docker-compose.yml <<'EOF'
services:
  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw:$VERSION
    env_file: /opt/openclaw-data/config/.env
    volumes:
      - /opt/openclaw-data/config:/home/node/.openclaw
      - /opt/openclaw-data/workspace:/home/node/.openclaw/workspace
    ports:
      - "18789:18789"
    restart: unless-stopped
    command:
      - "node"
      - "dist/index.js"
      - "gateway"
      - "--allow-unconfigured"
      - "--bind"
      - "lan"
      - "--port"
      - "18789"
EOF

rm -f /opt/openclaw/docker-compose.override.yml

echo "Restarting openclaw-gateway..."
cd /opt/openclaw && docker compose up -d --no-deps openclaw-gateway

echo ""
docker compose ps
ENDSSH

echo ""
echo "OpenClaw updated to $VERSION"
echo "SSH tunnel: ssh -fN -L 18789:localhost:18789 ubuntu@$IP"
echo "Control UI: http://localhost:18789/"
