variable "primary_region" {
  description = "Primary AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "multi-region-arch"
}

variable "vpc_cidr" {
  description = "CIDR block for the primary VPC"
  type        = string
}

variable "enable_nat_gateway" {
  description = "Whether to create NAT Gateway(s)"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway instead of one per AZ"
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Name of the initial database"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for RDS"
  type        = string
  sensitive   = true
}

variable "app_min_size" {
  description = "Minimum number of instances in ASG"
  type        = number
  default     = 1
}

variable "app_max_size" {
  description = "Maximum number of instances in ASG"
  type        = number
  default     = 4
}

variable "app_desired_capacity" {
  description = "Desired number of instances in ASG"
  type        = number
  default     = 2
}

variable "alarm_email" {
  description = "Email address for CloudWatch alarm notifications"
  type        = string
}

# ---------------------------------------------------------------------------
# Workspace-aware config — unknown workspaces fail at plan time
# ---------------------------------------------------------------------------
check "workspace_valid" {
  assert {
    condition     = contains(["dev", "staging", "prod"], terraform.workspace)
    error_message = "Unknown workspace '${terraform.workspace}'. Allowed values: dev, staging, prod."
  }
}

locals {
  workspace_config = {
    dev = {
      instance_size    = "t3.micro"
      db_instance      = "db.t3.micro"
      retention_days   = 7
      rate_limit       = 100
      enable_waf       = false
      enable_shield    = false
      multi_az         = false
      deletion_protect = false
    }
    staging = {
      instance_size    = "t3.small"
      db_instance      = "db.t3.small"
      retention_days   = 14
      rate_limit       = 500
      enable_waf       = true
      enable_shield    = false
      multi_az         = false
      deletion_protect = false
    }
    prod = {
      instance_size    = "t3.medium"
      db_instance      = "db.t3.medium"
      retention_days   = 90
      rate_limit       = 2000
      enable_waf       = true
      enable_shield    = true
      multi_az         = true
      deletion_protect = true
    }
  }

  env_config = local.workspace_config[terraform.workspace]
}
