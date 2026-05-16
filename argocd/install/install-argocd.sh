#!/bin/bash
# ============================================================
# install-argocd.sh — Install ArgoCD on EKS with pinned version
#
# Usage:
#   ./argocd/install/install-argocd.sh
#   ./argocd/install/install-argocd.sh --env prod
#
# What it does:
#   1. Creates argocd namespace
#   2. Installs ArgoCD v2.14.3 (pinned)
#   3. Patches server to run in insecure mode (ALB handles TLS)
#   4. Waits for all pods to be ready
#   5. Prints initial admin password + access instructions
#
# Prerequisites:
#   - kubectl configured (aws eks update-kubeconfig done)
#   - Cluster is running and accessible
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ARGOCD_VERSION="v2.14.3"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
ENV="dev"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env) ENV="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Derive domain from terraform.tfvars ───────────────────────────────────────
TFVARS="${REPO_ROOT}/terraform/environments/${ENV}/terraform.tfvars"
DOMAIN="your-domain.com"

if [ -f "${TFVARS}" ]; then
  DOMAIN_FROM_TFVARS=$(grep "^domain_name" "${TFVARS}" \
    | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
  if [ -n "${DOMAIN_FROM_TFVARS}" ]; then
    DOMAIN="${DOMAIN_FROM_TFVARS}"
  fi
else
  echo "  ⚠️  terraform.tfvars not found at ${TFVARS}"
  echo "     Using placeholder domain: ${DOMAIN}"
fi

if [ "${ENV}" = "prod" ]; then
  ARGOCD_URL="argocd.${DOMAIN}"
else
  ARGOCD_URL="argocd-dev.${DOMAIN}"
fi

echo "=============================================="
echo " Installing ArgoCD ${ARGOCD_VERSION}"
echo " Environment : ${ENV}"
echo " Domain      : ${ARGOCD_URL}"
echo "=============================================="

# ── Create namespace ──────────────────────────────────────────────────────────
echo ""
echo "[1/5] Creating argocd namespace..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    app.kubernetes.io/part-of: petclinic
EOF

# ── Install ArgoCD ────────────────────────────────────────────────────────────
echo ""
echo "[2/5] Applying ArgoCD manifests (${ARGOCD_VERSION})..."
kubectl apply -n argocd -f "${ARGOCD_MANIFEST}"

# ── Wait for deployments to exist before patching ─────────────────────────────
echo ""
echo "[3/5] Waiting for ArgoCD deployments to be created..."
kubectl wait --for=condition=available deployment \
  --all -n argocd \
  --timeout=300s

# ── Patch ArgoCD server to disable TLS (ALB handles TLS termination) ─────────
echo ""
echo "[4/5] Configuring ArgoCD server (insecure mode for ALB TLS termination)..."
kubectl patch deployment argocd-server -n argocd \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

# ── Apply RBAC ConfigMap ──────────────────────────────────────────────────────
echo ""
echo "[5/5] Applying ArgoCD RBAC configuration..."
if [ -f "${REPO_ROOT}/argocd/argocd-rbac-cm.yaml" ]; then
  kubectl apply -f "${REPO_ROOT}/argocd/argocd-rbac-cm.yaml"
  echo "  ✅ RBAC ConfigMap applied"
else
  echo "  ⚠️  argocd/argocd-rbac-cm.yaml not found — skipping RBAC config"
fi

# ── Print results ─────────────────────────────────────────────────────────────
INITIAL_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "=============================================="
echo " ArgoCD installed successfully!"
echo "=============================================="
echo ""
echo " Initial admin credentials:"
echo "   Username: admin"
echo "   Password: ${INITIAL_PASSWORD}"
echo ""
echo " Access ArgoCD UI (port-forward — works immediately):"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "   Then open: http://localhost:8080"
echo ""
echo " Or via domain (after DNS is configured):"
echo "   https://${ARGOCD_URL}"
echo ""
echo " IMPORTANT: Change the admin password after first login!"
echo "   argocd login ${ARGOCD_URL}"
echo "   argocd account update-password"
echo "=============================================="
