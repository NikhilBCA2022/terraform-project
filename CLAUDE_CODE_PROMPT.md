# Claude Code Bootstrap Prompt — Multi-Region Terraform Architecture

Paste this into `claude` (Claude Code CLI) after cloning the repo.

---

## Context

- **AWS Account:** 866435872216
- **Primary region:** ap-south-1
- **Replica region:** eu-central-1
- **GitHub repo:** NikhilBCA2022/terraform-project
- **Workspaces:** dev | staging | prod

---

## Task 1 — Run Bootstrap (once only)

```bash
cd bootstrap
terraform init
terraform plan -out=bootstrap.plan
terraform apply bootstrap.plan
```

Expected outputs: `state_bucket_name`, `dynamodb_lock_table`, `kms_key_arn`, `github_actions_role_arn`.

**Acceptance criteria:** All 4 outputs are non-empty and AWS resources are visible in the console.

---

## Task 2 — Fill in placeholder values

Replace all `REPLACE_WITH_*` tokens in the tfvars files:

```
envs/dev/terraform.tfvars
envs/staging/terraform.tfvars
envs/prod/terraform.tfvars
```

Required substitutions:
- `REPLACE_WITH_DB_USERNAME` → your RDS master username (e.g. `appuser`)
- `REPLACE_WITH_YOUR_EMAIL` → your alert notification email

---

## Task 3 — Validate all 3 workspaces

```bash
terraform init \
  -backend-config="bucket=tf-state-866435872216-ap-south-1" \
  -backend-config="region=ap-south-1" \
  -backend-config="dynamodb_table=tf-state-lock" \
  -backend-config="encrypt=true"

for ws in dev staging prod; do
  echo "=== Validating $ws ==="
  terraform workspace select $ws || terraform workspace new $ws
  terraform validate
  terraform plan -var-file="envs/$ws/terraform.tfvars" -no-color 2>&1 | tail -5
done
```

**Acceptance criteria:** All 3 workspaces produce `Plan: N to add, 0 to change, 0 to destroy` with no errors.

---

## Task 4 — Fix cross-module wiring

If `terraform validate` reports errors about unknown references, check:

1. `main.tf` — ensure `aws_lambda_function.secret_rotator` is declared before `aws_secretsmanager_secret_rotation`
2. `versions.tf` — confirm the `backend "s3"` block matches bootstrap outputs
3. `variables.tf` — confirm `workspace_guard` local is not referencing a null value

---

## Task 5 — Harden secrets

Ensure no secrets appear in `.tfvars` files committed to git:

```bash
grep -r "REPLACE_WITH" envs/  # should show 0 results after task 2
git diff --stat
```

Add `.gitignore` entries if needed:

```
*.tfvars
!envs/*/terraform.tfvars   # keep template files, exclude overrides
.terraform/
tfplan
*.plan
```

---

## Task 6 — Configure GitHub Actions

1. Go to **Settings → Environments** in the GitHub repo and create:
   - `dev`
   - `staging`
   - `production` (add a required reviewer for prod apply)

2. Add the OIDC role ARN as a repo secret or reference it directly in the workflow (it's already hardcoded in `.github/workflows/terraform.yml`).

3. Push to `develop` branch to trigger a dev plan.

---

## Task 7 — Enable drift detection labels

In the GitHub repo, create these labels (used by the drift detection job):
- `drift` (color: `#d93f0b`)
- `infrastructure` (color: `#0075ca`)
- `urgent` (color: `#e11d48`)

---

## Task 8 — Smoke test

```bash
# From root of repo, run dev workspace apply
terraform workspace select dev
terraform apply -var-file="envs/dev/terraform.tfvars" -auto-approve

# Confirm key outputs
terraform output alb_dns_name
terraform output workspace
```

**Acceptance criteria:** ALB DNS resolves, RDS endpoint is set, workspace output = `dev`.
