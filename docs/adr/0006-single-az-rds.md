# ADR-0006: Single-AZ RDS for Both Environments

**Status:** Accepted

## Context
Multi-AZ RDS provides automatic failover but doubles the RDS cost.

## Decision
Single-AZ RDS for both dev and prod in this learning project.

## Consequences
- Cost saving: ~50% reduction in RDS cost
- Trade-off: no automatic failover during AZ outage
- In real production: enable Multi-AZ, use `db.r7g.large` or higher, 30-day backups, deletion protection
