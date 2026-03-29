# Outputs for OpenClaw AWS Infrastructure

# Instance ID - works for both spot and on-demand
output "instance_id" {
  description = "EC2 instance ID (run 'terraform refresh' if showing 'pending' for spot instances)"
  value       = var.use_spot_instances ? try(data.aws_instances.openclaw_spot[0].ids[0], "pending") : aws_instance.openclaw[0].id
}

# Public IP - works for both spot and on-demand
output "instance_public_ip" {
  description = "Public IP address of the instance"
  value = var.use_spot_instances ? try(data.aws_instances.openclaw_spot[0].public_ips[0], "pending") : (
    var.allocate_elastic_ip ? aws_eip.openclaw_eip_ondemand[0].public_ip : aws_instance.openclaw[0].public_ip
  )
}

# Private IP - works for both spot and on-demand
output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = var.use_spot_instances ? try(data.aws_instances.openclaw_spot[0].private_ips[0], "pending") : aws_instance.openclaw[0].private_ip
}

# Instance type - actual type from spot fleet or configured type
output "instance_type" {
  description = "Instance type (actual type if spot fleet)"
  value = var.use_spot_instances ? "spot-fleet(t4g.small|medium|large)" : var.instance_type
}

# Spot fleet ID
output "spot_fleet_id" {
  description = "Spot fleet request ID (if using spot instances)"
  value       = var.use_spot_instances ? aws_spot_fleet_request.openclaw[0].id : null
}

# Elastic IP
output "elastic_ip" {
  description = "Elastic IP address (if allocated, on-demand only)"
  value       = var.allocate_elastic_ip && !var.use_spot_instances ? aws_eip.openclaw_eip_ondemand[0].public_ip : null
}

# SSH Command
output "ssh_command" {
  description = "SSH command to connect to the instance"
  value = var.use_spot_instances ? try("ssh ubuntu@${data.aws_instances.openclaw_spot[0].public_ips[0]}", "terraform refresh # to get spot instance IP") : "ssh ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip_ondemand[0].public_ip : aws_instance.openclaw[0].public_ip}"
}

# SSH Tunnel Command
output "ssh_tunnel_command" {
  description = "SSH tunnel command for Control UI access"
  value = var.use_spot_instances ? try("ssh -fN -L 18789:localhost:18789 ubuntu@${data.aws_instances.openclaw_spot[0].public_ips[0]}", "terraform refresh # to get spot instance IP") : "ssh -fN -L 18789:localhost:18789 ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip_ondemand[0].public_ip : aws_instance.openclaw[0].public_ip}"
}

# Control UI URL
output "control_ui_url" {
  description = "Control UI URL (access via SSH tunnel)"
  value       = "http://localhost:18789/"
}

# Gateway Token
output "gateway_token" {
  description = "OpenClaw gateway authentication token"
  value       = random_password.gateway_token.result
  sensitive   = true
}

# Gateway Token Command
output "gateway_token_command" {
  description = "Command to retrieve gateway token"
  value       = "terraform output -raw gateway_token"
}

# Security Group ID
output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.openclaw_sg.id
}

# VPC ID
output "vpc_id" {
  description = "VPC ID"
  value       = var.use_existing_vpc ? var.existing_vpc_id : aws_vpc.openclaw_vpc[0].id
}

# Subnet ID
output "subnet_id" {
  description = "Subnet ID"
  value       = var.use_existing_vpc ? var.existing_subnet_id : aws_subnet.openclaw_subnet[0].id
}

# Data Volume ID
output "data_volume_id" {
  description = "EBS data volume ID"
  value       = aws_ebs_volume.openclaw_data.id
}

# IAM Role Name
output "iam_role_name" {
  description = "IAM role name attached to the instance"
  value       = aws_iam_role.openclaw_role.name
}

# CloudWatch Log Group
output "cloudwatch_log_group" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.openclaw_logs.name
}

# AMI ID
output "ami_id" {
  description = "AMI ID used for the instance"
  value       = data.aws_ami.ubuntu_arm64.id
}

# Quick Start Guide
output "quick_start_guide" {
  description = "Quick start commands"
  value       = <<-EOT
    # Deployment Mode: ${var.use_spot_instances ? "SPOT INSTANCES (70% cost savings!)" : "ON-DEMAND"}
    ${var.use_spot_instances ? "# Instance Types: t4g.small (preferred), t4g.medium, t4g.large (fallback)" : "# Instance Type: ${var.instance_type}"}

    ${var.use_spot_instances ? "# 1. Wait for spot instance (30-60 seconds):\n    terraform refresh\n    terraform output instance_public_ip\n\n# 2. Attach EBS data volume:\n    ./attach-volume.sh\n" : ""}
    # ${var.use_spot_instances ? "3" : "1"}. Check instance status:
    ./status.sh

    # ${var.use_spot_instances ? "4" : "2"}. Connect to instance:
    terraform output -raw ssh_command

    # ${var.use_spot_instances ? "5" : "3"}. Check OpenClaw status:
    sudo docker compose -f /opt/openclaw/docker-compose.yml ps

    # ${var.use_spot_instances ? "6" : "4"}. View logs:
    sudo docker compose -f /opt/openclaw/docker-compose.yml logs -f openclaw-gateway

    # ${var.use_spot_instances ? "7" : "5"}. Access Control UI via SSH tunnel:
    terraform output -raw ssh_tunnel_command
    # Then browse to: http://localhost:18789/

    # ${var.use_spot_instances ? "8" : "6"}. Get gateway token:
    terraform output -raw gateway_token

    # ${var.use_spot_instances ? "9" : "7"}. Start/Stop instance (cost optimization):
    ${var.use_spot_instances ? "# Spot instances stop automatically on interruption (rare)\n    # After interruption, run ./attach-volume.sh again" : ""}
    ./status.sh   # Check current state
    ./stop.sh     # Stop instance (save money)
    ./start.sh    # Start instance when needed
    ${var.use_spot_instances ? "./attach-volume.sh  # Reattach volume after stop/start" : ""}
  EOT
}

# Tailscale IP
output "tailscale_ip" {
  description = "Tailscale IP (check on instance after deployment)"
  value = var.enable_tailscale ? (
    var.use_spot_instances ? try("Run: ssh ubuntu@${data.aws_instances.openclaw_spot[0].public_ips[0]} 'tailscale ip -4'", "Run terraform refresh first") : "Run: ssh ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip_ondemand[0].public_ip : aws_instance.openclaw[0].public_ip} 'tailscale ip -4'"
  ) : "Tailscale not enabled"
}

# Cost Estimate
output "estimated_monthly_cost" {
  description = "Estimated monthly cost (24/7 operation)"
  value = var.use_spot_instances ? (
    <<-EOT
    Spot Instance Pricing (typical):
    - t4g.small spot:  ~$3.60/month (70% savings)
    - t4g.medium spot: ~$7.20/month (if t4g.small unavailable)
    - t4g.large spot:  ~$14.40/month (rare fallback)

    Storage (always charged):
    - Root volume (${var.root_volume_size}GB): ~$${var.root_volume_size * 0.08}/month
    - Data volume (${var.data_volume_size}GB): ~$${var.data_volume_size * 0.08}/month

    Total estimated: ~$${3.60 + (var.root_volume_size * 0.08) + (var.data_volume_size * 0.08)}/month
    (using t4g.small most of the time)
    EOT
  ) : (
    <<-EOT
    On-Demand Pricing:
    - Instance (${var.instance_type}): ~$12.10/month (24/7)
    - Root volume (${var.root_volume_size}GB): ~$${var.root_volume_size * 0.08}/month
    - Data volume (${var.data_volume_size}GB): ~$${var.data_volume_size * 0.08}/month

    Total: ~$${12.10 + (var.root_volume_size * 0.08) + (var.data_volume_size * 0.08)}/month

    💡 Enable spot instances (use_spot_instances=true) to save 70%!
    EOT
  )
}
