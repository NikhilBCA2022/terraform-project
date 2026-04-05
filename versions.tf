terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  backend "s3" {
    bucket         = "tf-state-866435872216-ap-south-1"
    key            = "multi-region/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "tf-state-lock"
    encrypt        = true
    kms_key_id     = "alias/tf-state-key"
  }
}

provider "aws" {
  region = var.primary_region

  default_tags {
    tags = {
      Project     = "multi-region-arch"
      ManagedBy   = "terraform"
      Environment = terraform.workspace
    }
  }
}

provider "aws" {
  alias  = "replica"
  region = var.replica_region

  default_tags {
    tags = {
      Project     = "multi-region-arch"
      ManagedBy   = "terraform"
      Environment = terraform.workspace
    }
  }
}
