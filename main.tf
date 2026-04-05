# ---------------------------------------------------------------------------
# VPC
# ---------------------------------------------------------------------------
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
# Data sources
# ---------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = aws_secretsmanager_secret.db_password.id

  depends_on = [aws_secretsmanager_secret_version.db_password_initial]
}

# ---------------------------------------------------------------------------
# KMS key for application-level encryption
# ---------------------------------------------------------------------------
resource "aws_kms_key" "app" {
  description             = "${var.project_name}-${terraform.workspace} app encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

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
# RDS — PostgreSQL
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
  description = "Allow PostgreSQL from app tier"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-rds-sg"
  }
}

resource "aws_db_instance" "main" {
  identifier             = "${var.project_name}-${terraform.workspace}"
  engine                 = "postgres"
  engine_version         = "15.4"
  instance_class         = local.env_config.db_instance
  allocated_storage      = 20
  max_allocated_storage  = 100
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.app.arn
  db_name                = var.db_name
  username               = var.db_username
  password               = data.aws_secretsmanager_secret_version.db_password.secret_string
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  multi_az               = local.env_config.multi_az
  skip_final_snapshot    = !local.env_config.deletion_protect
  deletion_protection    = local.env_config.deletion_protect
  backup_retention_period = local.env_config.retention_days
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-rds"
  }
}

# ---------------------------------------------------------------------------
# Application security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.project_name}-${terraform.workspace}-app"
  description = "Application tier security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-app-sg"
  }
}

# ---------------------------------------------------------------------------
# ALB security group
# ---------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.project_name}-${terraform.workspace}-alb"
  description = "ALB security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-alb-sg"
  }
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------
resource "aws_lb" "main" {
  name               = "${var.project_name}-${terraform.workspace}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = local.env_config.deletion_protect

  tags = {
    Name = "${var.project_name}-${terraform.workspace}-alb"
  }
}

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
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

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
    # Application bootstrap would go here
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
# CloudWatch — log group + CPU alarm
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
# Lambda stub for secret rotation (placeholder — wire your real rotator here)
# ---------------------------------------------------------------------------
data "archive_file" "rotator" {
  type        = "zip"
  output_path = "${path.module}/.terraform/rotator.zip"

  source {
    content  = "def lambda_handler(e, c): pass"
    filename = "index.py"
  }
}

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

resource "aws_lambda_function" "secret_rotator" {
  function_name    = "${var.project_name}-${terraform.workspace}-secret-rotator"
  role             = aws_iam_role.rotator.arn
  filename         = data.archive_file.rotator.output_path
  source_code_hash = data.archive_file.rotator.output_base64sha256
  handler          = "index.lambda_handler"
  runtime          = "python3.12"
  kms_key_arn      = aws_kms_key.app.arn

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
}
