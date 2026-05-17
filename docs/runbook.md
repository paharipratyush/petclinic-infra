# Petclinic Platform — Operations Runbook

## Prerequisites

```bash
# Configure kubectl
aws eks update-kubeconfig --name petclinic-dev --region ap-south-1

# Verify cluster access
kubectl get nodes
kubectl get pods -n petclinic-dev
```

---

## Restart a Service

```bash
kubectl rollout restart deployment/{service-name} -n petclinic-dev

# Wait for rollout to complete
kubectl rollout status deployment/{service-name} -n petclinic-dev

# Verify pod is running
kubectl get pods -n petclinic-dev -l app.kubernetes.io/name={service-name}
```

---

## Scale a Service

### Manual scaling
```bash
kubectl scale deployment/{service-name} --replicas=3 -n petclinic-dev
```

### Check HPA status (prod only)
```bash
kubectl get hpa -n petclinic-prod
kubectl describe hpa {service-name} -n petclinic-prod
```

---

## Rollback a Deployment

### Option 1 — GitOps rollback (preferred)
```bash
# Revert the image tag commit in the infra repo
git log --oneline helm-values/   # find the bad commit
git revert {commit-sha}
git push
# ArgoCD auto-syncs dev, manual sync needed for prod
```

### Option 2 — ArgoCD rollback
```bash
# In ArgoCD UI: Application → History → select previous sync → Rollback
# Or via CLI:
argocd app rollback {service-name}-dev {history-id}
```

### Option 3 — Emergency kubectl rollback
```bash
kubectl rollout undo deployment/{service-name} -n petclinic-dev
```

---

## Access Logs

### Via Grafana (recommended)

https://grafana-dev.your-domain.com
→ Explore → Loki datasource
→ Query: {namespace="petclinic-dev", app_kubernetes_io_name="{service-name}"}

### Via kubectl
```bash
# Current logs
kubectl logs -f deployment/{service-name} -n petclinic-dev

# Previous pod logs (after crash)
kubectl logs deployment/{service-name} -n petclinic-dev --previous

# All pods for a service
kubectl logs -l app.kubernetes.io/name={service-name} -n petclinic-dev --all-containers
```

---

## Connect to RDS (Debug)

```bash
# Run a debug pod with MySQL client
kubectl run -it mysql-debug \
  --image=mysql:8 \
  --rm \
  --restart=Never \
  -n petclinic-dev \
  -- bash

# Inside the pod — get credentials from the K8s secret
# Username and password are in the rds-credentials secret
kubectl get secret rds-credentials -n petclinic-dev -o jsonpath='{.data.username}' | base64 -d
kubectl get secret rds-credentials -n petclinic-dev -o jsonpath='{.data.password}' | base64 -d

# Connect (get endpoint from terraform output or AWS console)
mysql -h {rds-endpoint} -u petclinic -p petclinic
```

---

## Rotate Secrets

### RDS credentials
```bash
# Generate new password in Secrets Manager
aws secretsmanager rotate-secret \
  --secret-id petclinic/dev/rds-credentials \
  --region ap-south-1

# ESO will sync the new secret within 1 hour (refresh interval)
# To force immediate sync:
kubectl annotate externalsecret rds-credentials \
  force-sync=$(date +%s) -n petclinic-dev --overwrite
```

### OpenAI API key
```bash
# Update in Secrets Manager
aws secretsmanager put-secret-value \
  --secret-id petclinic/dev/openai-api-key \
  --secret-string "sk-your-new-key" \
  --region ap-south-1

# Force ESO sync
kubectl annotate externalsecret openai-api-key \
  force-sync=$(date +%s) -n petclinic-dev --overwrite
```

---

## Run Terraform Safely

```bash
# Always plan before apply
./scripts/tf.sh dev plan
# Review the plan output carefully
./scripts/tf.sh dev apply   # applies the saved plan only
```

---

## Destroy and Recreate Stack

```bash
# Step 1: Pre-destroy cleanup (removes ALBs, ECR images)
./scripts/pre-destroy.sh --env dev

# Step 2: Destroy infrastructure
./scripts/tf.sh dev destroy

# Step 3: Recreate from scratch
./scripts/tf.sh dev init
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply

# Step 4: Setup cluster
./scripts/generate-config.sh dev
./scripts/setup-cluster.sh dev

# Step 5: Build and push images
./scripts/build-push-images.sh --tag v1.0.0

# Step 6: Commit generated config
git add helm-values/ k8s/ monitoring/ argocd/
git commit -m "config: update dynamic values for dev"
git push

# Step 7: Wire DNS
./scripts/update-dns-and-ingress.sh dev

# Step 8: Verify
./scripts/smoke-test.sh petclinic-dev
```

---

## Update EKS Version

```bash
# 1. Check current version
kubectl version --short

# 2. Update cluster version in terraform
# Edit terraform/environments/dev/terraform.tfvars:
# eks_cluster_version = "1.31"

# 3. Plan and apply
./scripts/tf.sh dev plan
./scripts/tf.sh dev apply

# 4. Update node group (done automatically by Terraform)
# Monitor: kubectl get nodes -w

# 5. Update add-on versions in terraform/modules/eks/main.tf
# Check compatible versions: aws eks describe-addon-versions --kubernetes-version 1.31
```

---

## Check Service Health

```bash
# Run full smoke test
./scripts/smoke-test.sh petclinic-dev

# Check individual service
kubectl exec -it deployment/config-server -n petclinic-dev \
  -- wget -qO- http://localhost:8888/actuator/health

# Check Eureka registrations
kubectl exec -it deployment/discovery-server -n petclinic-dev \
  -- wget -qO- http://localhost:8761/eureka/apps | grep '<name>'
```

---

## Terraform State Operations

```bash
# List all resources in state
cd terraform/environments/dev
terraform state list

# Import existing resource
terraform import module.vpc.aws_vpc.main vpc-12345678

# Remove resource from state (without destroying)
terraform state rm module.vpc.aws_vpc.main

# Recover from state lock stuck
terraform force-unlock {lock-id}

# Recover from state corruption — use S3 versioning
aws s3api list-object-versions \
  --bucket petclinic-terraform-state-{account}-ap-south-1 \
  --prefix petclinic/dev/terraform.tfstate
```
