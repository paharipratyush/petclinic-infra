# Petclinic Platform — Compliance Checklist

## Encryption at Rest

| Resource | Status | Key |
|----------|--------|-----|
| RDS MySQL | ✅ Encrypted | AWS default KMS |
| S3 (Terraform state) | ✅ SSE-S3 (AES256) | AWS managed |
| EBS Volumes (nodes, PVCs) | ✅ Default encryption | AWS managed |
| ECR Images | ✅ AES256 | AWS managed |
| Secrets Manager | ✅ KMS | `aws/secretsmanager` |

## Encryption in Transit

| Path | Status | Method |
|------|--------|--------|
| ALB → Internet | ✅ TLS 1.2+ | ACM Certificate |
| Internal K8s | ⚠️ HTTP (internal only) | VPC network boundary |
| App → RDS | ⚠️ SSL available, not enforced | Configure `spring.datasource.ssl=true` to enforce |

## IAM Roles Inventory

| Role | Permissions | Scope |
|------|------------|-------|
| `petclinic-{env}-eks-cluster-role` | AmazonEKSClusterPolicy | EKS control plane |
| `petclinic-{env}-eks-node-role` | Worker, CNI, ECR read | EKS nodes |
| `petclinic-{env}-ebs-csi-role` | AmazonEBSCSIDriverPolicy | EBS volumes |
| `petclinic-{env}-lb-controller-role` | ALB management | Load balancers |
| `petclinic-{env}-eso-role` | secretsmanager:Get/Describe on `petclinic/*` | Secrets sync |
| `petclinic-{env}-karpenter-role` | EC2 provisioning, SQS, EKS describe | Node autoscaling |
| `petclinic-github-actions-role` | ECR push to `petclinic-{env}/*` only | CI/CD pipeline |

## Access Control

| Area | Control | Status |
|------|---------|--------|
| EKS cluster | IAM + RBAC | ✅ |
| ArgoCD | RBAC (admin + developer roles) | ✅ |
| Secrets | IAM + ESO IRSA | ✅ |
| RDS | Security Group (EKS nodes only) | ✅ |
| ECR | IAM (node read, CI push only) | ✅ |
| S3 state | IAM + public access blocked | ✅ |

## Audit Logging

| Service | Logging | Retention |
|---------|---------|-----------|
| EKS | API + audit + authenticator logs | CloudWatch |
| AWS API calls | CloudTrail | 90 days default |
| Application logs | Loki (FluentBit) | 7 days dev, 30 days prod |
| Secrets access | CloudTrail via Secrets Manager | 90 days |

## Data Classification

| Data | Classification | Storage | Protection |
|------|---------------|---------|-----------|
| Pet/owner records | PII (GDPR applicable) | RDS MySQL | Encrypted at rest, TLS in transit |
| RDS credentials | Secret | Secrets Manager | KMS encrypted |
| OpenAI API key | Secret | Secrets Manager | KMS encrypted |
| Container images | Internal | ECR Private | IAM controlled |
| Terraform state | Internal | S3 | SSE-S3, versioning |

## Data Residency

All resources deployed in `ap-south-1` (Mumbai). Change `aws_region` in `terraform.tfvars` to deploy in a different region.

## Vulnerability Scanning Schedule

| Scanner | When | Blocks |
|---------|------|--------|
| Trivy (CI) | Every image build | CRITICAL CVEs block push |
| ECR scan-on-push | Every image push | Informational (review findings) |
| Checkov | Run manually: `checkov -d terraform/` | Manual review |

**Remediation SLAs:**
- Critical: 24 hours
- High: 72 hours
- Medium: 1 week
- Low: Next sprint
