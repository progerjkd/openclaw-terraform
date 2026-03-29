#!/usr/bin/env bash
set -euo pipefail

# AWS_PROFILE is read from environment: export AWS_PROFILE=your-profile
REGION="us-east-1"

echo "Checking spot instance and EBS volume status..."

# Get instance and volume IDs
INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null) || {
  echo "Error: could not read instance_id from terraform output."
  exit 1
}

if [[ "$INSTANCE_ID" == "pending" ]]; then
  echo "Spot instance is still pending. Wait a moment and try again."
  exit 1
fi

VOLUME_ID=$(terraform output -raw data_volume_id 2>/dev/null) || {
  echo "Error: could not read data_volume_id from terraform output."
  exit 1
}

# Check if volume is already attached
attachment=$(aws ec2 describe-volumes \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION" \
  --query 'Volumes[0].Attachments[0].{State:State,Instance:InstanceId}' \
  --output json)

current_state=$(echo "$attachment" | jq -r '.State // "detached"')
attached_instance=$(echo "$attachment" | jq -r '.Instance // "none"')

if [[ "$current_state" == "attached" && "$attached_instance" == "$INSTANCE_ID" ]]; then
  echo "✓ Volume $VOLUME_ID is already attached to instance $INSTANCE_ID"
  exit 0
fi

if [[ "$current_state" == "attached" && "$attached_instance" != "$INSTANCE_ID" ]]; then
  echo "Volume is attached to a different instance: $attached_instance"
  echo "Detaching from old instance first..."
  aws ec2 detach-volume \
    --volume-id "$VOLUME_ID" \
    --region "$REGION" > /dev/null

  echo "Waiting for volume to detach..."
  aws ec2 wait volume-available \
    --volume-ids "$VOLUME_ID" \
    --region "$REGION"
fi

# Attach volume
echo "Attaching volume $VOLUME_ID to instance $INSTANCE_ID..."
aws ec2 attach-volume \
  --volume-id "$VOLUME_ID" \
  --instance-id "$INSTANCE_ID" \
  --device /dev/sdf \
  --region "$REGION" > /dev/null

echo "Waiting for volume to attach..."
aws ec2 wait volume-in-use \
  --volume-ids "$VOLUME_ID" \
  --region "$REGION"

echo "✓ Volume attached successfully!"
echo ""
echo "The volume will be automatically mounted at /opt/openclaw-data"
echo "by the cloud-init script on first boot."
