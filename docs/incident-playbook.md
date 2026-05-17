# Petclinic Platform — Incident Playbook

## Severity Classification

| Severity | Definition | Response Time |
|----------|-----------|--------------|
| SEV1 | Service completely down, users cannot access app | 15 min |
| SEV2 | Degraded performance, partial outage | 1 hour |
| SEV3 | Minor issue, non-critical component affected | Next business day |

---

## Scenario 1: Pod in CrashLoopBackOff

**Symptoms:** Pod repeatedly restarts, `kubectl get pods` shows `CrashLoopBackOff`

**Diagnosis:**
```bash
# Get pod details
kubectl get pods -n petclinic-dev
kubectl describe pod {pod-name} -n petclinic-dev

# Check current logs
kubectl logs {pod-name} -n petclinic-dev

# Check previous container logs (before crash)
kubectl logs {pod-name} -n petclinic-dev --previous
```

**Common causes and fixes:**

*Config Server not ready:*
```bash
# Check if config-server is healthy
kubectl exec -it deployment/discovery-server -n petclinic-dev \
  -- wget -qO- http://config-server:8888/actuator/health
# If not: kubectl rollout restart deployment/config-server -n petclinic-dev
```

*RDS connection failure:*
```bash
# Check if secret exists and has correct keys
kubectl get secret rds-credentials -n petclinic-dev -o yaml
# Check if RDS is accessible (see runbook: Connect to RDS)
```

*OOM (Out of Memory):*
```bash
# Check memory limits vs usage
kubectl top pod {pod-name} -n petclinic-dev
# Increase limits in helm-values/{service}.yaml if needed
```

---

## Scenario 2: Service Not Registering with Eureka

**Symptoms:** API gateway returns 503 for some routes, "Find Owners" or other sections missing

**Diagnosis:**
```bash
# Check Eureka registrations
kubectl exec -it deployment/discovery-server -n petclinic-dev \
  -- wget -qO- http://localhost:8761/eureka/apps | grep -i '<name>'

# Check if the specific service pod is running
kubectl get pods -n petclinic-dev -l app.kubernetes.io/name=customers-service
```

**Fix:**
```bash
# Restart the affected service — it will re-register on startup
kubectl rollout restart deployment/customers-service -n petclinic-dev

# Wait for it to appear in Eureka (30-60 seconds after pod Ready)
kubectl rollout status deployment/customers-service -n petclinic-dev
```

---

## Scenario 3: Database Connection Failures

**Symptoms:** customers/visits/vets services in error, 500 errors on data endpoints

**Diagnosis:**
```bash
# Check if RDS secret exists and is synced
kubectl get externalsecret rds-credentials -n petclinic-dev
kubectl get secret rds-credentials -n petclinic-dev

# Test connectivity from a pod
kubectl run -it mysql-debug --image=mysql:8 --rm --restart=Never -n petclinic-dev -- \
  mysql -h {rds-endpoint} -u petclinic -p{password} petclinic -e "SHOW TABLES;"
```

**Fix:**
```bash
# If secret is missing — force ESO sync
kubectl annotate externalsecret rds-credentials \
  force-sync=$(date +%s) -n petclinic-dev --overwrite

# If RDS is unreachable — check security groups in AWS Console
# RDS SG must allow port 3306 from EKS node SG

# If credentials are wrong — rotate secret (see runbook)
```

---

## Scenario 4: Image Pull Errors from ECR

**Symptoms:** Pod stuck in `ImagePullBackOff` or `ErrImagePull`

**Diagnosis:**
```bash
kubectl describe pod {pod-name} -n petclinic-dev | grep -A5 Events
# Look for: "Failed to pull image" or "unauthorized"
```

**Fix:**
```bash
# Verify image exists in ECR
aws ecr list-images \
  --repository-name petclinic-dev/customers-service \
  --region ap-south-1

# Verify node IAM role has ECR read policy
aws iam list-attached-role-policies \
  --role-name petclinic-dev-eks-node-role

# If image tag doesn't exist — check helm-values
cat helm-values/customers-service.yaml | grep tag
# Re-run CI or manually push the correct image tag
```

---

## Scenario 5: Node Not Ready

**Symptoms:** `kubectl get nodes` shows `NotReady`

**Diagnosis:**
```bash
kubectl describe node {node-name}
kubectl get events -n kube-system --sort-by='.lastTimestamp'
```

**Fix:**
```bash
# Cordon the node (stop scheduling new pods)
kubectl cordon {node-name}

# Drain the node (evict existing pods gracefully)
kubectl drain {node-name} --ignore-daemonsets --delete-emptydir-data

# If the node doesn't recover — terminate it via AWS Console
# The managed node group will replace it automatically

# Uncordon once replacement is ready
kubectl uncordon {new-node-name}
```

---

## Scenario 6: ALB Returns 502 Bad Gateway

**Symptoms:** Website shows 502 after deploy or after DNS change

**Diagnosis:**
```bash
# Check if api-gateway pod is running
kubectl get pods -n petclinic-dev -l app.kubernetes.io/name=api-gateway

# Check ingress status
kubectl get ingress petclinic-ingress -n petclinic-dev

# Check LB controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller | tail -50
```

**Common causes:**
- Health check failing: Check `/actuator/health` is returning 200
- Target group has no healthy targets: Check pod readiness probe
- Certificate ARN wrong: Run `./scripts/generate-config.sh dev` and reapply ingress

---

## Post-Incident Review Template

```
Date: ___________
Severity: SEV1 / SEV2 / SEV3
Duration: _____ minutes
Services affected: ___________

Timeline:
  HH:MM - Incident detected
  HH:MM - Investigation started
  HH:MM - Root cause identified
  HH:MM - Fix applied
  HH:MM - Service restored

Root cause: ___________

Contributing factors: ___________

Action items:
  1. [ ] ___________
  2. [ ] ___________

Prevention: ___________
```
