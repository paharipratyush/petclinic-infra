# ADR-0003: Shared RDS Instance for All Services

**Status:** Accepted

## Context
Three services (customers, visits, vets) need MySQL. The application schema has cross-service foreign key constraints: `visits.pet_id` references `pets.id` (owned by customers-service).

## Decision
Single shared `petclinic` database on one RDS instance for all three services.

## Consequences
- Matches the application design (cross-service FK constraints require shared DB)
- Simpler operations: one endpoint, one secret, one backup schedule
- Lower cost: one `db.t4g.micro` vs three
- In production at scale: separate databases per service with an API for cross-service data
