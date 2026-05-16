#!/bin/bash
# ==========================================================
# setup-cluster.sh — Run AFTER terraform apply
# Installs everything on the EKS cluster in the correct order:
#   1. kubectl config
#   2. Namespaces
#   3. ArgoCD
#   4. External Secrets Operator
#   5. AWS Load Balancer Controller
#   6. ClusterSecretStore + ExternalSecrets
#   7. ArgoCD Applications
#   8. Monitoring stack
#   9. Ingresses
#
# Usage:
#   ./scripts/setup-cluster.sh        # defaults to dev
#   ./scripts/setup-cluster.sh prod
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

echo "=============================================="
echo " setup-cluster.sh — environment: ${ENV}"
echo "=============================================="

# ── Verify dependencies ───────────────────────────────────────────────────────
for cmd in kubectl helm aws terraform yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed."
    exit 1
  fi
done

# ── Read terraform outputs (all paths derived, nothing hardcoded) ─────────────
echo "[0/9] Reading Terraform outputs..."
cd "${TF_DIR}"

CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION=$(terraform output 2>/dev/null | grep -q "aws_region" \
  && terraform output -raw aws_region 2>/dev/null \
  || aws configure get region 2>/dev/null \
  || echo "ap-south-1")
LB_ROLE_ARN=$(terraform output -raw lb_controller_role_arn)
VPC_ID=$(terraform output -raw vpc_id)
ESO_ROLE_ARN=$(terraform output -raw eso_role_arn)
CERT_ARN=$(terraform output -raw certificate_arn)

cd "${REPO_ROOT}"

echo "  Cluster     : ${CLUSTER_NAME}"
echo "  Region      : ${AWS_REGION}"
echo "  LB Role ARN : ${LB_ROLE_ARN}"
echo "  VPC ID      : ${VPC_ID}"
echo "  ESO Role ARN: ${ESO_ROLE_ARN}"
echo "  Cert ARN    : ${CERT_ARN}"

# ── Step 1: kubectl config ────────────────────────────────────────────────────
echo ""
echo "[1/9] Configuring kubectl..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

echo "  Waiting for nodes to be Ready (up to 5 min)..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes
echo "  ✅ kubectl configured"

# ── Step 2: Namespaces ────────────────────────────────────────────────────────
echo ""
echo "[2/9] Creating namespaces..."
kubectl apply -f "${REPO_ROOT}/k8s/base/namespaces.yaml"
echo "  ✅ Namespaces created"

# ── Step 3: ArgoCD ────────────────────────────────────────────────────────────
echo ""
echo "[3/9] Installing ArgoCD..."
"${REPO_ROOT}/argocd/install/install-argocd.sh"
echo "  ✅ ArgoCD installed"

# ── Step 4: External Secrets Operator ────────────────────────────────────────
echo ""
echo "[4/9] Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --version 0.14.4 \
  --set installCRDs=true \
  --wait --timeout 120s
echo "  ✅ ESO installed (v0.14.4)"

# ── Step 5: AWS Load Balancer Controller ──────────────────────────────────────
echo ""
echo "[5/9] Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --version 1.8.1 \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${LB_ROLE_ARN}" \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --wait --timeout 120s
echo "  ✅ LB Controller installed (chart v1.8.1 = app v2.8.1)"

# ── Step 6: ClusterSecretStore + ExternalSecrets ──────────────────────────────
echo ""
echo "[6/9] Setting up External Secrets..."

kubectl apply -f "${REPO_ROOT}/k8s/base/external-secrets/serviceaccount.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/base/external-secrets/cluster-secret-store.yaml"

echo "  Waiting 15s for ClusterSecretStore to validate..."
sleep 15
kubectl get clustersecretstore

kubectl apply -f "${REPO_ROOT}/k8s/overlays/${ENV}/rds-external-secret.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/overlays/${ENV}/openai-external-secret.yaml"

echo "  Waiting 30s for secrets to sync..."
sleep 30
kubectl get externalsecret -n "petclinic-${ENV}"
echo "  ✅ Secrets configured"

# ── Step 7: ArgoCD Applications ───────────────────────────────────────────────
echo ""
echo "[7/9] Deploying ArgoCD Applications..."
kubectl apply -f "${REPO_ROOT}/argocd/applications/${ENV}/"
echo "  Waiting 60s for ArgoCD to sync..."
sleep 60
kubectl get applications -n argocd
echo "  ✅ ArgoCD applications deployed"

# ── Step 8: Monitoring stack ──────────────────────────────────────────────────
echo ""
echo "[8/9] Installing monitoring stack..."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add fluent https://fluent.github.io/helm-charts 2>/dev/null || true
helm repo update

helm upgrade --install prometheus prometheus-community/prometheus \
  -n monitoring \
  --version 25.21.0 \
  -f "${REPO_ROOT}/monitoring/prometheus-values.yaml" \
  --wait --timeout 180s

helm upgrade --install loki grafana/loki \
  -n monitoring \
  --version 6.6.2 \
  -f "${REPO_ROOT}/monitoring/loki-values.yaml"

helm upgrade --install fluent-bit fluent/fluent-bit \
  -n monitoring \
  --version 0.46.7 \
  -f "${REPO_ROOT}/monitoring/fluent-bit-values.yaml" \
  --wait --timeout 120s

helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  --version 7.3.9 \
  -f "${REPO_ROOT}/monitoring/grafana-values.yaml" \
  --wait --timeout 120s

kubectl apply -f "${REPO_ROOT}/monitoring/alertmanager.yaml"
kubectl apply -f "${REPO_ROOT}/monitoring/zipkin.yaml"

# Apply alerting rules if present
if [ -f "${REPO_ROOT}/monitoring/alerting-rules.yaml" ]; then
  kubectl apply -f "${REPO_ROOT}/monitoring/alerting-rules.yaml"
  echo "  ✅ Alerting rules applied"
fi

echo "  ✅ Monitoring stack installed"

# ── Step 9: Ingresses ─────────────────────────────────────────────────────────
echo ""
echo "[9/9] Applying ingresses..."
kubectl apply -f "${REPO_ROOT}/k8s/overlays/${ENV}/ingress.yaml"

# Apply multi-namespace monitoring ingress safely
kubectl apply -f "${REPO_ROOT}/monitoring/monitoring-ingress.yaml" 2>/dev/null || {
  yq 'select(.metadata.namespace == "monitoring")' \
    "${REPO_ROOT}/monitoring/monitoring-ingress.yaml" | kubectl apply -f -
  yq 'select(.metadata.namespace == "argocd")' \
    "${REPO_ROOT}/monitoring/monitoring-ingress.yaml" | kubectl apply -f -
}

echo "  Waiting 3 minutes for ALBs to provision..."
sleep 180

echo ""
echo "  Ingress addresses:"
kubectl get ingress -n "petclinic-${ENV}"
kubectl get ingress -n monitoring
kubectl get ingress -n argocd
echo "  ✅ Ingresses applied"

# ── Final instructions ────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Cluster setup complete!"
echo "=============================================="
echo ""
echo " Next steps:"
echo ""
echo "   1. Build and push images:"
echo "      cd ~/spring-petclinic-microservices"
echo "      ./mvnw clean install -DskipTests --no-transfer-progress --batch-mode"
echo "      cd ${REPO_ROOT}"
echo "      ./scripts/build-push-images.sh --tag v1.0.0"
echo ""
echo "   2. Inject dynamic config (ECR URLs, RDS endpoint, cert ARN, domains):"
echo "      ./scripts/generate-config.sh ${ENV}"
echo ""
echo "   3. Commit and push so ArgoCD picks up the config:"
echo "      git add helm-values/ k8s/ monitoring/ argocd/"
echo "      git commit -m 'config: update dynamic values for ${ENV}'"
echo "      git push"
echo ""
echo "   4. Wire DNS (Cloudflare CNAMEs → ALBs):"
echo "      ./scripts/update-dns-and-ingress.sh ${ENV}"
echo ""
echo "   5. Run smoke test:"
echo "      ./scripts/smoke-test.sh petclinic-${ENV}"
