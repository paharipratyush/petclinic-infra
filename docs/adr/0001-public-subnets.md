# ADR-0001: All-Public Subnet Design (No NAT Gateway)

**Status:** Accepted
**Date:** 2025

## Context
Standard AWS production architectures use private subnets with NAT Gateways for outbound internet access. However, NAT Gateways cost a minimum of ~$35/month plus data transfer fees.

## Decision
Use all-public subnets for all resources (EKS nodes, RDS, ALB). Security groups enforce access control as the primary network boundary.

## Consequences
- **Cost saving:** ~$35-65/month per environment (significant for a learning project)
- **Trade-off:** Nodes have public IPs. This is mitigated by security groups which restrict all inbound traffic
- **Security groups are the perimeter:** Must be treated as strictly as private subnet firewalls
- In real production at scale: use private subnets + NAT Gateway for defense in depth
