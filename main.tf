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
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "OpenClaw"
      Environment = var.environment
      ManagedBy   = "Terraform"
      Team        = var.team_name
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
  ingress {
    description = "HTTPS (optional reverse proxy)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.enable_https ? ["0.0.0.0/0"] : []
  }

  # Optional: HTTP for Let's Encrypt challenge
  ingress {
    description = "HTTP (optional LetsEncrypt)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.enable_https ? ["0.0.0.0/0"] : []
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

# EC2 Instance - t4g.small (ARM64)
resource "aws_instance" "openclaw" {
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
  }

  user_data = templatefile("${path.module}/user-data.sh", {
    anthropic_api_key     = var.anthropic_api_key
    openai_api_key        = var.openai_api_key
    gateway_token         = random_password.gateway_token.result
    telegram_bot_token    = var.telegram_bot_token
    discord_bot_token     = var.discord_bot_token
    openclaw_repo_url     = var.openclaw_repo_url
    enable_tailscale      = var.enable_tailscale
    tailscale_auth_key    = var.tailscale_auth_key
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

# Attach EBS volume
resource "aws_volume_attachment" "openclaw_data_attachment" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.openclaw_data.id
  instance_id = aws_instance.openclaw.id

  # Force detach on destroy to avoid errors
  force_detach = true
}

# Generate secure gateway token
resource "random_password" "gateway_token" {
  length  = 64
  special = false
}

# Elastic IP (optional, for static IP)
resource "aws_eip" "openclaw_eip" {
  count = var.allocate_elastic_ip ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.openclaw.id

  tags = {
    Name = "${var.project_name}-eip"
  }
}

# CloudWatch Log Group for OpenClaw logs
resource "aws_cloudwatch_log_group" "openclaw_logs" {
  name              = "/aws/ec2/${var.project_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name = "${var.project_name}-logs"
  }
}
