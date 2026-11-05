provider "aws" {
  region = var.aws_region
}

locals {
  # ECR repository name must match ECR_REPOSITORY in the GitHub Actions workflow
  ecr_repository_name = "${var.project_name}-app"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# Latest Amazon Linux 2 AMI — SSM Agent pre-installed
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Use the account's default VPC to keep the POC self-contained
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_caller_identity" "current" {}
