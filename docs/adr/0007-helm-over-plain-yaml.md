# ADR-0007: Helm over Plain K8s YAML (Supersedes ADR-0004)

**Status:** Accepted

## Context
Plain YAML + Kustomize creates maintenance burden: 8 services × 2 environments = 16 manifest sets. Any label change requires 16 edits.

## Decision
Single generic Helm chart (`helm/petclinic-service/`) shared by all 8 services. Per-service and per-environment configuration in `helm-values/` files.

## Consequences
- Single chart template maintains consistency across all services
- Values merge order: defaults → per-service → per-environment
- ArgoCD natively supports Helm chart + values files deployment
- Trade-off: Helm templating is less transparent than raw YAML
