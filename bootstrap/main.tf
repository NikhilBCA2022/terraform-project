# ---------------------------------------------------------------------------
# Bootstrap — run ONCE before any workspace plan/apply.
# Provisions: S3 state bucket, DynamoDB lock table, KMS CMK,
#             GitHub Actions OIDC role, Secrets Manager DB secret.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

provider "aws" {
  alias  = "replica"
  region = "eu-central-1"
}

locals {
  account_id   = "866435872216"
  primary_region = "ap-south-1"
  replica_region = "eu-central-1"
  project      = "multi-region-arch"
  state_bucket = "tf-state-${local.account_id}-${local.primary_region}"
  replica_bucket = "tf-state-${local.account_id}-${local.replica_region}"
  github_repo  = "NikhilBCA2022/terraform-project"
}

# ---------------------------------------------------------------------------
# KMS — state encryption key (primary)
# ---------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  description             = "Terraform state bucket encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Enable IAM root permissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "Allow S3 service"
        Effect = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name    = "tf-state-key"
    Project = local.project
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/tf-state-key"
  target_key_id = aws_kms_key.state.key_id
}

# Replicate the KMS key to eu-central-1 for CRR
resource "aws_kms_replica_key" "state_replica" {
  provider                = aws.replica
  description             = "Replica of Terraform state KMS key"
  primary_key_arn         = aws_kms_key.state.arn
  deletion_window_in_days = 30

  tags = {
    Name    = "tf-state-key-replica"
    Project = local.project
  }
}

resource "aws_kms_alias" "state_replica" {
  provider      = aws.replica
  name          = "alias/tf-state-key-replica"
  target_key_id = aws_kms_replica_key.state_replica.key_id
}

# ---------------------------------------------------------------------------
# S3 — state bucket (primary, ap-south-1)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket        = local.state_bucket
  force_destroy = false

  tags = {
    Name    = local.state_bucket
    Project = local.project
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "archive-old-state"
    status = "Enabled"

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_transition {
      noncurrent_days = 90
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

# IAM role for CRR
resource "aws_iam_role" "crr" {
  name = "tf-state-crr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "crr" {
  name = "tf-state-crr-policy"
  role = aws_iam_role.crr.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = "${aws_s3_bucket.state_replica.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = aws_kms_key.state.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_replica_key.state_replica.arn
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  role   = aws_iam_role.crr.arn

  rule {
    id     = "replicate-to-eu-central-1"
    status = "Enabled"

    destination {
      bucket        = aws_s3_bucket.state_replica.arn
      storage_class = "STANDARD"

      encryption_configuration {
        replica_kms_key_id = aws_kms_replica_key.state_replica.arn
      }
    }

    source_selection_criteria {
      sse_kms_encrypted_objects {
        status = "Enabled"
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

resource "aws_s3_bucket_policy" "state_https_only" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonHTTPS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [
        aws_s3_bucket.state.arn,
        "${aws_s3_bucket.state.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# ---------------------------------------------------------------------------
# S3 — replica bucket (eu-central-1)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state_replica" {
  provider      = aws.replica
  bucket        = local.replica_bucket
  force_destroy = false

  tags = {
    Name    = local.replica_bucket
    Project = local.project
  }
}

resource "aws_s3_bucket_versioning" "state_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.state_replica.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state_replica" {
  provider = aws.replica
  bucket   = aws_s3_bucket.state_replica.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_replica_key.state_replica.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state_replica" {
  provider                = aws.replica
  bucket                  = aws_s3_bucket.state_replica.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# DynamoDB — state lock table
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "state_lock" {
  name         = "tf-state-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name    = "tf-state-lock"
    Project = local.project
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC — IAM role
# ---------------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = length(data.aws_iam_openid_connect_provider.github.arn) == 0 ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  github_oidc_arn = length(data.aws_iam_openid_connect_provider.github.arn) > 0 ? data.aws_iam_openid_connect_provider.github.arn : aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_role" "github_actions" {
  name = "github-actions-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = local.github_oidc_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${local.github_repo}:*"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = {
    Name    = "github-actions-terraform"
    Project = local.project
  }
}

resource "aws_iam_role_policy" "github_actions_terraform" {
  name = "terraform-access"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*"
        ]
      },
      {
        Sid    = "TerraformLockAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.state_lock.arn
      },
      {
        Sid    = "TerraformKMSAccess"
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"
        ]
        Resource = aws_kms_key.state.arn
      },
      {
        Sid      = "TerraformProvisionAccess"
        Effect   = "Allow"
        Action   = ["*"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = [local.primary_region, local.replica_region]
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "state_bucket_name" {
  value = aws_s3_bucket.state.bucket
}

output "replica_bucket_name" {
  value = aws_s3_bucket.state_replica.bucket
}

output "dynamodb_lock_table" {
  value = aws_dynamodb_table.state_lock.name
}

output "kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
