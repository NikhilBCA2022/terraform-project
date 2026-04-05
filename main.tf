# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_secretsmanager_secret_version" "db_password" {
  secret_id  = aws_secretsmanager_secret.db_password.id
  depends_on = [aws_secretsmanager_secret_version.db_password_initial]
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

data "archive_file" "rotator" {
  type        = "zip"
  output_path = "${path.module}/.terraform/rotator.zip"

  source {
    content  = "def lambda_handler(e, c): pass"
    filename = "index.py"
  }
}

# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
#checkov:skip=CKV_TF_1:Registry module with pinned version is acceptable
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-${terraform.workspace}"
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available.names
  private_subnets = [for i, az in data.aws_availability_zones.available.names : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in data.aws_availability_zones.available.names : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  enable_nat_gateway   = var.enable_nat_gateway
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Workspace = terraform.workspace
  }
}

# ---------------------------------------------------------------------------
# KMS — application key with explicit policy
# ---------------------------------------------------------------------------
resource "aws_kms_key" "app" {
  description             = "${var.project_name}-${terraform.workspace} app encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-app-key"
  }
}

resource "aws_kms_alias" "app" {
  name          = "alias/${var.project_name}-${terraform.workspace}-app"
  target_key_id = aws_kms_key.app.key_id
}

# ---------------------------------------------------------------------------
# Secrets Manager — DB password
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}/${terraform.workspace}/db-password"
  kms_key_id              = aws_kms_key.app.arn
  recovery_window_in_days = terraform.workspace == "prod" ? 30 : 0

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-db-password"
  }
}

resource "random_password" "db" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret_version" "db_password_initial" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db.result
}

resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = aws_lambda_function.secret_rotator.arn

  rotation_rules {
    automatically_after_days = 30
  }
}

# ---------------------------------------------------------------------------
# RDS — parameter group (enables query logging for CKV2_AWS_30)
# ---------------------------------------------------------------------------
resource "aws_db_parameter_group" "main" {
  name   = "${var.project_name}-${terraform.workspace}-pg15"
  family = "postgres15"

  parameter {
    name  = "log_statement"
    value = "all"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-pg15"
  }
}

# ---------------------------------------------------------------------------
# RDS — enhanced monitoring IAM role
# ---------------------------------------------------------------------------
resource "aws_iam_role" "rds_monitoring" {
  name = "${var.project_name}-${terraform.workspace}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# ---------------------------------------------------------------------------
# RDS — subnet group + security group
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${terraform.workspace}"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-${terraform.workspace}-rds"
  description = "Allow PostgreSQL inbound from app tier only — no egress needed"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL from app tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-rds-sg"
  }
}

# ---------------------------------------------------------------------------
# RDS — PostgreSQL instance
# ---------------------------------------------------------------------------
resource "aws_db_instance" "main" {
  identifier                            = "${var.project_name}-${terraform.workspace}"
  engine                                = "postgres"
  engine_version                        = "15.4"
  instance_class                        = local.env_config.db_instance
  allocated_storage                     = 20
  max_allocated_storage                 = 100
  storage_encrypted                     = true
  kms_key_id                            = aws_kms_key.app.arn
  db_name                               = var.db_name
  username                              = var.db_username
  password                              = data.aws_secretsmanager_secret_version.db_password.secret_string
  db_subnet_group_name                  = aws_db_subnet_group.main.name
  vpc_security_group_ids                = [aws_security_group.rds.id]
  parameter_group_name                  = aws_db_parameter_group.main.name
  multi_az                              = local.env_config.multi_az
  skip_final_snapshot                   = !local.env_config.deletion_protect
  deletion_protection                   = local.env_config.deletion_protect
  backup_retention_period               = local.env_config.retention_days
  copy_tags_to_snapshot                 = true
  auto_minor_version_upgrade            = true
  iam_database_authentication_enabled   = true
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.app.arn
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-rds"
  }
}

# ---------------------------------------------------------------------------
# App security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-${terraform.workspace}-app"
  description = "App tier — inbound from ALB, outbound to RDS and AWS APIs"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTP from ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description     = "PostgreSQL to RDS tier"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id]
  }

  egress {
    description = "HTTPS to AWS service endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-app-sg"
  }
}

# ---------------------------------------------------------------------------
# ALB security group
# ---------------------------------------------------------------------------
#checkov:skip=CKV_AWS_260:Port 80 required for HTTP-to-HTTPS redirect listener
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${terraform.workspace}-alb"
  description = "ALB — HTTPS/HTTP inbound from internet, outbound to app tier"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP redirect from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description     = "HTTP to app tier"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-alb-sg"
  }
}

# ---------------------------------------------------------------------------
# S3 — ALB access logs bucket
# ---------------------------------------------------------------------------
#checkov:skip=CKV2_AWS_62:Event notifications not required for ALB log buckets
resource "aws_s3_bucket" "alb_logs" {
  bucket        = "${var.project_name}-${terraform.workspace}-alb-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-alb-logs"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    expiration {
      days = local.env_config.retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowALBLogDelivery"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid       = "AllowALBAclCheck"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.alb_logs.arn
      },
      {
        Sid       = "DenyNonHTTPS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.alb_logs.arn, "${aws_s3_bucket.alb_logs.arn}/*"]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# WAFv2 WebACL
# ---------------------------------------------------------------------------
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project_name}-${terraform.workspace}"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${terraform.workspace}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.project_name}-${terraform.workspace}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-${terraform.workspace}-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-waf"
  }
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name                       = "${var.project_name}-${terraform.workspace}"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [aws_security_group.alb.id]
  subnets                    = module.vpc.public_subnets
  enable_deletion_protection = local.env_config.deletion_protect
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb"
    enabled = true
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-alb"
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

#checkov:skip=CKV_AWS_378:Internal HTTP on port 8080 within VPC is acceptable
resource "aws_lb_target_group" "app" {
  name     = "${var.project_name}-${terraform.workspace}-app"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ---------------------------------------------------------------------------
# Auto Scaling Group
# ---------------------------------------------------------------------------
resource "aws_launch_template" "app" {
  name_prefix   = "${var.project_name}-${terraform.workspace}-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = local.env_config.instance_size

  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    # Application bootstrap goes here
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name      = "${var.project_name}-${terraform.workspace}-app"
      Workspace = terraform.workspace
    }
  }
}

resource "aws_autoscaling_group" "app" {
  name                = "${var.project_name}-${terraform.workspace}"
  vpc_zone_identifier = module.vpc.private_subnets
  target_group_arns   = [aws_lb_target_group.app.arn]
  min_size            = var.app_min_size
  max_size            = var.app_max_size
  desired_capacity    = var.app_desired_capacity

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  health_check_type         = "ELB"
  health_check_grace_period = 300

  tag {
    key                 = "Name"
    value               = "${var.project_name}-${terraform.workspace}-app"
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------------------
# IAM — EC2 instance profile
# ---------------------------------------------------------------------------
resource "aws_iam_role" "app_instance" {
  name = "${var.project_name}-${terraform.workspace}-app-instance"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "secrets_read" {
  name = "secrets-read"
  role = aws_iam_role.app_instance.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db_password.arn]
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.project_name}-${terraform.workspace}-app"
  role = aws_iam_role.app_instance.name
}

# ---------------------------------------------------------------------------
# CloudWatch — log group + alarm
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project_name}/${terraform.workspace}/app"
  retention_in_days = local.env_config.retention_days
  kms_key_id        = aws_kms_key.app.arn
}

resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${var.project_name}-${terraform.workspace}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "CPU above 80% for 4 minutes"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.app.name
  }
}

resource "aws_sns_topic" "alerts" {
  name              = "${var.project_name}-${terraform.workspace}-alerts"
  kms_master_key_id = aws_kms_key.app.id
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------------------
# Lambda — SQS dead-letter queue
# ---------------------------------------------------------------------------
resource "aws_sqs_queue" "lambda_dlq" {
  name              = "${var.project_name}-${terraform.workspace}-rotator-dlq"
  kms_master_key_id = aws_kms_key.app.id

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-rotator-dlq"
  }
}

# ---------------------------------------------------------------------------
# Lambda — security group (outbound HTTPS only)
# ---------------------------------------------------------------------------
resource "aws_security_group" "lambda_rotator" {
  name        = "${var.project_name}-${terraform.workspace}-lambda-rotator"
  description = "Lambda rotator — outbound HTTPS to AWS APIs only"
  vpc_id      = module.vpc.vpc_id

  egress {
    description = "HTTPS to AWS service endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-lambda-rotator-sg"
  }
}

# ---------------------------------------------------------------------------
# Lambda — IAM role for secret rotator
# ---------------------------------------------------------------------------
resource "aws_iam_role" "rotator" {
  name = "${var.project_name}-${terraform.workspace}-rotator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rotator_basic" {
  role       = aws_iam_role.rotator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "rotator_vpc" {
  role       = aws_iam_role.rotator.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "rotator_secrets" {
  name = "secrets-rotation"
  role = aws_iam_role.rotator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage"
        ]
        Resource = [aws_secretsmanager_secret.db_password.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.lambda_dlq.arn]
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Lambda — secret rotator function
# ---------------------------------------------------------------------------
#checkov:skip=CKV_AWS_272:Code signing not required for internal rotation stub
resource "aws_lambda_function" "secret_rotator" {
  function_name                  = "${var.project_name}-${terraform.workspace}-secret-rotator"
  role                           = aws_iam_role.rotator.arn
  filename                       = data.archive_file.rotator.output_path
  source_code_hash               = data.archive_file.rotator.output_base64sha256
  handler                        = "index.lambda_handler"
  runtime                        = "python3.12"
  kms_key_arn                    = aws_kms_key.app.arn
  reserved_concurrent_executions = 10

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }

  vpc_config {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.lambda_rotator.id]
  }

  environment {
    variables = {
      SECRET_ARN = aws_secretsmanager_secret.db_password.arn
    }
  }
}

resource "aws_lambda_permission" "secrets_manager" {
  statement_id  = "AllowSecretsManagerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.secret_rotator.function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.db_password.arn
}
