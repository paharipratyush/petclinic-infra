#!/bin/bash
# ============================================================
# generate-config.sh — Update ALL dynamic config after terraform apply
#
# Reads Terraform outputs + terraform.tfvars and updates:
#   - helm-values/*.yaml         (ECR URLs, RDS endpoint)
#   - k8s/overlays/{env}/ingress.yaml  (cert ARN, domain hostnames)
#   - monitoring/monitoring-ingress.yaml (cert ARN, domain hostnames)
#   - monitoring/grafana-values.yaml    (root_url)
#   - argocd/applications/{env}/*.yaml  (repoURL)
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

# ── Read terraform.tfvars for non-sensitive config ────────────────────────────
TFVARS="${REPO_ROOT}/${TF_DIR}/terraform.tfvars"
if [ ! -f "${TFVARS}" ]; then
  echo "ERROR: ${TFVARS} not found."
  echo "Copy terraform.tfvars.example to terraform.tfvars and fill in your values."
  exit 1
fi

# Extract values from tfvars (handles quoted and unquoted values)
get_tfvar() {
  grep "^${1}" "${TFVARS}" | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' '
}

DOMAIN=$(get_tfvar "domain_name")
GITHUB_ORG=$(get_tfvar "github_org")
INFRA_REPO=$(get_tfvar "infra_repo")

if [ -z "${DOMAIN}" ]; then
  echo "ERROR: domain_name not found in ${TFVARS}"
  exit 1
fi

if [ -z "${GITHUB_ORG}" ]; then
  echo "WARNING: github_org not found in ${TFVARS} — ArgoCD app URLs will not be updated"
fi

echo ""
echo " Domain      : ${DOMAIN}"
echo " GitHub Org  : ${GITHUB_ORG:-NOT SET}"
echo " Infra Repo  : ${INFRA_REPO:-NOT SET}"

# ── Get Terraform outputs ─────────────────────────────────────────────────────
echo ""
echo "[1/6] Reading Terraform outputs..."
cd "${REPO_ROOT}/${TF_DIR}"

JDBC_URL=$(terraform output -raw rds_jdbc_url 2>/dev/null || echo "")
CERT_ARN=$(terraform output -raw certificate_arn 2>/dev/null || echo "")

cd "${REPO_ROOT}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(aws configure get region 2>/dev/null || get_tfvar "aws_region")
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "   JDBC URL    : ${JDBC_URL:-NOT FOUND — RDS not deployed yet}"
echo "   Cert ARN    : ${CERT_ARN:-NOT FOUND — DNS module not deployed yet}"
echo "   ECR Registry: ${ECR_REGISTRY}"

# ── Build subdomain names ─────────────────────────────────────────────────────
if [ "${ENV}" = "prod" ]; then
  PETCLINIC_HOST="petclinic.${DOMAIN}"
  GRAFANA_HOST="grafana.${DOMAIN}"
  ARGOCD_HOST="argocd.${DOMAIN}"
  ADMIN_HOST="admin.${DOMAIN}"
else
  PETCLINIC_HOST="petclinic-dev.${DOMAIN}"
  GRAFANA_HOST="grafana-dev.${DOMAIN}"
  ARGOCD_HOST="argocd-dev.${DOMAIN}"
  ADMIN_HOST="admin-dev.${DOMAIN}"
fi

INFRA_REPO_URL="https://github.com/${GITHUB_ORG}/${INFRA_REPO}.git"

echo ""
echo " Subdomains:"
echo "   App     : https://${PETCLINIC_HOST}"
echo "   Grafana : https://${GRAFANA_HOST}"
echo "   ArgoCD  : https://${ARGOCD_HOST}"
echo "   Admin   : https://${ADMIN_HOST}"
echo " ArgoCD repo URL: ${INFRA_REPO_URL}"

# ── [1] Update ECR image repositories in all helm-values ─────────────────────
echo ""
echo "[2/6] Updating ECR image repository URLs in helm-values/..."

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
    echo "   ✅ helm-values/${SERVICE}.yaml"
  fi
done

# ── [2] Update RDS datasource URL ─────────────────────────────────────────────
echo ""
echo "[3/6] Updating SPRING_DATASOURCE_URL in DB service helm-values..."

if [ -z "${JDBC_URL}" ]; then
  echo "   ⚠️  Skipping — no rds_jdbc_url output found"
else
  for SERVICE in customers-service visits-service vets-service; do
    FILE="${REPO_ROOT}/helm-values/${SERVICE}.yaml"
    if [ -f "${FILE}" ]; then
      yq -i \
        "(.env[] | select(.name == \"SPRING_DATASOURCE_URL\") | .value) = \"${JDBC_URL}\"" \
        "${FILE}"
      echo "   ✅ helm-values/${SERVICE}.yaml → ${JDBC_URL}"
    fi
  done
fi

# ── [3] Update ACM cert ARN + hostnames in app ingress ────────────────────────
echo ""
echo "[4/6] Updating app ingress (cert ARN + hostnames)..."

APP_INGRESS="${REPO_ROOT}/k8s/overlays/${ENV}/ingress.yaml"
if [ -f "${APP_INGRESS}" ]; then
  if [ -n "${CERT_ARN}" ]; then
    yq -i \
      ".metadata.annotations[\"alb.ingress.kubernetes.io/certificate-arn\"] = \"${CERT_ARN}\"" \
      "${APP_INGRESS}"
  fi
  # Update hostnames — targets each rule by index
  yq -i ".spec.rules[0].host = \"${PETCLINIC_HOST}\"" "${APP_INGRESS}"
  yq -i ".spec.rules[1].host = \"${ADMIN_HOST}\"" "${APP_INGRESS}"
  echo "   ✅ k8s/overlays/${ENV}/ingress.yaml"
  echo "      ${PETCLINIC_HOST} → api-gateway"
  echo "      ${ADMIN_HOST} → admin-server"
fi

# ── [4] Update ACM cert ARN + hostnames in monitoring ingress ─────────────────
echo ""
echo "[5/6] Updating monitoring ingress (cert ARN + hostnames)..."

MONITORING_INGRESS="${REPO_ROOT}/monitoring/monitoring-ingress.yaml"
if [ -f "${MONITORING_INGRESS}" ]; then
  if [ -n "${CERT_ARN}" ]; then
    # Updates cert ARN in ALL documents in the file (both Ingress resources)
    yq -i \
      ".metadata.annotations[\"alb.ingress.kubernetes.io/certificate-arn\"] = \"${CERT_ARN}\"" \
      "${MONITORING_INGRESS}"
  fi
  # Update grafana ingress host (document 0)
  yq -i "select(di == 0) | .spec.rules[0].host = \"${GRAFANA_HOST}\"" \
    "${MONITORING_INGRESS}" 2>/dev/null || \
  yq -i "(select(.metadata.name == \"grafana-ingress\") | .spec.rules[0].host) = \"${GRAFANA_HOST}\"" \
    "${MONITORING_INGRESS}"

  # Update argocd ingress host (document 1)
  yq -i "(select(.metadata.name == \"argocd-ingress\") | .spec.rules[0].host) = \"${ARGOCD_HOST}\"" \
    "${MONITORING_INGRESS}"

  echo "   ✅ monitoring/monitoring-ingress.yaml"
  echo "      ${GRAFANA_HOST} → grafana"
  echo "      ${ARGOCD_HOST} → argocd-server"
fi

# Update Grafana root_url
GRAFANA_VALUES="${REPO_ROOT}/monitoring/grafana-values.yaml"
if [ -f "${GRAFANA_VALUES}" ]; then
  yq -i ".\"grafana.ini\".server.root_url = \"https://${GRAFANA_HOST}\"" \
    "${GRAFANA_VALUES}"
  echo "   ✅ monitoring/grafana-values.yaml → root_url: https://${GRAFANA_HOST}"
fi

# ── [5] Update ArgoCD application repo URLs ───────────────────────────────────
echo ""
echo "[6/6] Updating ArgoCD application repo URLs..."

if [ -z "${GITHUB_ORG}" ] || [ -z "${INFRA_REPO}" ]; then
  echo "   ⚠️  Skipping — github_org or infra_repo not set in terraform.tfvars"
else
  for f in "${REPO_ROOT}/argocd/applications/${ENV}"/*.yaml; do
    if [ -f "${f}" ]; then
      yq -i ".spec.source.repoURL = \"${INFRA_REPO_URL}\"" "${f}"
      echo "   ✅ $(basename ${f})"
    fi
  done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Done! Review all changes:"
echo "=============================================="
echo ""
echo "  git diff helm-values/"
echo "  git diff k8s/overlays/${ENV}/"
echo "  git diff monitoring/"
echo "  git diff argocd/applications/${ENV}/"
echo ""
echo " Then commit and push so ArgoCD picks up the changes:"
echo ""
echo "  git add helm-values/ k8s/ monitoring/ argocd/"
echo "  git commit -m 'config: update dynamic values for ${ENV}'"
echo "  git push"
echo ""

# ── Update ESO ServiceAccount annotation with current ESO role ARN ────────────
if [ -n "${ESO_ROLE_ARN:-}" ]; then
  ESO_SA="${REPO_ROOT}/k8s/base/external-secrets/serviceaccount.yaml"
  if [ -f "${ESO_SA}" ]; then
    yq -i ".metadata.annotations[\"eks.amazonaws.com/role-arn\"] = \"${ESO_ROLE_ARN}\"" \
      "${ESO_SA}"
    echo "   ✅ k8s/base/external-secrets/serviceaccount.yaml → ${ESO_ROLE_ARN}"
  fi
fi
