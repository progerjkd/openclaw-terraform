# Outputs for OpenClaw AWS Infrastructure

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.openclaw.id
}

output "instance_public_ip" {
  description = "Public IP address of the instance"
  value       = var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : aws_instance.openclaw.public_ip
}

output "instance_private_ip" {
  description = "Private IP address of the instance"
  value       = aws_instance.openclaw.private_ip
}

output "elastic_ip" {
  description = "Elastic IP address (if allocated)"
  value       = var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : null
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/${var.create_new_key_pair ? "${var.project_name}-key" : var.existing_key_name}.pem ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : aws_instance.openclaw.public_ip}"
}

output "ssh_tunnel_command" {
  description = "SSH tunnel command for Control UI access"
  value       = "ssh -L 18789:localhost:18789 -i ~/.ssh/${var.create_new_key_pair ? "${var.project_name}-key" : var.existing_key_name}.pem ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : aws_instance.openclaw.public_ip}"
}

output "control_ui_url" {
  description = "Control UI URL (access via SSH tunnel)"
  value       = "http://localhost:18789/"
}

output "gateway_token" {
  description = "OpenClaw gateway authentication token"
  value       = random_password.gateway_token.result
  sensitive   = true
}

output "gateway_token_command" {
  description = "Command to retrieve gateway token"
  value       = "terraform output -raw gateway_token"
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.openclaw_sg.id
}

output "vpc_id" {
  description = "VPC ID"
  value       = var.use_existing_vpc ? var.existing_vpc_id : aws_vpc.openclaw_vpc[0].id
}

output "subnet_id" {
  description = "Subnet ID"
  value       = var.use_existing_vpc ? var.existing_subnet_id : aws_subnet.openclaw_subnet[0].id
}

output "data_volume_id" {
  description = "EBS data volume ID"
  value       = aws_ebs_volume.openclaw_data.id
}

output "iam_role_name" {
  description = "IAM role name attached to the instance"
  value       = aws_iam_role.openclaw_role.name
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group name"
  value       = aws_cloudwatch_log_group.openclaw_logs.name
}

output "ami_id" {
  description = "AMI ID used for the instance"
  value       = data.aws_ami.ubuntu_arm64.id
}

output "instance_type" {
  description = "Instance type"
  value       = var.instance_type
}

output "quick_start_guide" {
  description = "Quick start commands"
  value       = <<-EOT
    # 1. Connect to instance:
    ${var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : aws_instance.openclaw.public_ip}
    ssh -i ~/.ssh/${var.create_new_key_pair ? "${var.project_name}-key" : var.existing_key_name}.pem ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : aws_instance.openclaw.public_ip}

    # 2. Check OpenClaw status:
    sudo docker compose -f /opt/openclaw/docker-compose.yml ps

    # 3. View logs:
    sudo docker compose -f /opt/openclaw/docker-compose.yml logs -f openclaw-gateway

    # 4. Access Control UI via SSH tunnel:
    ssh -L 18789:localhost:18789 ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : aws_instance.openclaw.public_ip}
    # Then browse to: http://localhost:18789/

    # 5. Get gateway token:
    terraform output -raw gateway_token

    # 6. Configure WhatsApp:
    sudo docker compose -f /opt/openclaw/docker-compose.yml run --rm openclaw-cli channels login

    # 7. Configure Telegram (if token provided):
    sudo docker compose -f /opt/openclaw/docker-compose.yml run --rm openclaw-cli channels add --channel telegram --token "YOUR_TOKEN"
  EOT
}

output "tailscale_ip" {
  description = "Tailscale IP (check on instance after deployment)"
  value       = var.enable_tailscale ? "Run: ssh ubuntu@${var.allocate_elastic_ip ? aws_eip.openclaw_eip[0].public_ip : aws_instance.openclaw.public_ip} 'tailscale ip -4'" : "Tailscale not enabled"
}
