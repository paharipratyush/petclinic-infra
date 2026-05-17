# ADR-0004: Plain K8s YAML over Helm (Superseded)

**Status:** Superseded by ADR-0007

## Context
Initial design used plain Kubernetes YAML + Kustomize overlays for transparency and simplicity.

## Decision (original)
Use raw Kubernetes manifests with Kustomize for environment differences.

## Superseded by
ADR-0007 — Helm charts adopted for industry relevance and ArgoCD integration.
