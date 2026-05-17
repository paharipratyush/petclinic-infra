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

# Clone your fork of the app repo (read-only reference)
git clone https://github.com/{your-username}/spring-petclinic-microservices.git
```

## Step 3 — Bootstrap State Backend (5 min)

This creates the S3 bucket for Terraform state. Run once per AWS account.

```bash
cd petclinic-infra
chmod +x scripts/*.sh
./scripts/bootstrap-state.sh
# For DynamoDB locking instead: ./scripts/bootstrap-state.sh --locking dynamodb
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

# Initialize Terraform
./scripts/tf.sh dev init

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

## Step 10 — Explore the Platform

```bash
# See all running pods
kubectl get pods -n petclinic-dev

# Watch ArgoCD sync
kubectl port-forward svc/argocd-server -n argocd 8080:80
# Open http://localhost:8080

# Check metrics
kubectl port-forward svc/prometheus-server -n monitoring 9090:80
# Open http://localhost:9090

# Make a change and see it deploy
# Edit any file in the app repo, push to main
# Watch GitHub Actions build → ArgoCD sync → pod update
```

## Cost Reminder

EKS costs $0.10/hour. **Destroy after each session:**

```bash
./scripts/pre-destroy.sh --env dev
./scripts/tf.sh dev destroy
```

## Getting Help

- **Architecture:** `docs/architecture.md`
- **Operations:** `docs/runbook.md`
- **Incidents:** `docs/incident-playbook.md`
- **Why we made each decision:** `docs/adr/`
