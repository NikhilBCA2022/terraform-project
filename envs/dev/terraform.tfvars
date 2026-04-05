# ── dev workspace ────────────────────────────────────────────────────────────
primary_region = "ap-south-1"
replica_region = "eu-central-1"
project_name   = "multi-region-arch"

vpc_cidr           = "10.0.0.0/16"
enable_nat_gateway = true
single_nat_gateway = true # save cost in dev

app_instance_type    = "t3.micro"
app_min_size         = 1
app_max_size         = 2
app_desired_capacity = 1

db_instance_class = "db.t3.micro"
db_name           = "appdb"
db_username       = "REPLACE_WITH_DB_USERNAME"
db_multi_az       = false

log_retention_days = 7
alarm_email        = "REPLACE_WITH_YOUR_EMAIL"
