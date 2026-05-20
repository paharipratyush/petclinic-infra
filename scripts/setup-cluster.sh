#!/bin/bash
# ==========================================================
# setup-cluster.sh — Run AFTER terraform apply
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

echo "=============================================="
echo " setup-cluster.sh — environment: ${ENV}"
echo "=============================================="

for cmd in kubectl helm aws terraform yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: '$cmd' is required but not installed."
    exit 1
  fi
done

# ── Read terraform outputs ────────────────────────────────────────────────────
echo ""
echo "[0/10] Reading Terraform outputs..."
cd "${TF_DIR}"

CLUSTER_NAME=$(terraform output -raw cluster_name)
LB_ROLE_ARN=$(terraform output -raw lb_controller_role_arn)
VPC_ID=$(terraform output -raw vpc_id)
ESO_ROLE_ARN=$(terraform output -raw eso_role_arn)
CERT_ARN=$(terraform output -raw certificate_arn)
KARPENTER_ROLE_ARN=$(terraform output -raw karpenter_role_arn)
KARPENTER_QUEUE=$(terraform output -raw karpenter_queue_name)
KARPENTER_INSTANCE_PROFILE=$(terraform output -raw karpenter_instance_profile_name)

cd "${REPO_ROOT}"

TFVARS="${TF_DIR}/terraform.tfvars"
AWS_REGION=$(grep "^aws_region" "${TFVARS}" \
  | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ' \
  || aws configure get region 2>/dev/null \
  || echo "ap-south-1")

echo "  Cluster              : ${CLUSTER_NAME}"
echo "  Region               : ${AWS_REGION}"
echo "  LB Role ARN          : ${LB_ROLE_ARN}"
echo "  VPC ID               : ${VPC_ID}"
echo "  ESO Role ARN         : ${ESO_ROLE_ARN}"
echo "  Cert ARN             : ${CERT_ARN}"
echo "  Karpenter Role       : ${KARPENTER_ROLE_ARN}"
echo "  Karpenter Queue      : ${KARPENTER_QUEUE}"
echo "  Karpenter Profile    : ${KARPENTER_INSTANCE_PROFILE}"

# ── Helper: check if Helm release is healthy ─────────────────────────────────
helm_release_healthy() {
  local release="$1"
  local namespace="$2"
  local min_pods="${3:-1}"

  STATUS=$(helm status "${release}" -n "${namespace}" \
    --output json 2>/dev/null | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['info']['status'])" \
    2>/dev/null || echo "not-found")

  if [ "${STATUS}" != "deployed" ]; then
    return 1
  fi

  RUNNING=$(kubectl get pods -n "${namespace}" \
    --field-selector=status.phase=Running \
    --no-headers 2>/dev/null | wc -l)

  if [ "${RUNNING}" -lt "${min_pods}" ]; then
    return 1
  fi

  return 0
}

# ── Helper: Helm install with retry ──────────────────────────────────────────
# Retries Helm installs up to 3 times with a delay between attempts.
# Handles transient API server errors (net/http: request canceled) that occur
# when EKS API server is still warming up after cluster creation.
helm_install_with_retry() {
  local max_attempts=3
  local attempt=1
  local delay=30

  while [ "${attempt}" -le "${max_attempts}" ]; do
    echo "  Attempt ${attempt}/${max_attempts}..."
    if "$@"; then
      return 0
    fi
    if [ "${attempt}" -lt "${max_attempts}" ]; then
      echo "  ⚠️  Helm install failed — waiting ${delay}s before retry..."
      sleep "${delay}"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done

  echo "  ❌ Helm install failed after ${max_attempts} attempts"
  return 1
}

# ── Step 1: kubectl config + API server readiness ────────────────────────────
echo ""
echo "[1/10] Configuring kubectl and waiting for cluster to be fully ready..."
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

echo "  Waiting for nodes to be Ready (up to 5 min)..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes

# Wait for API server to be fully stable and able to serve OpenAPI schema.
# EKS API server can take 2-5 minutes after nodes are Ready to fully
# stabilize. Helm requires OpenAPI schema for validation — if the API server
# is still warming up, Helm installs fail with "request canceled" errors.
echo "  Waiting for API server to stabilize (OpenAPI schema check)..."
for i in $(seq 1 20); do
  if kubectl get --raw /openapi/v2 &>/dev/null 2>&1; then
    echo "  ✅ API server ready (attempt ${i}/20)"
    break
  fi
  if [ "${i}" -eq 20 ]; then
    echo "  ⚠️  API server did not stabilize in time — proceeding anyway"
  else
    echo "  Waiting... attempt ${i}/20 (sleeping 15s)"
    sleep 15
  fi
done

# Extra buffer for CoreDNS and other system pods to be ready
echo "  Waiting 30s for system pods to stabilize..."
sleep 30

echo "  ✅ kubectl configured and cluster ready"

# ── Step 2: Namespaces ────────────────────────────────────────────────────────
echo ""
echo "[2/10] Creating namespaces..."
kubectl apply -f "${REPO_ROOT}/k8s/base/namespaces.yaml"
echo "  ✅ Namespaces created"

# ── Step 3: ArgoCD ────────────────────────────────────────────────────────────
echo ""
echo "[3/10] Installing ArgoCD..."
"${REPO_ROOT}/argocd/install/install-argocd.sh" --env "${ENV}"
echo "  ✅ ArgoCD installed"

# ── Step 4: External Secrets Operator ────────────────────────────────────────
echo ""
echo "[4/10] Installing External Secrets Operator..."
helm repo add external-secrets \
  https://charts.external-secrets.io 2>/dev/null || true
helm repo update

if helm_release_healthy "external-secrets" "external-secrets" 1; then
  echo "  ✅ ESO already running and healthy — skipping install"
else
  HELM_STATUS=$(helm status external-secrets -n external-secrets \
    --output json 2>/dev/null | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['info']['status'])" \
    2>/dev/null || echo "not-found")

  if [ "${HELM_STATUS}" = "pending-install" ] || \
     [ "${HELM_STATUS}" = "failed" ] || \
     [ "${HELM_STATUS}" = "pending-upgrade" ]; then
    echo "  Cleaning up stuck ESO release (status: ${HELM_STATUS})..."
    helm delete external-secrets -n external-secrets 2>/dev/null || true
    sleep 5
  fi

  for CRD in \
    clusterexternalsecrets.external-secrets.io \
    clustersecretstores.external-secrets.io \
    externalsecrets.external-secrets.io \
    secretstores.external-secrets.io; do
    kubectl patch crd "${CRD}" --type=json \
      -p='[{"op":"replace","path":"/status/storedVersions","value":["v1beta1"]}]' \
      --subresource=status 2>/dev/null || true
  done

  helm_install_with_retry helm upgrade --install external-secrets \
    external-secrets/external-secrets \
    -n external-secrets \
    --version 0.14.4 \
    --set installCRDs=true \
    --wait --timeout 10m
  echo "  ✅ ESO installed (v0.14.4)"
fi

# ── Step 5: AWS Load Balancer Controller ──────────────────────────────────────
echo ""
echo "[5/10] Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
helm repo update

if helm_release_healthy "aws-load-balancer-controller" "kube-system" 1; then
  echo "  ✅ ALB Controller already running and healthy — skipping install"
else
  helm_install_with_retry helm upgrade --install \
    aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    -n kube-system \
    --version 1.8.1 \
    --set clusterName="${CLUSTER_NAME}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${LB_ROLE_ARN}" \
    --set region="${AWS_REGION}" \
    --set vpcId="${VPC_ID}" \
    --wait --timeout 10m
  echo "  ✅ LB Controller installed (chart v1.8.1 = app v2.8.1)"
fi

# ── Step 6: External Secrets setup ───────────────────────────────────────────
echo ""
echo "[6/10] Setting up External Secrets..."

kubectl apply -f "${REPO_ROOT}/k8s/base/external-secrets/serviceaccount.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/base/external-secrets/cluster-secret-store.yaml"

echo "  Waiting 15s for ClusterSecretStore to validate..."
sleep 15
kubectl get clustersecretstore

kubectl apply -f "${REPO_ROOT}/k8s/overlays/${ENV}/rds-external-secret.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/overlays/${ENV}/openai-external-secret.yaml"
kubectl apply -f "${REPO_ROOT}/k8s/overlays/${ENV}/grafana-external-secret.yaml"

echo "  Waiting 30s for secrets to sync from Secrets Manager..."
sleep 30

echo "  Checking synced secrets..."
kubectl get externalsecret -n "petclinic-${ENV}" 2>/dev/null || true
kubectl get externalsecret -n monitoring 2>/dev/null || true
echo "  ✅ Secrets configured"

# ── Step 7: ArgoCD Applications ───────────────────────────────────────────────
echo ""
echo "[7/10] Deploying ArgoCD Applications..."
kubectl apply -f "${REPO_ROOT}/argocd/applications/${ENV}/"
echo "  Waiting 60s for ArgoCD to begin syncing..."
sleep 60
kubectl get applications -n argocd 2>/dev/null || true

# ── Schema init order fix ─────────────────────────────────────────────────────
echo "  Waiting for customers-service to be ready (DB schema init order)..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=customers-service \
  -n "petclinic-${ENV}" --timeout=300s 2>/dev/null || true
echo "  ✅ customers-service ready"

VISITS_RESTARTS=$(kubectl get pod -n "petclinic-${ENV}" \
  -l app.kubernetes.io/name=visits-service \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' \
  2>/dev/null || echo "0")
VISITS_PHASE=$(kubectl get pod -n "petclinic-${ENV}" \
  -l app.kubernetes.io/name=visits-service \
  -o jsonpath='{.items[0].status.phase}' \
  2>/dev/null || echo "")

if [ "${VISITS_RESTARTS}" -gt "0" ] || [ "${VISITS_PHASE}" = "Failed" ]; then
  echo "  visits-service has ${VISITS_RESTARTS} restart(s) — restarting..."
  VISITS_POD=$(kubectl get pod -n "petclinic-${ENV}" \
    -l app.kubernetes.io/name=visits-service \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "${VISITS_POD}" ]; then
    kubectl delete pod "${VISITS_POD}" -n "petclinic-${ENV}" 2>/dev/null || true
    echo "  ✅ visits-service pod restarted"
  fi
else
  echo "  ✅ visits-service starting cleanly"
fi

echo "  ✅ ArgoCD applications deployed"

# ── Step 8: Karpenter ─────────────────────────────────────────────────────────
echo ""
echo "[8/10] Installing Karpenter..."

if helm_release_healthy "karpenter" "kube-system" 1; then
  echo "  ✅ Karpenter already running and healthy — skipping install"
else
  helm_install_with_retry helm upgrade --install karpenter \
    oci://public.ecr.aws/karpenter/karpenter \
    --version 1.1.1 \
    -n kube-system \
    --set "settings.clusterName=${CLUSTER_NAME}" \
    --set "settings.interruptionQueue=${KARPENTER_QUEUE}" \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${KARPENTER_ROLE_ARN}" \
    --set controller.resources.requests.cpu=100m \
    --set controller.resources.requests.memory=256Mi \
    --wait --timeout 10m
  echo "  ✅ Karpenter installed (v1.1.1)"
fi

echo "  Applying NodePool and EC2NodeClass for ${ENV}..."
sed \
  -e "s|karpenter.sh/discovery: petclinic-dev|karpenter.sh/discovery: ${CLUSTER_NAME}|g" \
  -e "s|instanceProfile: petclinic-dev-karpenter-node-profile|instanceProfile: ${KARPENTER_INSTANCE_PROFILE}|g" \
  "${REPO_ROOT}/k8s/base/karpenter/nodepool.yaml" | kubectl apply -f -

kubectl get nodepool
kubectl get ec2nodeclass
echo "  ✅ Karpenter installed and NodePool applied for ${ENV}"

# ── Step 9: Monitoring stack ──────────────────────────────────────────────────
echo ""
echo "[9/10] Installing Metrics Server and monitoring stack..."

echo "  Installing Metrics Server..."
kubectl apply -f \
  https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment metrics-server -n kube-system \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' \
  2>/dev/null || true
echo "  ✅ Metrics Server installed"

helm repo add prometheus-community \
  https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana \
  https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add fluent \
  https://fluent.github.io/helm-charts 2>/dev/null || true
helm repo update

echo "  Installing Prometheus..."
helm_install_with_retry helm upgrade --install prometheus \
  prometheus-community/prometheus \
  -n monitoring \
  --version 25.21.0 \
  -f "${REPO_ROOT}/monitoring/prometheus-values.yaml" \
  --wait --timeout 10m

echo "  Installing Loki..."
helm_install_with_retry helm upgrade --install loki grafana/loki \
  -n monitoring \
  --version 6.6.2 \
  -f "${REPO_ROOT}/monitoring/loki-values.yaml"

echo "  Installing FluentBit..."
helm_install_with_retry helm upgrade --install fluent-bit fluent/fluent-bit \
  -n monitoring \
  --version 0.46.7 \
  -f "${REPO_ROOT}/monitoring/fluent-bit-values.yaml" \
  --wait --timeout 10m

echo "  Installing Grafana..."
helm_install_with_retry helm upgrade --install grafana grafana/grafana \
  -n monitoring \
  --version 7.3.9 \
  -f "${REPO_ROOT}/monitoring/grafana-values.yaml" \
  --wait --timeout 10m

# ── Alertmanager — inject credentials from Secrets Manager ───────────────────
echo "  Configuring Alertmanager..."
AM_SECRET_ID="petclinic/${ENV}/alertmanager-email"

if aws secretsmanager describe-secret \
  --secret-id "${AM_SECRET_ID}" \
  --region "${AWS_REGION}" &>/dev/null 2>&1; then

  AM_SECRET_VAL=$(aws secretsmanager get-secret-value \
    --secret-id "${AM_SECRET_ID}" \
    --region "${AWS_REGION}" \
    --query "SecretString" --output text 2>/dev/null || echo "")

  if [ -n "${AM_SECRET_VAL}" ]; then
    AM_EMAIL=$(echo "${AM_SECRET_VAL}" | python3 -c \
      "import json,sys; print(json.load(sys.stdin)['email'])" 2>/dev/null || echo "")
    AM_PASSWORD=$(echo "${AM_SECRET_VAL}" | python3 -c \
      "import json,sys; print(json.load(sys.stdin)['app_password'])" 2>/dev/null || echo "")

    if [ -n "${AM_EMAIL}" ] && [ -n "${AM_PASSWORD}" ]; then
      AM_CONFIG=$(sed \
        -e "s|ALERTMANAGER_EMAIL_PLACEHOLDER|${AM_EMAIL}|g" \
        -e "s|ALERTMANAGER_PASSWORD_PLACEHOLDER|${AM_PASSWORD}|g" \
        "${REPO_ROOT}/monitoring/alertmanager.yaml" | \
        awk '/^  alertmanager\.yml: \|/{found=1; next} \
             found && /^---/{exit} \
             found{print substr($0,5)}')

      kubectl delete secret alertmanager-config \
        -n monitoring 2>/dev/null || true
      kubectl create secret generic alertmanager-config \
        -n monitoring \
        --from-literal="alertmanager.yml=${AM_CONFIG}"
      echo "  ✅ Alertmanager credentials injected from Secrets Manager"
    else
      echo "  ⚠️  Could not parse alertmanager credentials"
    fi
  fi
else
  echo "  ⚠️  Alertmanager secret not found: ${AM_SECRET_ID}"
  echo "      Run pre-apply-check.sh first to create it automatically"
fi

kubectl apply -f "${REPO_ROOT}/monitoring/alertmanager.yaml"
echo "  Applying Zipkin..."
kubectl apply -f "${REPO_ROOT}/monitoring/zipkin.yaml"
echo "  ✅ Monitoring stack installed"

# ── Step 10: Ingresses ────────────────────────────────────────────────────────
echo ""
echo "[10/10] Applying ingresses..."

kubectl apply -f "${REPO_ROOT}/k8s/overlays/${ENV}/ingress.yaml"

yq 'select(.metadata.namespace == "monitoring")' \
  "${REPO_ROOT}/monitoring/monitoring-ingress.yaml" | kubectl apply -f -

yq 'select(.metadata.namespace == "argocd")' \
  "${REPO_ROOT}/monitoring/monitoring-ingress.yaml" | kubectl apply -f -

yq 'select(.metadata.namespace == "tracing")' \
  "${REPO_ROOT}/monitoring/monitoring-ingress.yaml" | kubectl apply -f -

echo "  Waiting 3 minutes for ALBs to provision..."
sleep 180

echo ""
echo "  Ingress addresses:"
kubectl get ingress -n "petclinic-${ENV}" 2>/dev/null || true
kubectl get ingress -n monitoring 2>/dev/null || true
kubectl get ingress -n argocd 2>/dev/null || true
kubectl get ingress -n tracing 2>/dev/null || true
echo "  ✅ Ingresses applied"

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
echo "      git add helm-values/${ENV}/ k8s/ monitoring/ argocd/"
echo "      git commit -m 'config: update dynamic values for ${ENV}'"
echo "      git push"
echo ""
echo "   4. Wire DNS (Cloudflare CNAMEs → ALBs):"
echo "      ./scripts/update-dns-and-ingress.sh ${ENV}"
echo ""
echo "   5. Run smoke test:"
echo "      ./scripts/smoke-test.sh petclinic-${ENV}"
echo "=============================================="
