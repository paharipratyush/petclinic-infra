# Petclinic Platform — Architecture

## Overview

Spring Petclinic Microservices (8 Spring Boot services) deployed on AWS EKS,
managed via Terraform IaC, deployed via ArgoCD GitOps, monitored with Prometheus/Grafana/Loki.

## Repository Structure
```
petclinic-infra/
├── terraform/           # All AWS infrastructure as code
│   ├── environments/    # Dev and prod root modules
│   └── modules/         # Reusable modules (vpc, eks, ecr, rds, dns, secrets, karpenter, github-oidc)
├── helm/                # Generic Helm chart shared by all 8 services
├── helm-values/         # Per-service and per-environment values
├── argocd/              # ArgoCD installation + Application CRDs
├── k8s/                 # Kubernetes manifests (namespaces, external-secrets, overlays)
├── monitoring/          # Prometheus, Grafana, Loki, FluentBit, Alertmanager, Zipkin
├── scripts/             # Operational scripts
└── docs/                # Documentation and ADRs
```

## AWS Infrastructure

### Network (VPC)
- **Design:** All-public subnets (see ADR-0001)
- **Dev VPC:** `10.0.0.0/16`, subnets `10.0.1.0/24` (ap-south-1a), `10.0.2.0/24` (ap-south-1b)
- **Prod VPC:** `10.1.0.0/16`, subnets `10.1.1.0/24`, `10.1.2.0/24`
- **Security groups:** 4 per env — EKS cluster, EKS node, RDS, ALB
- **No NAT Gateway** — cost optimization, SGs are the perimeter

### Compute (EKS)
- **Kubernetes:** v1.30
- **Nodes:** 2x `t4g.medium` ARM64/Graviton (free trial until Dec 2026)
- **Add-ons:** CoreDNS, kube-proxy, vpc-cni, EBS CSI Driver (all pinned versions)
- **OIDC:** Enabled for IRSA (IAM Roles for Service Accounts)
- **Node autoscaling:** Karpenter (NodePool + EC2NodeClass)

### Container Registry (ECR)
- **8 private repos** per environment: `petclinic-{env}/{service}`
- **Dev:** MUTABLE tags, **Prod:** IMMUTABLE tags
- **Lifecycle:** Keep last 10 images, expire untagged after 7 days

### Database (RDS)
- **Engine:** MySQL 8.0, `db.t4g.micro` (free tier)
- **Single shared `petclinic` database** for customers, visits, vets services (see ADR-0003)
- **Single-AZ** both environments (see ADR-0006)
- **Credentials:** Stored in AWS Secrets Manager, synced to K8s via ESO

### DNS & Ingress
- **Domain:** Managed in Cloudflare (see `docs/setup/dns-provider-guide.md` for Route53 alternative)
- **TLS:** ACM wildcard certificate, validated via Cloudflare DNS
- **Ingress:** AWS ALB Ingress Controller (IRSA), internet-facing ALB
- **Subdomains (dev):** `petclinic-dev`, `grafana-dev`, `argocd-dev`, `admin-dev`, `zipkin-dev`
- **Subdomains (prod):** `petclinic`, `grafana`, `argocd`, `admin`, `zipkin`

### Secrets Management
- **AWS Secrets Manager:** RDS credentials, OpenAI API key, Grafana password
- **External Secrets Operator:** Syncs from Secrets Manager → Kubernetes Secrets
- **ClusterSecretStore:** Single store for both petclinic namespaces and monitoring

## Application Services

| Service | Port | MySQL | Profile | Startup Order |
|---------|------|-------|---------|--------------|
| config-server | 8888 | No | `docker` | 1st |
| discovery-server | 8761 | No | `docker` | 2nd |
| api-gateway | 8080 | No | `docker` | 3rd+ |
| customers-service | 8081 | Yes | `docker,mysql` | 3rd+ |
| visits-service | 8082 | Yes | `docker,mysql` | After customers |
| vets-service | 8083 | Yes | `docker,mysql,production` | 3rd+ |
| genai-service | 8084 | No | `docker,production` | 3rd+ |
| admin-server | 9090 | No | `docker` | 3rd+ |

**Startup order enforced** via init containers (busybox wget polling health endpoints).

## Deployment Pipeline

 Developer pushes to app repo main branch
           ↓
 GitHub Actions (build-push.yml)

  - Detects changed services (paths-filter)
  - Builds linux/arm64 Docker images (QEMU + Buildx)
  - Scans with Trivy (CRITICAL gate)
  - Pushes to ECR: {account}.dkr.ecr.{region}.amazonaws.com/petclinic-dev/{service}:{sha}
  - Fires repository_dispatch to infra repo
           ↓
 GitHub Actions (update-image-tags.yml)
  - Updates helm-values/{service}.yaml image.tag = {sha}
  - Commits and pushes to infra repo
           ↓
 ArgoCD (watching infra repo)
  - Dev: auto-syncs immediately
  - Prod: queues for manual approval
           ↓
 Cluster updated


## Observability Stack

All components run in-cluster in the `monitoring` namespace (Zipkin in `tracing`).

| Component | Purpose | Port |
|-----------|---------|------|
| Prometheus | Scrapes metrics from 5 services every 15s | 9090 |
| Grafana | Dashboards + log exploration | 3000 |
| Loki | Log aggregation | 3100 |
| FluentBit | Log collection DaemonSet → Loki | - |
| Alertmanager | Alert routing and notifications | 9093 |
| Zipkin | Distributed tracing | 9411 |

**Prometheus scrapes only 5 services** (those with `micrometer-registry-prometheus`):
api-gateway, customers-service, visits-service, vets-service, genai-service.
config-server, discovery-server, admin-server do NOT have this dependency.

## Cost Estimate (Monthly)

| Resource | Cost |
|----------|------|
| EKS Control Plane | ~$73 (unavoidable) |
| EC2 Nodes (2x t4g.medium) | $0 (Graviton free trial) |
| RDS db.t4g.micro | $0 (free tier) |
| ECR | ~$1 |
| S3 + Secrets Manager | ~$2 |
| Route 53 / Cloudflare | ~$1 |
| **Total per env** | **~$77/month** |

**Destroy after each session** to avoid EKS charges: `./scripts/tf.sh dev destroy`

## Architecture Decisions

See `docs/adr/` for all 11 Architecture Decision Records.
Key decisions: ADR-0001 (public subnets), ADR-0007 (Helm), ADR-0008 (ArgoCD), ADR-0011 (Loki).
