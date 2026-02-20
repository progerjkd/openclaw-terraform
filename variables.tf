# Variables for OpenClaw AWS Infrastructure

# General Configuration
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "production"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "openclaw"
}

variable "team_name" {
  description = "Team name for tagging"
  type        = string
  default     = "startup-team"
}

# Instance Configuration
variable "instance_type" {
  description = "EC2 instance type (ARM64)"
  type        = string
  default     = "t4g.small"

  validation {
    condition     = can(regex("^t4g\\.", var.instance_type))
    error_message = "Instance type must be ARM64 (t4g family)."
  }
}

variable "root_volume_size" {
  description = "Size of root EBS volume in GB"
  type        = number
  default     = 20
}

variable "data_volume_size" {
  description = "Size of data EBS volume for OpenClaw persistence in GB"
  type        = number
  default     = 30
}

# Networking Configuration
variable "use_existing_vpc" {
  description = "Use existing VPC instead of creating new one"
  type        = bool
  default     = false
}

variable "existing_vpc_id" {
  description = "Existing VPC ID (required if use_existing_vpc = true)"
  type        = string
  default     = ""
}

variable "existing_subnet_id" {
  description = "Existing subnet ID (required if use_existing_vpc = true)"
  type        = string
  default     = ""
}

variable "vpc_cidr" {
  description = "CIDR block for VPC (if creating new)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR block for subnet (if creating new)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "allowed_ssh_cidrs" {
  description = "List of CIDR blocks allowed to SSH to the instance"
  type        = list(string)
  default     = ["0.0.0.0/0"] # CHANGE THIS! Use your office/home IP

  validation {
    condition     = length(var.allowed_ssh_cidrs) > 0
    error_message = "At least one CIDR block must be specified for SSH access."
  }
}

variable "enable_https" {
  description = "Enable HTTPS (ports 80/443) for reverse proxy setup"
  type        = bool
  default     = false
}

variable "allocate_elastic_ip" {
  description = "Allocate an Elastic IP for the instance"
  type        = bool
  default     = false
}

# SSH Key Configuration
variable "create_new_key_pair" {
  description = "Create a new SSH key pair (if false, use existing)"
  type        = bool
  default     = true
}

variable "ssh_public_key" {
  description = "SSH public key content (required if create_new_key_pair = true)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "existing_key_name" {
  description = "Name of existing EC2 key pair (required if create_new_key_pair = false)"
  type        = string
  default     = ""
}

# OpenClaw Configuration
variable "openclaw_repo_url" {
  description = "OpenClaw Git repository URL"
  type        = string
  default     = "https://github.com/openclaw/openclaw.git"
}

variable "anthropic_api_key" {
  description = "Anthropic API key for Claude models"
  type        = string
  default     = ""
  sensitive   = true
}

variable "openai_api_key" {
  description = "OpenAI API key"
  type        = string
  default     = ""
  sensitive   = true
}

variable "telegram_bot_token" {
  description = "Telegram bot token for channel integration"
  type        = string
  default     = ""
  sensitive   = true
}

variable "discord_bot_token" {
  description = "Discord bot token for channel integration"
  type        = string
  default     = ""
  sensitive   = true
}

# Tailscale VPN Configuration
variable "enable_tailscale" {
  description = "Install and configure Tailscale VPN"
  type        = bool
  default     = true
}

variable "tailscale_auth_key" {
  description = "Tailscale authentication key (one-time or reusable)"
  type        = string
  default     = ""
  sensitive   = true
}

# Monitoring Configuration
variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.log_retention_days)
    error_message = "Log retention days must be a valid CloudWatch retention period."
  }
}
