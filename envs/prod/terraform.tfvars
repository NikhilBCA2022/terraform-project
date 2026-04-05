# ── prod workspace ────────────────────────────────────────────────────────────
primary_region = "ap-south-1"
replica_region = "eu-central-1"
project_name   = "multi-region-arch"

vpc_cidr           = "10.2.0.0/16"
enable_nat_gateway = true
single_nat_gateway = false

app_instance_type    = "t3.medium"
app_min_size         = 2
app_max_size         = 10
app_desired_capacity = 3

db_instance_class = "db.t3.medium"
db_name           = "appdb"
db_username       = "REPLACE_WITH_DB_USERNAME"
db_multi_az       = true

log_retention_days = 90
alarm_email        = "REPLACE_WITH_YOUR_EMAIL"
