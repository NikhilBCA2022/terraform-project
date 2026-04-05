output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnets
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = aws_db_instance.main.endpoint
  sensitive   = true
}

output "db_secret_arn" {
  description = "ARN of the Secrets Manager secret for the DB password"
  value       = aws_secretsmanager_secret.db_password.arn
}

output "app_kms_key_arn" {
  description = "ARN of the application KMS key"
  value       = aws_kms_key.app.arn
}

output "sns_alerts_arn" {
  description = "ARN of the SNS alerts topic"
  value       = aws_sns_topic.alerts.arn
}

output "workspace" {
  description = "Active Terraform workspace"
  value       = terraform.workspace
}

output "env_config" {
  description = "Resolved workspace configuration"
  value       = local.env_config
}
