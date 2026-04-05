# ── dev workspace ────────────────────────────────────────────────────────────
primary_region = "ap-south-1"
replica_region = "eu-central-1"
project_name   = "multi-region-arch"

vpc_cidr           = "10.0.0.0/16"
enable_nat_gateway = true
single_nat_gateway = true # save cost in dev

app_min_size         = 1
app_max_size         = 2
app_desired_capacity = 1

db_name     = "appdb"
db_username = "REPLACE_WITH_DB_USERNAME"

alarm_email = "REPLACE_WITH_YOUR_EMAIL"
