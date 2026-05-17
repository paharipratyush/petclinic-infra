# ADR-0002: Amazon EKS over ECS

**Status:** Accepted

## Context
Both EKS and ECS can run the 8 Spring Boot microservices. ECS is simpler to operate. EKS is more complex but more widely used.

## Decision
Use Amazon EKS (Kubernetes).

## Consequences
- Industry-standard: Kubernetes skills transfer to any cloud provider
- Enables Helm, ArgoCD, Karpenter, and standard K8s tooling
- Higher learning curve than ECS
- EKS control plane costs $0.10/hr regardless of workload
