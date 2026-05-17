# ADR-0009: ECR Private Registry

**Status:** Accepted

## Context
Container images need a registry. Options: Docker Hub (public), GitHub Container Registry, or Amazon ECR Private.

## Decision
Amazon ECR Private for all environments.

## Consequences
- Production-correct: IAM-controlled access, no public image exposure
- Features: lifecycle policies, scan-on-push, tag immutability (IMMUTABLE in prod)
- EKS node IAM role has `AmazonEC2ContainerRegistryReadOnly` — no credentials needed in pods
- Cost: ~$1/month beyond 500MB free tier
