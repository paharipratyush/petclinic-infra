# Petclinic Platform — Onboarding Guide

> **Goal:** Get you productive in under 90 minutes.

## Prerequisites

Install these tools before starting:

| Tool | Install | Version |
|------|---------|---------|
| AWS CLI | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html | v2+ |
| Terraform | https://developer.hashicorp.com/terraform/install | >= 1.10 |
| kubectl | https://kubernetes.io/docs/tasks/tools/ | latest |
| Helm | https://helm.sh/docs/intro/install/ | v3+ |
| Docker Desktop | https://www.docker.com/products/docker-desktop/ | latest |
| yq | https://github.com/mikefarah/yq#install | v4+ |
| git | Already installed on most systems | - |
| gh CLI | https://cli.github.com | latest |

## Step 1 — AWS Access (10 min)

```bash
# Configure AWS CLI with your credentials
aws configure
# Enter: Access Key ID, Secret Access Key, Region (ap-south-1), Output (json)

# Verify access
aws sts get-caller-identity
```

## Step 2 — Clone Repositories (5 min)

```bash
# Create a working directory
mkdir ~/petclinic && cd ~/petclinic

# Clone the infra repo (this repo)
git clone https://github.com/{your-org}/petclinic-infra.git

# Clone your fork of the app repo
git clone https://github.com/{your-username}/spring-petclinic-microservices.git
```

## Step 3 — Bootstrap State Backend (5 min)

This creates the S3 bucket for Terraform state. Run once per AWS account.

```bash
cd petclinic-infra
chmod +x scripts/*.sh
./scripts/bootstrap-state.sh
```

## Step 4 — Configure Your Environment (10 min)

```bash
# Copy example config
cp terraform/environments/dev/terraform.tfvars.example \
   terraform/environments/dev/terraform.tfvars

# Edit with your values
nano terraform/environments/dev/terraform.tfvars
```

Required values to fill in:
- `aws_region` — your AWS region (e.g. `ap-south-1`)
- `domain_name` — your domain (e.g. `example.com`)
- `iam_admin_username` — your IAM username
- `github_org` — your GitHub username
- `cloudflare_zone_id` — from Cloudflare dashboard → your domain → Zone ID
- `cloudflare_api_token` — Cloudflare API token with DNS edit permissions

## Step 5 — Deploy Infrastructure (30 min)

```bash
cd petclinic-infra

# Preview what will be created
./scripts/tf.sh dev plan

# Deploy (takes ~15 min — EKS cluster creation)
./scripts/tf.sh dev apply
```

## Step 6 — Configure Cluster (20 min)

```bash
# Inject dynamic values (ECR URLs, RDS endpoint, cert ARN, domains)
./scripts/generate-config.sh dev

# Commit the generated config
git add helm-values/ k8s/ monitoring/ argocd/
git commit -m "config: update dynamic values for dev"
git push

# Set up the cluster (installs ArgoCD, ESO, LB Controller, monitoring)
./scripts/setup-cluster.sh dev
```

## Step 7 — Build and Push Images (15 min)

```bash
# Build all JARs
cd ~/petclinic/spring-petclinic-microservices
./mvnw clean install -DskipTests --no-transfer-progress --batch-mode

# Build ARM64 images and push to ECR
cd ~/petclinic/petclinic-infra
./scripts/build-push-images.sh --tag v1.0.0

# Update helm-values with the new tag
./scripts/generate-config.sh dev
git add helm-values/
git commit -m "config: initial image tags v1.0.0"
git push
```

## Step 8 — Wire DNS (5 min)

```bash
./scripts/update-dns-and-ingress.sh dev
# Wait 2-5 minutes for DNS propagation
```

## Step 9 — Verify Everything Works

```bash
# Run smoke test
./scripts/smoke-test.sh petclinic-dev

# Access the app
echo "App: https://petclinic-dev.your-domain.com"
echo "Grafana: https://grafana-dev.your-domain.com"
echo "ArgoCD: https://argocd-dev.your-domain.com"
```

## Step 10 — Set Up CI/CD Pipeline (15 min)

The CI/CD pipeline automatically builds Docker images and deploys them when
code is pushed to the app repo. This step wires GitHub Actions to AWS and
connects the app repo to the infra repo.

### 10a — Authenticate GitHub CLI

```bash
gh auth login
# Choose: GitHub.com → HTTPS → Authenticate with browser
# Verify: gh auth status
```

### 10b — Create a Fine-Grained PAT

The pipeline needs write access to the infra repo to commit image tag updates.

1. Go to `https://github.com/settings/tokens?type=beta`
2. Click **Generate new token (fine-grained)**
3. Fill in:
   - **Token name:** `petclinic-platform-write`
   - **Expiration:** 90 days
   - **Resource owner:** your GitHub username
   - **Repository access:** Only select repositories → `petclinic-infra`
   - **Permissions → Contents:** Read and write
   - **Permissions → Metadata:** Read-only (auto-selected)
4. Click **Generate token**
5. Copy the token immediately — you will not see it again

### 10c — Run the Setup Script

```bash
cd ~/petclinic/petclinic-infra
./scripts/setup-github-secrets.sh
# Paste your PAT when prompted
```

This script automatically configures:

| Type | Name | Value |
|------|------|-------|
| Variable | `AWS_REGION` | `ap-south-1` |
| Variable | `AWS_ACCOUNT_ID` | Your AWS account ID |
| Variable | `PLATFORM_REPO` | `{your-username}/petclinic-infra` |
| Secret | `AWS_ROLE_ARN` | OIDC role ARN from Terraform output |
| Secret | `PLATFORM_REPO_TOKEN` | The PAT you just created |

### 10d — Verify Workflow Files Exist

The following workflow files must exist in the app repo:

```bash
ls ~/petclinic/spring-petclinic-microservices/.github/workflows/
# Expected output:
# build-push.yml        — main CI orchestrator
# ecr-build-push.yml    — reusable build/scan/push workflow
# maven-build.yml       — original Maven build (keep as-is)
```

If missing, copy them from the infra repo's docs or recreate per PETPLAT-49.

### 10e — Test the Pipeline

```bash
cd ~/petclinic/spring-petclinic-microservices

# Make a small change to trigger change detection
echo "# Pipeline test $(date)" >> spring-petclinic-api-gateway/README.md
git add spring-petclinic-api-gateway/README.md
git commit -m "ci: test pipeline trigger"
git push
```

Watch the pipeline run:
- App repo actions: `https://github.com/{your-username}/spring-petclinic-microservices/actions`
- Infra repo actions: `https://github.com/{your-username}/petclinic-infra/actions`

Expected flow:

Code push
→ detect-changes detects api-gateway changed
→ build job: ARM64 Docker build + Trivy scan + ECR push (~3-5 min)
→ notify job: dispatches to petclinic-infra
→ update-image-tags: commits new tag to helm-values/api-gateway.yaml
→ ArgoCD detects Git change → deploys new image (~3 min)

### 10f — Trigger ArgoCD Sync (Optional — speeds up deployment)

ArgoCD auto-syncs every 3 minutes. For immediate deployment:

```bash
kubectl annotate application api-gateway-dev -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

### CI/CD Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Build fails: `OIDC error` | OIDC role not configured | Check `AWS_ROLE_ARN` secret is set |
| Build fails: `ECR not found` | Wrong account/region | Check `AWS_ACCOUNT_ID` and `AWS_REGION` variables |
| Infra workflow fails: `403` | Wrong token | Regenerate PAT, re-run `setup-github-secrets.sh` |
| ArgoCD not syncing | Tag not updated in Git | Check infra repo actions tab |
| Pod stuck in `ImagePullBackOff` | Image not in ECR | Check ECR console for the image tag |

## Step 11 — Explore the Platform

```bash
# See all running pods
kubectl get pods -n petclinic-dev

# Check ArgoCD applications
kubectl get applications -n argocd

# Check metrics in Grafana
# https://grafana-dev.your-domain.com

# Make a code change and watch it deploy end-to-end
cd ~/petclinic/spring-petclinic-microservices
echo "# test" >> spring-petclinic-vets-service/README.md
git add . && git commit -m "feat: update vets-service" && git push
# Watch: GitHub Actions → infra tag update → ArgoCD sync → new pod
```

## Cost Reminder

EKS costs $0.10/hour (~$73/month). **Destroy after each session:**

```bash
./scripts/pre-destroy.sh --env dev
cd terraform/environments/dev && terraform destroy
```

## Getting Help

- **Architecture:** `docs/architecture.md`
- **Operations:** `docs/runbook.md`
- **Incidents:** `docs/incident-playbook.md`
- **Why we made each decision:** `docs/adr/`
- **CI/CD secrets setup:** `scripts/setup-github-secrets.sh`
