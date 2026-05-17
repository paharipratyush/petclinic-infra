# ADR-0010: AWS Secrets Manager for Secrets Storage

**Status:** Accepted

## Context
Application secrets (RDS credentials, OpenAI API key, Grafana password) need secure storage. Options: Kubernetes Secrets (base64, not encrypted), SSM Parameter Store, or AWS Secrets Manager.

## Decision
AWS Secrets Manager + External Secrets Operator (ESO) to sync secrets into Kubernetes.

## Consequences
- Secrets encrypted at rest with KMS
- Full audit trail via CloudTrail
- ESO syncs from Secrets Manager → Kubernetes Secret on schedule
- No secrets in Git
- Cost: $0.40/secret/month (~$1.60/month for 4 secrets)
