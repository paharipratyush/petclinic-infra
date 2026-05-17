# ADR-0005: GitHub Actions with OIDC Federation

**Status:** Accepted

## Context
CI pipelines need AWS credentials to push images to ECR. Options: long-lived IAM access keys stored as GitHub Secrets, or short-lived credentials via OIDC federation.

## Decision
Use OIDC federation (no long-lived credentials). GitHub Actions generates a short-lived JWT per workflow run. AWS exchanges it for temporary STS credentials.

## Consequences
- No static credentials to rotate or leak
- Trust policy restricted to `ref:refs/heads/main` of the app repo only
- AWS-recommended pattern for CI/CD
