#!/bin/bash
# ============================================================
# install-argocd.sh — Install ArgoCD on EKS with pinned version
#
# Usage:
#   ./argocd/install/install-argocd.sh
#
# What it does:
#   1. Creates argocd namespace
#   2. Installs ArgoCD v2.14.3 (pinned)
#   3. Waits for all pods to be ready
#   4. Prints initial admin password + port-forward command
#
# Prerequisites:
#   - kubectl configured (aws eks update-kubeconfig done)
#   - Cluster is running and accessible
# ============================================================

set -euo pipefail

ARGOCD_VERSION="v2.14.3"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

echo "=============================================="
echo " Installing ArgoCD ${ARGOCD_VERSION}"
echo "=============================================="

# ── Create namespace ──────────────────────────────────────────────────────────
echo ""
echo "[1/4] Creating argocd namespace..."
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
echo "[2/4] Applying ArgoCD manifests (${ARGOCD_VERSION})..."
kubectl apply -n argocd -f "${ARGOCD_MANIFEST}"

# ── Wait for ArgoCD pods ──────────────────────────────────────────────────────
echo ""
echo "[3/4] Waiting for ArgoCD pods to be ready (up to 5 minutes)..."
kubectl wait --for=condition=available deployment \
  --all -n argocd \
  --timeout=300s

# ── Patch ArgoCD server to disable TLS (ALB handles TLS termination) ─────────
echo ""
echo "[4/4] Configuring ArgoCD server (disable insecure TLS for ALB)..."
kubectl patch deployment argocd-server -n argocd \
  --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--insecure"}]'

# ── Wait for rollout ──────────────────────────────────────────────────────────
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s

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
echo " Access ArgoCD UI (port-forward):"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "   Then open: http://localhost:8080"
echo ""
echo " Or via domain (after DNS is configured):"
echo "   https://argocd-dev.praty.dev"
echo ""
echo " IMPORTANT: Change the admin password after first login!"
echo "   argocd login argocd-dev.praty.dev"
echo "   argocd account update-password"
echo "=============================================="
