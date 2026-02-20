#!/usr/bin/env bash
set -euo pipefail

REGION="us-east-1"
INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null) || {
  echo "Error: could not read instance_id from terraform output."
  echo "Run this script from the openclaw-terraform directory."
  exit 1
}

# Check current state
state=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].State.Name' \
  --output text)

echo "Instance:  $INSTANCE_ID"
echo "State:     $state"

if [[ "$state" == "running" ]]; then
  ip=$(aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)
  echo "Public IP: $ip"
  echo ""
  echo "Instance is already running."
  echo ""
  echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
  echo "Control UI:  http://localhost:18789/"
  exit 0
fi

if [[ "$state" != "stopped" ]]; then
  echo ""
  echo "Instance is in state '$state'. Can only start from 'stopped'."
  exit 1
fi

echo ""
echo "Starting instance..."
aws ec2 start-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --output text > /dev/null

echo "Waiting for instance to start..."
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"

# Fetch new public IP
ip=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo ""
echo "Instance is running!"
echo "Public IP: $ip"
echo ""
echo "SSH tunnel:  ssh -fN -L 18789:localhost:18789 ubuntu@$ip"
echo "Control UI:  http://localhost:18789/"
