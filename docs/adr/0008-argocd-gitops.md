# ADR-0008: ArgoCD for GitOps CD

**Status:** Accepted

## Context
CD options: push-based (CI runs kubectl apply) or pull-based GitOps (ArgoCD watches Git).

## Decision
ArgoCD for all CD. GitHub Actions is CI-only (build, push, commit image tags). ArgoCD watches Git and syncs.

## Consequences
- Git is the source of truth for cluster state
- Dev: auto-sync (immediate deployment on Git change)
- Prod: manual sync (explicit approval required in ArgoCD UI)
- No cluster credentials in CI pipelines
- Rollback = git revert → ArgoCD syncs previous state
