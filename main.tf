# OpenClaw AWS Infrastructure
# Deploys OpenClaw on AWS t4g.small (ARM64) with Docker

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile != "" ? var.aws_profile : null

  default_tags {
    tags = {
      project     = "openclaw"
      environment = var.environment
      managed-by  = "terraform"
      team        = var.team_name
    }
  }
}

# Data source for latest Ubuntu 22.04 ARM64 AMI
data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# VPC (use existing or create new)
resource "aws_vpc" "openclaw_vpc" {
  count = var.use_existing_vpc ? 0 : 1

  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# Subnet
resource "aws_subnet" "openclaw_subnet" {
  count = var.use_existing_vpc ? 0 : 1

  vpc_id                  = aws_vpc.openclaw_vpc[0].id
  cidr_block              = var.subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project_name}-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "openclaw_igw" {
  count = var.use_existing_vpc ? 0 : 1

  vpc_id = aws_vpc.openclaw_vpc[0].id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

# Route Table
resource "aws_route_table" "openclaw_rt" {
  count = var.use_existing_vpc ? 0 : 1

  vpc_id = aws_vpc.openclaw_vpc[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.openclaw_igw[0].id
  }

  tags = {
    Name = "${var.project_name}-rt"
  }
}

# Route Table Association
resource "aws_route_table_association" "openclaw_rta" {
  count = var.use_existing_vpc ? 0 : 1

  subnet_id      = aws_subnet.openclaw_subnet[0].id
  route_table_id = aws_route_table.openclaw_rt[0].id
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# Security Group
resource "aws_security_group" "openclaw_sg" {
  name        = "${var.project_name}-sg"
  description = "Security group for OpenClaw instance"
  vpc_id      = var.use_existing_vpc ? var.existing_vpc_id : aws_vpc.openclaw_vpc[0].id

  # SSH access
  ingress {
    description = "SSH from allowed IPs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Optional: HTTPS for reverse proxy (if you add Nginx later)
  dynamic "ingress" {
    for_each = var.enable_https ? [1] : []
    content {
      description = "HTTPS (optional reverse proxy)"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # Optional: HTTP for Let's Encrypt challenge
  dynamic "ingress" {
    for_each = var.enable_https ? [1] : []
    content {
      description = "HTTP (optional LetsEncrypt)"
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # Outbound internet access (for API calls, Docker pulls, etc.)
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

# IAM Role for EC2 (for CloudWatch logs, SSM, etc.)
resource "aws_iam_role" "openclaw_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-ec2-role"
  }
}

# Attach SSM policy for AWS Systems Manager access
resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.openclaw_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Attach CloudWatch policy for logs
resource "aws_iam_role_policy_attachment" "cloudwatch_policy" {
  role       = aws_iam_role.openclaw_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# IAM Instance Profile
resource "aws_iam_instance_profile" "openclaw_profile" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.openclaw_role.name

  tags = {
    Name = "${var.project_name}-instance-profile"
  }
}

# IAM Role for Spot Fleet
resource "aws_iam_role" "spot_fleet_role" {
  count = var.use_spot_instances ? 1 : 0
  name  = "${var.project_name}-spot-fleet-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "spotfleet.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-spot-fleet-role"
  }
}

# Attach Spot Fleet policy
resource "aws_iam_role_policy_attachment" "spot_fleet_policy" {
  count      = var.use_spot_instances ? 1 : 0
  role       = aws_iam_role.spot_fleet_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2SpotFleetTaggingRole"
}

# Allow the instance to self-attach its EBS data volume on boot
resource "aws_iam_role_policy" "ebs_self_attach" {
  name = "${var.project_name}-ebs-self-attach"
  role = aws_iam_role.openclaw_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:AttachVolume", "ec2:DetachVolume", "ec2:DescribeVolumes"]
      Resource = "*"
    }]
  })
}

# SSH Key Pair (if creating new)
resource "aws_key_pair" "openclaw_key" {
  count = var.create_new_key_pair ? 1 : 0

  key_name   = "${var.project_name}-key"
  public_key = var.ssh_public_key

  tags = {
    Name = "${var.project_name}-key"
  }
}

# EBS Volume for data persistence
resource "aws_ebs_volume" "openclaw_data" {
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.project_name}-data"
  }
}

# Launch Template for Spot Fleet
resource "aws_launch_template" "openclaw" {
  name_prefix = "${var.project_name}-lt-"
  image_id    = data.aws_ami.ubuntu_arm64.id
  key_name    = var.create_new_key_pair ? aws_key_pair.openclaw_key[0].key_name : var.existing_key_name
  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    anthropic_api_key  = var.anthropic_api_key
    openai_api_key     = var.openai_api_key
    gateway_token      = random_password.gateway_token.result
    telegram_bot_token = var.telegram_bot_token
    discord_bot_token  = var.discord_bot_token
    openclaw_version   = var.openclaw_version
    enable_tailscale   = var.enable_tailscale
    tailscale_auth_key = var.tailscale_auth_key
    data_volume_id     = aws_ebs_volume.openclaw_data.id
  }))

  iam_instance_profile {
    name = aws_iam_instance_profile.openclaw_profile.name
  }

  vpc_security_group_ids = [aws_security_group.openclaw_sg.id]

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only for security
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-spot-instance"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.project_name}-root"
    }
  }


  tags = {
    Name = "${var.project_name}-launch-template"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# EC2 Spot Fleet with multiple instance types (priority: t4g.micro → t4g.small → t4g.medium)
resource "aws_spot_fleet_request" "openclaw" {
  count = var.use_spot_instances ? 1 : 0

  iam_fleet_role                      = aws_iam_role.spot_fleet_role[0].arn
  target_capacity                     = var.fleet_target_capacity
  allocation_strategy                 = "capacityOptimizedPrioritized"
  instance_interruption_behaviour     = "terminate" # Data lives on the separate EBS volume; terminate avoids accumulating stopped instances
  wait_for_fulfillment                = true
  terminate_instances_with_expiration = false
  replace_unhealthy_instances         = false # Prevents fleet from relaunching when we intentionally scale to 0

  # t4g.micro - Priority 0 (highest priority, cheapest; 1 GB RAM — relies on swap)
  launch_template_config {
    launch_template_specification {
      id      = aws_launch_template.openclaw.id
      version = "$Latest"
    }

    overrides {
      instance_type     = "t4g.micro"
      priority          = 0
      spot_price        = var.spot_max_price
      subnet_id         = var.use_existing_vpc ? var.existing_subnet_id : aws_subnet.openclaw_subnet[0].id
      weighted_capacity = 1
    }
  }

  # t4g.small - Priority 1
  launch_template_config {
    launch_template_specification {
      id      = aws_launch_template.openclaw.id
      version = "$Latest"
    }

    overrides {
      instance_type     = "t4g.small"
      priority          = 1
      spot_price        = var.spot_max_price
      subnet_id         = var.use_existing_vpc ? var.existing_subnet_id : aws_subnet.openclaw_subnet[0].id
      weighted_capacity = 1
    }
  }

  # t4g.medium - Priority 2 (fallback)
  launch_template_config {
    launch_template_specification {
      id      = aws_launch_template.openclaw.id
      version = "$Latest"
    }

    overrides {
      instance_type     = "t4g.medium"
      priority          = 2
      spot_price        = var.spot_max_price
      subnet_id         = var.use_existing_vpc ? var.existing_subnet_id : aws_subnet.openclaw_subnet[0].id
      weighted_capacity = 1
    }
  }

  tags = {
    Name = "${var.project_name}-spot-fleet"
  }

  lifecycle {
    # target_capacity is managed by start.sh / stop.sh out-of-band;
    # ignore it so terraform apply doesn't fight the scripts.
    ignore_changes = [target_capacity]
  }
}

# EC2 Instance - On-Demand (fallback when spot disabled)
resource "aws_instance" "openclaw" {
  count = var.use_spot_instances ? 0 : 1

  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.instance_type
  key_name               = var.create_new_key_pair ? aws_key_pair.openclaw_key[0].key_name : var.existing_key_name
  iam_instance_profile   = aws_iam_instance_profile.openclaw_profile.name
  vpc_security_group_ids = [aws_security_group.openclaw_sg.id]
  subnet_id              = var.use_existing_vpc ? var.existing_subnet_id : aws_subnet.openclaw_subnet[0].id

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
    tags = {
      Name = "${var.project_name}-root"
    }
  }

  user_data = templatefile("${path.module}/user-data.sh", {
    anthropic_api_key  = var.anthropic_api_key
    openai_api_key     = var.openai_api_key
    gateway_token      = random_password.gateway_token.result
    telegram_bot_token = var.telegram_bot_token
    discord_bot_token  = var.discord_bot_token
    openclaw_version   = var.openclaw_version
    enable_tailscale   = var.enable_tailscale
    tailscale_auth_key = var.tailscale_auth_key
    data_volume_id     = aws_ebs_volume.openclaw_data.id
  })

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only for security
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.project_name}-instance"
  }

  lifecycle {
    ignore_changes = [
      ami, # Prevent replacement on AMI updates
    ]
  }
}

# Data source to get instance ID from spot fleet
data "aws_instances" "openclaw_spot" {
  count = var.use_spot_instances ? 1 : 0

  filter {
    name   = "tag:aws:ec2spot:fleet-request-id"
    values = [aws_spot_fleet_request.openclaw[0].id]
  }

  filter {
    name   = "instance-state-name"
    values = ["running", "stopped"]
  }

  depends_on = [aws_spot_fleet_request.openclaw]
}

# Attach EBS volume to on-demand instance
resource "aws_volume_attachment" "openclaw_data_attachment" {
  count = var.use_spot_instances ? 0 : 1

  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.openclaw_data.id
  instance_id  = aws_instance.openclaw[0].id
  force_detach = true
}

# Generate secure gateway token
resource "random_password" "gateway_token" {
  length  = 64
  special = false
}

# Note: Elastic IP not supported for spot instances (instance ID changes on stop/start)
# For static IP with spot instances, consider using an Application Load Balancer or Route53 with health checks

# Elastic IP for on-demand instance (optional, for static IP)
resource "aws_eip" "openclaw_eip_ondemand" {
  count = var.allocate_elastic_ip && !var.use_spot_instances ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.openclaw[0].id

  tags = {
    Name = "${var.project_name}-eip"
  }
}

# Note: cost allocation tags must be activated from the payer/management account.
# To filter by project=openclaw in Cost Explorer, go to:
# AWS Billing Console (payer account) → Cost Allocation Tags → User-defined → activate "project"

# CloudWatch Log Group for OpenClaw logs
resource "aws_cloudwatch_log_group" "openclaw_logs" {
  name              = "/aws/ec2/${var.project_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-logs"
  }
}
