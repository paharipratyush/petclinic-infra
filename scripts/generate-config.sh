#!/bin/bash
# ============================================================
# generate-config.sh — Update dynamic config after terraform apply
#
# Reads Terraform outputs and updates:
#   - helm-values/*.yaml  (RDS endpoint, ECR registry URLs)
#   - k8s/overlays/{env}/ingress.yaml  (ACM certificate ARN)
#   - monitoring/monitoring-ingress.yaml  (ACM certificate ARN)
#
# Usage:
#   ./scripts/generate-config.sh          # defaults to dev
#   ./scripts/generate-config.sh dev
#   ./scripts/generate-config.sh prod
#
# Run this after EVERY terraform apply before applying K8s manifests.
# ============================================================

set -euo pipefail

ENV="${1:-dev}"
TF_DIR="terraform/environments/${ENV}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Verify dependencies ───────────────────────────────────────────────────────
for cmd in terraform yq aws; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is required but not installed."
    exit 1
  fi
done

echo "=============================================="
echo " generate-config.sh — environment: ${ENV}"
echo "=============================================="

# ── Get Terraform outputs ─────────────────────────────────────────────────────
cd "${REPO_ROOT}/${TF_DIR}"

echo ""
echo "[1/4] Reading Terraform outputs..."
JDBC_URL=$(terraform output -raw rds_jdbc_url 2>/dev/null || echo "")
CERT_ARN=$(terraform output -raw certificate_arn 2>/dev/null || echo "")
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region || echo "ap-south-1")

cd "${REPO_ROOT}"

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "   JDBC URL    : ${JDBC_URL:-NOT FOUND}"
echo "   Cert ARN    : ${CERT_ARN:-NOT FOUND}"
echo "   ECR Registry: ${ECR_REGISTRY}"

# ── Update ECR image repositories in all helm-values ─────────────────────────
echo ""
echo "[2/4] Updating ECR image repository URLs in helm-values/..."

SERVICES=(
  "config-server"
  "discovery-server"
  "api-gateway"
  "customers-service"
  "visits-service"
  "vets-service"
  "genai-service"
  "admin-server"
)

for SERVICE in "${SERVICES[@]}"; do
  FILE="${REPO_ROOT}/helm-values/${SERVICE}.yaml"
  if [ -f "${FILE}" ]; then
    yq -i ".image.repository = \"${ECR_REGISTRY}/petclinic-${ENV}/${SERVICE}\"" "${FILE}"
    echo "   ✅ ${FILE}"
  fi
done

# ── Update RDS datasource URL in DB service helm-values ──────────────────────
echo ""
echo "[3/4] Updating SPRING_DATASOURCE_URL in DB service helm-values..."

if [ -z "${JDBC_URL}" ]; then
  echo "   ⚠️  WARNING: No rds_jdbc_url output found. RDS may not be deployed yet."
else
  for SERVICE in customers-service visits-service vets-service; do
    FILE="${REPO_ROOT}/helm-values/${SERVICE}.yaml"
    if [ -f "${FILE}" ]; then
      yq -i \
        "(.env[] | select(.name == \"SPRING_DATASOURCE_URL\") | .value) = \"${JDBC_URL}\"" \
        "${FILE}"
      echo "   ✅ ${FILE} → ${JDBC_URL}"
    fi
  done
fi

# ── Update ACM certificate ARN in ingress manifests ──────────────────────────
echo ""
echo "[4/4] Updating ACM certificate ARN in ingress manifests..."

if [ -z "${CERT_ARN}" ]; then
  echo "   ⚠️  WARNING: No certificate_arn output found. DNS module may not be deployed yet."
else
  # App ingress
  APP_INGRESS="${REPO_ROOT}/k8s/overlays/${ENV}/ingress.yaml"
  if [ -f "${APP_INGRESS}" ]; then
    yq -i \
      ".metadata.annotations[\"alb.ingress.kubernetes.io/certificate-arn\"] = \"${CERT_ARN}\"" \
      "${APP_INGRESS}"
    echo "   ✅ ${APP_INGRESS}"
  fi

  # Monitoring ingress (grafana + argocd)
  MONITORING_INGRESS="${REPO_ROOT}/monitoring/monitoring-ingress.yaml"
  if [ -f "${MONITORING_INGRESS}" ]; then
    # Update both Ingress resources in the file
    yq -i \
      "select(.kind == \"Ingress\") | .metadata.annotations[\"alb.ingress.kubernetes.io/certificate-arn\"] = \"${CERT_ARN}\"" \
      "${MONITORING_INGRESS}"
    echo "   ✅ ${MONITORING_INGRESS}"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Done! Review all changes before committing:"
echo "=============================================="
echo ""
echo "  git diff helm-values/"
echo "  git diff k8s/overlays/${ENV}/ingress.yaml"
echo "  git diff monitoring/monitoring-ingress.yaml"
echo ""
echo " Then commit and push so ArgoCD picks up the changes:"
echo ""
echo "  git add helm-values/ k8s/ monitoring/"
echo "  git commit -m 'config: update dynamic values for ${ENV}'"
echo "  git push"
echo ""
