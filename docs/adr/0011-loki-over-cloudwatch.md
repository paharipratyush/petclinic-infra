# ADR-0011: In-Cluster Logging (Loki) over CloudWatch Logs

**Status:** Accepted

## Context
Centralized log aggregation options: CloudWatch Logs (AWS-managed) or Loki (in-cluster, open source).

## Decision
Loki + FluentBit in-cluster. FluentBit DaemonSet collects pod logs and forwards to Loki. Grafana queries Loki as a datasource alongside Prometheus.

## Consequences
- No IRSA role required for FluentBit (Loki is in-cluster, no AWS API calls)
- Unified observability in one Grafana instance (metrics + logs + traces)
- LogQL for log queries alongside PromQL for metrics
- Cost: EBS storage only (included in node costs)
- Trade-off: must manage Loki storage and retention yourself
