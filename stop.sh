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

if [[ "$state" != "running" ]]; then
  echo ""
  echo "Instance is not running (state: $state). Nothing to stop."
  exit 0
fi

echo ""
read -rp "Stop this instance? [y/N] " confirm
if [[ "$confirm" != [yY] ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""
echo "Stopping instance..."
aws ec2 stop-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION" \
  --output text > /dev/null

echo "Waiting for instance to stop..."
aws ec2 wait instance-stopped \
  --instance-ids "$INSTANCE_ID" \
  --region "$REGION"

echo "Instance stopped."
