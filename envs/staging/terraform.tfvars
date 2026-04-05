# ── staging workspace ─────────────────────────────────────────────────────────
primary_region = "ap-south-1"
project_name   = "multi-region-arch"

vpc_cidr           = "10.1.0.0/16"
enable_nat_gateway = true
single_nat_gateway = false

app_min_size         = 1
app_max_size         = 3
app_desired_capacity = 2

db_name     = "appdb"
db_username = "REPLACE_WITH_DB_USERNAME"

alarm_email = "REPLACE_WITH_YOUR_EMAIL"
