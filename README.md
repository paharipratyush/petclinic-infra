# Petclinic Platform — AWS Infrastructure

Production AWS infrastructure for [Spring Petclinic Microservices](https://github.com/spring-petclinic/spring-petclinic-microservices) — 8 Spring Boot services deployed on Amazon EKS with full GitOps, observability, and security.

> **Reproducible by design.** Anyone with an AWS account, a domain name, and a GitHub account can deploy this from scratch using the scripts in this repo.

---

## What This Repo Does

Takes Spring Petclinic Microservices from Docker Compose to production on AWS:

```
Docker Compose (local)
      ↓
AWS EKS (production)

 - Terraform manages all AWS infrastructure
 - Helm packages all 8 services with a single generic chart
 - ArgoCD handles all deployments (GitOps)
 - GitHub Actions builds and pushes images (CI only)
 - Prometheus + Grafana + Loki + Zipkin for observability
 - Karpenter for node autoscaling
```

---

## Architecture
```
Internet
   │
   ▼
Cloudflare DNS (CNAME)
   │
   ▼
AWS ACM (TLS termination)
   │
   ▼
AWS ALB (created by ALB Ingress Controller)
│
├─→ petclinic-dev.your-domain.com → api-gateway:8080
├─→ admin-dev.your-domain.com     → admin-server:9090
├─→ grafana-dev.your-domain.com   → grafana:3000
├─→ argocd-dev.your-domain.com    → argocd-server:80
└─→ zipkin-dev.your-domain.com    → zipkin:9411
   │
   ▼
Amazon EKS (Kubernetes 1.30)
Nodes: 2x t4g.medium ARM64/Graviton
│
┌─────┴──────────────────────────┐
│ petclinic-dev namespace        │
│  config-server   :8888         │
│  discovery-server:8761         │
│  api-gateway     :8080  ←ALB  │
│  customers-service:8081        │
│  visits-service  :8082         │──→ RDS MySQL (db.t4g.micro)
│  vets-service    :8083         │
│  genai-service   :8084         │──→ AWS Secrets Manager
│  admin-server    :9090  ←ALB  │
└────────────────────────────────┘
│
┌─────┴──────────────────────────┐
│ monitoring namespace           │
│  Prometheus, Grafana, Loki     │
│  FluentBit, Alertmanager       │
└────────────────────────────────┘
│
┌─────┴──────────────────────────┐
│ tracing namespace              │
│  Zipkin                        │
└────────────────────────────────┘
```

### Tech Stack

| Layer | Tool | Details |
|-------|------|---------|
| Cloud | AWS | Any region |
| IaC | Terraform >= 1.10 | S3 backend, modular |
| Cluster | Amazon EKS 1.30 | ARM64 Graviton nodes |
| Registry | Amazon ECR | Private, scan-on-push |
| Database | Amazon RDS MySQL 8.0 | Shared `petclinic` DB |
| DNS | Cloudflare (or Route 53) | Wildcard ACM cert |
| Secrets | AWS Secrets Manager + ESO | No secrets in Git |
| Ingress | AWS ALB Ingress Controller | IRSA, internet-facing |
| Packaging | Helm | Generic chart, per-service values |
| GitOps | ArgoCD | Auto-sync dev, manual prod |
| CI | GitHub Actions | OIDC, ARM64 builds, Trivy |
| Metrics | Prometheus + Grafana | 5 services instrumented |
| Logging | Loki + FluentBit | In-cluster, no CloudWatch |
| Tracing | Zipkin | OpenTelemetry |
| Autoscaling | Karpenter | NodePool + EC2NodeClass |

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | v2+ | [docs](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Terraform | >= 1.10 | [docs](https://developer.hashicorp.com/terraform/install) |
| kubectl | latest | [docs](https://kubernetes.io/docs/tasks/tools/) |
| Helm | v3+ | [docs](https://helm.sh/docs/intro/install/) |
| Docker Desktop | latest | [docs](https://www.docker.com/products/docker-desktop/) |
| yq | v4+ | [docs](https://github.com/mikefarah/yq#install) |
| git | any | pre-installed |

You also need:
- **AWS account** with IAM user that has sufficient permissions
- **Domain name** managed in Cloudflare (or Route 53 — see `docs/setup/dns-provider-guide.md`)
- **GitHub account** with a fork of [spring-petclinic-microservices](https://github.com/spring-petclinic/spring-petclinic-microservices)

---

## Quick Start (Full Deployment)

### Step 1 — Clone repos

```bash
mkdir ~/petclinic && cd ~/petclinic
git clone https://github.com/your-username/petclinic-infra.git
git clone https://github.com/your-username/spring-petclinic-microservices.git
cd petclinic-infra
chmod +x scripts/*.sh
```

### Step 2 — Configure AWS and Terraform

```bash
# Configure AWS credentials
aws configure

# Bootstrap Terraform state backend (run once per AWS account)
./scripts/bootstrap-state.sh
# For DynamoDB locking: ./scripts/bootstrap-state.sh --locking dynamodb

# Copy and fill in your values
cp terraform/environments/dev/terraform.tfvars.example \
   terraform/environments/dev/terraform.tfvars
nano terraform/environments/dev/terraform.tfvars
```

**Required values in `terraform.tfvars`:**
| Variable | Description | Example |
|----------|-------------|---------|
| `aws_region` | Your AWS region | `ap-south-1` |
| `domain_name` | Your domain | `example.com` |
| `iam_admin_username` | Your IAM username | `my-iam-user` |
| `github_org` | Your GitHub username | `myusername` |
| `cloudflare_zone_id` | Cloudflare Zone ID | from Cloudflare dashboard |
| `cloudflare_api_token` | Cloudflare API token | DNS edit permissions |

### Step 3 — Deploy AWS Infrastructure

```bash
# Initialize and deploy (~15 min — EKS takes time)
./scripts/tf.sh dev init
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply
```

### Step 4 — Inject Dynamic Config

```bash
# Updates ECR URLs, RDS endpoint, cert ARN, domain names in all config files
./scripts/generate-config.sh dev

# Commit the generated config so ArgoCD can read it
git add helm-values/ k8s/ monitoring/ argocd/
git commit -m "config: update dynamic values for dev"
git push
```

### Step 5 — Setup the Cluster

```bash
# Installs: ArgoCD, ESO, ALB Controller, Monitoring stack, Ingresses
./scripts/setup-cluster.sh dev
```

### Step 6 — Build and Push Images

```bash
# Build all JARs
cd ../spring-petclinic-microservices
./mvnw clean install -DskipTests --no-transfer-progress --batch-mode
cd ../petclinic-infra

# Build ARM64 images and push to ECR
./scripts/build-push-images.sh --tag v1.0.0

# Update image tags in helm-values
./scripts/generate-config.sh dev
git add helm-values/
git commit -m "config: initial image tags v1.0.0"
git push
```

### Step 7 — Wire DNS

```bash
./scripts/update-dns-and-ingress.sh dev
```

### Step 8 — Verify

```bash
./scripts/smoke-test.sh petclinic-dev
```

Your app is live at:
- **App:** `https://petclinic-dev.your-domain.com`
- **Grafana:** `https://grafana-dev.your-domain.com`
- **ArgoCD:** `https://argocd-dev.your-domain.com`
- **Zipkin:** `https://zipkin-dev.your-domain.com`

---

## CI/CD Pipeline
```
App repo (spring-petclinic-microservices)
push to main
   ↓
GitHub Actions: build-push.yml

 - Changed services detected (paths-filter)
 - ARM64 images built (QEMU + Buildx)
 - Trivy scan (CRITICAL blocks push)
 - Images pushed to ECR: {account}.dkr.ecr.{region}.amazonaws.com/petclinic-dev/{service}:{sha}
 - repository_dispatch fired to infra repo
   ↓
Infra repo (petclinic-infra)
GitHub Actions: update-image-tags.yml

 - helm-values/{service}.yaml image.tag updated to {sha}
 - Committed and pushed
   ↓ 
ArgoCD (watching infra repo)
Dev:  auto-syncs immediately
Prod: queues for manual approval in ArgoCD UI
```

### Setup CI/CD

1. Add `AWS_ROLE_ARN` secret to your app repo (from `terraform output github_actions_role_arn`)
2. Add `AWS_REGION` and `AWS_ACCOUNT_ID` variables to your app repo
3. Add `PLATFORM_REPO_TOKEN` secret — GitHub PAT with write access to infra repo
4. Add `PLATFORM_REPO` variable — `your-username/petclinic-infra`

---

## Environments

| Setting | Dev | Prod |
|---------|-----|------|
| VPC CIDR | `10.0.0.0/16` | `10.1.0.0/16` |
| K8s namespace | `petclinic-dev` | `petclinic-prod` |
| ECR tag mutability | MUTABLE | IMMUTABLE |
| ArgoCD sync | Auto | Manual approval |
| Replicas | 1 per service | 2+ per service |
| HPA | Disabled | Enabled |
| PDB | Disabled | Enabled |
| Subdomain prefix | `petclinic-dev.` | `petclinic.` |

---

## Repository Structure
```
petclinic-infra/
│
├── terraform/
│   ├── environments/
│   │   ├── dev/          # Dev root module
│   │   └── prod/         # Prod root module
│   └── modules/
│       ├── vpc/          # VPC, subnets, security groups
│       ├── eks/          # EKS cluster, node groups, add-ons, IRSA
│       ├── ecr/          # ECR repositories, lifecycle policies
│       ├── rds/          # RDS MySQL, credentials
│       ├── dns/          # ACM cert, Cloudflare DNS records
│       ├── secrets/      # Secrets Manager, ESO IRSA role
│       ├── karpenter/    # Karpenter IAM, SQS, EventBridge
│       └── github-oidc/  # GitHub Actions OIDC federation
│
├── helm/
│   └── petclinic-service/ # Generic chart for all 8 services
│
├── helm-values/
│   ├── {service}.yaml     # Per-service config (port, image, env vars)
│   ├── dev.yaml           # Dev overrides (1 replica, no HPA)
│   └── prod.yaml          # Prod overrides (HPA enabled, PDB enabled)
│
├── argocd/
│   ├── install/           # ArgoCD installation script
│   ├── applications/dev/  # 9 ArgoCD Application CRDs (auto-sync)
│   ├── applications/prod/ # 9 ArgoCD Application CRDs (manual sync)
│   └── argocd-rbac-cm.yaml
│
├── k8s/
│   ├── base/
│   │   ├── namespaces.yaml
│   │   ├── external-secrets/  # ClusterSecretStore, ServiceAccount
│   │   └── karpenter/         # NodePool, EC2NodeClass, Spot override
│   └── overlays/
│       ├── dev/    # ExternalSecrets, Ingress for dev
│       └── prod/   # ExternalSecrets, Ingress for prod
│
├── monitoring/
│   ├── prometheus-values.yaml  # Scrape config + alert rules
│   ├── grafana-values.yaml     # Datasources + dashboards
│   ├── loki-values.yaml
│   ├── fluent-bit-values.yaml
│   ├── alertmanager.yaml       # Deployment + PVC + routing
│   ├── zipkin.yaml             # Deployment in tracing namespace
│   └── monitoring-ingress.yaml # Grafana + ArgoCD ingresses
│
├── .github/workflows/
│   └── update-image-tags.yml   # Triggered by app repo dispatch
│
├── scripts/
│   ├── bootstrap-state.sh      # Create S3 bucket for TF state
│   ├── tf.sh                   # Terraform wrapper (handles paths)
│   ├── generate-config.sh      # Inject dynamic values after apply
│   ├── setup-cluster.sh        # Full cluster setup
│   ├── build-push-images.sh    # Build ARM64 images + push to ECR
│   ├── update-dns-and-ingress.sh # Wire Cloudflare DNS to ALBs
│   ├── smoke-test.sh           # Verify all 8 services healthy
│   └── pre-destroy.sh          # Cleanup before terraform destroy
│
├── config/                     # Generated backend HCL files (gitignored)
│
└── docs/
    ├── architecture.md
    ├── runbook.md
    ├── incident-playbook.md
    ├── onboarding.md
    ├── compliance-checklist.md
    ├── setup/
    │   └── dns-provider-guide.md
    └── adr/
        ├── 0001-public-subnets.md
        ├── 0002-eks-over-ecs.md
        ├── 0003-shared-rds.md
        ├── 0004-plain-yaml-over-helm.md
        ├── 0005-github-actions-oidc.md
        ├── 0006-single-az-rds.md
        ├── 0007-helm-over-plain-yaml.md
        ├── 0008-argocd-gitops.md
        ├── 0009-ecr-private.md
        ├── 0010-secrets-manager.md
        └── 0011-loki-over-cloudwatch.md
```
---

## Key Scripts Reference

| Script | Purpose | Usage |
|--------|---------|-------|
| `bootstrap-state.sh` | Create S3 state bucket | Run once per account |
| `tf.sh` | Terraform wrapper | `./scripts/tf.sh dev plan` |
| `generate-config.sh` | Inject post-apply dynamic values | After every `terraform apply` |
| `setup-cluster.sh` | Full cluster setup | After first `terraform apply` |
| `build-push-images.sh` | Build ARM64 + push to ECR | Initial deploy or manual rebuild |
| `update-dns-and-ingress.sh` | Wire DNS to ALBs | After ingresses are applied |
| `smoke-test.sh` | Verify all services healthy | After any deployment |
| `pre-destroy.sh` | Clean up before destroy | Before `tf.sh dev destroy` |

---

## Cost

| Resource | Monthly Cost |
|----------|-------------|
| EKS Control Plane | ~$73 (unavoidable) |
| EC2 t4g.medium nodes | $0 (Graviton free trial until Dec 2026) |
| RDS db.t4g.micro | $0 (12-month free tier) |
| ECR storage | ~$1 |
| Secrets Manager | ~$2 |
| S3, DNS, data transfer | ~$2 |
| **Per environment total** | **~$78/month** |

> **Cost tip:** EKS control plane costs $0.10/hr. Destroy after each session:
> ```bash
> ./scripts/pre-destroy.sh --env dev
> ./scripts/tf.sh dev destroy
> ```
> Target: under $10 for the entire course/project.

---

## Documentation

| Doc | Purpose |
|-----|---------|
| [Architecture](docs/architecture.md) | Full AWS + K8s architecture |
| [Runbook](docs/runbook.md) | Day-2 operations (restart, scale, rollback, RDS access) |
| [Incident Playbook](docs/incident-playbook.md) | Common failures + fixes |
| [Onboarding Guide](docs/onboarding.md) | New engineer setup in <90 min |
| [Compliance Checklist](docs/compliance-checklist.md) | Security + encryption + IAM audit |
| [DNS Provider Guide](docs/setup/dns-provider-guide.md) | Cloudflare + Route 53 setup |
| [ADRs](docs/adr/) | All 11 architecture decision records |

---

## DNS Provider Options

This repo defaults to **Cloudflare** for DNS. If you use Route 53, follow the migration steps in `docs/setup/dns-provider-guide.md`.

| Provider | Setup Effort | Cost |
|----------|-------------|------|
| Cloudflare | Add zone_id + API token to tfvars | Free |
| Route 53 | Domain must be in Route 53 | ~$0.50/zone/month |

---

## Security Notes

- No secrets committed to Git — all via AWS Secrets Manager + ESO
- GitHub Actions uses OIDC federation — no long-lived AWS keys
- ECR prod repos use IMMUTABLE tags — deployed images can't be overwritten
- All S3 buckets have public access blocked
- RDS only reachable from EKS nodes (security group restriction)
- ArgoCD RBAC: admin full access, developer can only sync dev

---

## Application Services

| Service | Port | Role |
|---------|------|------|
| config-server | 8888 | Git-backed config for all services |
| discovery-server | 8761 | Eureka service registry |
| api-gateway | 8080 | Routes all traffic, serves frontend |
| customers-service | 8081 | Owners + pets data (MySQL) |
| visits-service | 8082 | Visit records (MySQL) |
| vets-service | 8083 | Vet data + Caffeine cache (MySQL) |
| genai-service | 8084 | AI chatbot via Spring AI + OpenAI |
| admin-server | 9090 | Spring Boot Admin dashboard |

Source: [spring-petclinic-microservices](https://github.com/spring-petclinic/spring-petclinic-microservices)
