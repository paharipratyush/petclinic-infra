#!/bin/bash
# ============================================================
# generate-config.sh — Update ALL dynamic config after terraform apply
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

for cmd in terraform yq aws sed; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is required but not installed."
    exit 1
  fi
done

echo "=============================================="
echo " generate-config.sh — environment: ${ENV}"
echo "=============================================="

# ── Safety warning ────────────────────────────────────────────────────────────
# Warn if generating prod config while kubectl points to dev cluster.
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
echo ""
echo " Current kubectl context: ${CURRENT_CONTEXT}"
if [ "${ENV}" = "prod" ] && echo "${CURRENT_CONTEXT}" | grep -q "petclinic-dev"; then
  echo ""
  echo " ⚠️  WARNING: Generating PROD config but kubectl points to DEV cluster!"
  echo " ⚠️  Switch kubectl to prod after committing:"
  echo "     aws eks update-kubeconfig --name petclinic-prod --region ap-south-1"
  echo ""
  read -r -p " Continue anyway? (yes/no): " CONFIRM
  if [ "${CONFIRM}" != "yes" ]; then
    echo " Aborted."
    exit 1
  fi
fi

TFVARS="${TF_DIR}/terraform.tfvars"
if [ ! -f "${TFVARS}" ]; then
  echo "ERROR: ${TFVARS} not found."
  exit 1
fi

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

if [ "${ENV}" = "prod" ]; then
  PETCLINIC_HOST="petclinic.${DOMAIN}"
  GRAFANA_HOST="grafana.${DOMAIN}"
  ARGOCD_HOST="argocd.${DOMAIN}"
  ADMIN_HOST="admin.${DOMAIN}"
  ZIPKIN_HOST="zipkin.${DOMAIN}"
else
  PETCLINIC_HOST="petclinic-dev.${DOMAIN}"
  GRAFANA_HOST="grafana-dev.${DOMAIN}"
  ARGOCD_HOST="argocd-dev.${DOMAIN}"
  ADMIN_HOST="admin-dev.${DOMAIN}"
  ZIPKIN_HOST="zipkin-dev.${DOMAIN}"
fi

INFRA_REPO_URL="https://github.com/${GITHUB_ORG}/${INFRA_REPO}.git"
K8S_NAMESPACE="petclinic-${ENV}"
HELM_VALUES_DIR="${REPO_ROOT}/helm-values/${ENV}"

echo ""
echo " Domain         : ${DOMAIN}"
echo " GitHub Org     : ${GITHUB_ORG:-NOT SET}"
echo " Infra Repo     : ${INFRA_REPO:-NOT SET}"
echo " K8s NS         : ${K8S_NAMESPACE}"
echo " Helm Values Dir: ${HELM_VALUES_DIR}"
echo ""
echo " Subdomains:"
echo "   App     : https://${PETCLINIC_HOST}"
echo "   Grafana : https://${GRAFANA_HOST}"
echo "   ArgoCD  : https://${ARGOCD_HOST}"
echo "   Admin   : https://${ADMIN_HOST}"
echo "   Zipkin  : https://${ZIPKIN_HOST}"

echo ""
echo "[1/8] Reading Terraform outputs..."
cd "${TF_DIR}"

JDBC_URL=$(terraform output -raw rds_jdbc_url 2>/dev/null || echo "")
CERT_ARN=$(terraform output -raw certificate_arn 2>/dev/null || echo "")
ESO_ROLE_ARN=$(terraform output -raw eso_role_arn 2>/dev/null || echo "")

cd "${REPO_ROOT}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=$(get_tfvar "aws_region")
if [ -z "${AWS_REGION}" ]; then
  AWS_REGION=$(aws configure get region 2>/dev/null || echo "ap-south-1")
fi
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "   JDBC URL    : ${JDBC_URL:-NOT FOUND}"
echo "   Cert ARN    : ${CERT_ARN:-NOT FOUND}"
echo "   ECR Registry: ${ECR_REGISTRY}"
echo "   ESO Role ARN: ${ESO_ROLE_ARN:-NOT FOUND}"

# Ensure env-specific helm-values directory exists
mkdir -p "${HELM_VALUES_DIR}"

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

# ── [2] Update ECR image repositories ────────────────────────────────────────
echo ""
echo "[2/8] Updating ECR image repository URLs in helm-values/${ENV}/..."
for SERVICE in "${SERVICES[@]}"; do
  FILE="${HELM_VALUES_DIR}/${SERVICE}.yaml"
  if [ -f "${FILE}" ]; then
    yq -i ".image.repository = \"${ECR_REGISTRY}/petclinic-${ENV}/${SERVICE}\"" "${FILE}"
    echo "   ✅ helm-values/${ENV}/${SERVICE}.yaml → ${ECR_REGISTRY}/petclinic-${ENV}/${SERVICE}"
  else
    echo "   ⚠️  helm-values/${ENV}/${SERVICE}.yaml not found — skipping"
  fi
done

# ── [3] Reset SHA image tags — only if image doesn't exist in ECR ─────────────
# On a fresh cluster after destroy+recreate, CI/CD SHA tags from the previous
# cluster no longer exist in the new ECR repos. Reset to v1.0.0 ONLY when
# the image is confirmed missing from ECR — avoids resetting valid CI/CD tags.
echo ""
echo "[3/8] Checking image tags (reset stale SHAs only if not in ECR)..."
TAGS_RESET=0
for SERVICE in "${SERVICES[@]}"; do
  FILE="${HELM_VALUES_DIR}/${SERVICE}.yaml"
  if [ -f "${FILE}" ]; then
    CURRENT_TAG=$(yq '.image.tag' "${FILE}" 2>/dev/null || echo "")
    if echo "${CURRENT_TAG}" | grep -qE '^[0-9a-f]{7}$'; then
      # Check if this SHA image actually exists in ECR
      IMAGE_EXISTS=$(aws ecr describe-images \
        --repository-name "petclinic-${ENV}/${SERVICE}" \
        --region "${AWS_REGION}" \
        --image-ids imageTag="${CURRENT_TAG}" \
        --query "imageDetails[0].imageTags[0]" \
        --output text 2>/dev/null || echo "")
      if [ -z "${IMAGE_EXISTS}" ] || [ "${IMAGE_EXISTS}" = "None" ]; then
        yq -i '.image.tag = "v1.0.0"' "${FILE}"
        echo "   ✅ helm-values/${ENV}/${SERVICE}.yaml: ${CURRENT_TAG} → v1.0.0 (image not in ECR — reset)"
        TAGS_RESET=$((TAGS_RESET + 1))
      else
        echo "   ✅ helm-values/${ENV}/${SERVICE}.yaml: tag=${CURRENT_TAG} (exists in ECR — keeping)"
      fi
    else
      echo "   ✅ helm-values/${ENV}/${SERVICE}.yaml: tag=${CURRENT_TAG} (no change)"
    fi
  fi
done
if [ "${TAGS_RESET}" -gt 0 ]; then
  echo "   ℹ️  Reset ${TAGS_RESET} stale SHA tag(s) to v1.0.0"
  echo "      These images no longer exist in ECR (fresh cluster deploy)"
fi

# ── [4] Update RDS datasource URL ────────────────────────────────────────────
echo ""
echo "[4/8] Updating SPRING_DATASOURCE_URL in DB service helm-values..."
if [ -z "${JDBC_URL}" ]; then
  echo "   ⚠️  Skipping — no rds_jdbc_url output found"
else
  for SERVICE in customers-service visits-service vets-service; do
    FILE="${HELM_VALUES_DIR}/${SERVICE}.yaml"
    if [ -f "${FILE}" ]; then
      yq -i \
        "(.env[] | select(.name == \"SPRING_DATASOURCE_URL\") | .value) = \"${JDBC_URL}\"" \
        "${FILE}"
      echo "   ✅ helm-values/${ENV}/${SERVICE}.yaml → ${JDBC_URL}"
    fi
  done
fi

# ── [5] Update ACM cert ARN + hostnames in app ingress ───────────────────────
echo ""
echo "[5/8] Updating app ingress (cert ARN + hostnames)..."
APP_INGRESS="${REPO_ROOT}/k8s/overlays/${ENV}/ingress.yaml"
if [ -f "${APP_INGRESS}" ]; then
  if [ -n "${CERT_ARN}" ]; then
    yq -i \
      ".metadata.annotations[\"alb.ingress.kubernetes.io/certificate-arn\"] = \"${CERT_ARN}\"" \
      "${APP_INGRESS}"
  fi
  yq -i ".spec.rules[0].host = \"${PETCLINIC_HOST}\"" "${APP_INGRESS}"
  yq -i ".spec.rules[1].host = \"${ADMIN_HOST}\"" "${APP_INGRESS}"
  echo "   ✅ k8s/overlays/${ENV}/ingress.yaml"
  echo "      Cert ARN: ${CERT_ARN}"
  echo "      ${PETCLINIC_HOST} → api-gateway"
  echo "      ${ADMIN_HOST} → admin-server"
fi

# ── [6] Update monitoring ingress cert ARN + hostnames ───────────────────────
echo ""
echo "[6/8] Updating monitoring ingress (cert ARN + hostnames)..."
MONITORING_INGRESS="${REPO_ROOT}/monitoring/monitoring-ingress.yaml"
if [ -f "${MONITORING_INGRESS}" ]; then
  if [ -n "${CERT_ARN}" ]; then
    sed -i "s|CERT_ARN_PLACEHOLDER|${CERT_ARN}|g" "${MONITORING_INGRESS}"
    sed -i \
      "s|arn:aws:acm:[a-z0-9-]*:[0-9]*:certificate/[a-f0-9-]*|${CERT_ARN}|g" \
      "${MONITORING_INGRESS}"
  fi
  sed -i "s|PLACEHOLDER_GRAFANA_HOST|${GRAFANA_HOST}|g" "${MONITORING_INGRESS}"
  sed -i "s|PLACEHOLDER_ARGOCD_HOST|${ARGOCD_HOST}|g" "${MONITORING_INGRESS}"
  sed -i "s|PLACEHOLDER_ZIPKIN_HOST|${ZIPKIN_HOST}|g" "${MONITORING_INGRESS}"
  yq -i \
    "(select(.metadata.name == \"grafana-ingress\") | .spec.rules[0].host) = \"${GRAFANA_HOST}\"" \
    "${MONITORING_INGRESS}"
  yq -i \
    "(select(.metadata.name == \"argocd-ingress\") | .spec.rules[0].host) = \"${ARGOCD_HOST}\"" \
    "${MONITORING_INGRESS}"
  yq -i \
    "(select(.metadata.name == \"zipkin-ingress\") | .spec.rules[0].host) = \"${ZIPKIN_HOST}\"" \
    "${MONITORING_INGRESS}"
  echo "   ✅ monitoring/monitoring-ingress.yaml"
  echo "      Cert ARN: ${CERT_ARN}"
  echo "      ${GRAFANA_HOST} → grafana"
  echo "      ${ARGOCD_HOST} → argocd-server"
  echo "      ${ZIPKIN_HOST} → zipkin"
fi

# ── [7] Update Prometheus scrape namespace and Grafana root_url ──────────────
echo ""
echo "[7/8] Updating Prometheus scrape namespace and Grafana root_url..."
PROM_VALUES="${REPO_ROOT}/monitoring/prometheus-values.yaml"
if [ -f "${PROM_VALUES}" ]; then
  sed -i "s|PLACEHOLDER_K8S_NAMESPACE|${K8S_NAMESPACE}|g" "${PROM_VALUES}"
  sed -i "s|PLACEHOLDER_K8S_ENV|${ENV}|g" "${PROM_VALUES}"
  # Replace namespace in scrape targets
  sed -i "s|\.petclinic-dev:|\.${K8S_NAMESPACE}:|g" "${PROM_VALUES}"
  sed -i "s|\.petclinic-prod:|\.${K8S_NAMESPACE}:|g" "${PROM_VALUES}"
  # Replace namespace in alert rule expressions
  sed -i \
    "s|namespace=~\"petclinic-dev\"|namespace=~\"${K8S_NAMESPACE}\"|g" \
    "${PROM_VALUES}"
  sed -i \
    "s|namespace=~\"petclinic-prod\"|namespace=~\"${K8S_NAMESPACE}\"|g" \
    "${PROM_VALUES}"
  echo "   ✅ monitoring/prometheus-values.yaml → namespace: ${K8S_NAMESPACE}"
fi

GRAFANA_VALUES="${REPO_ROOT}/monitoring/grafana-values.yaml"
if [ -f "${GRAFANA_VALUES}" ]; then
  yq -i ".\"grafana.ini\".server.root_url = \"https://${GRAFANA_HOST}\"" \
    "${GRAFANA_VALUES}"
  echo "   ✅ monitoring/grafana-values.yaml → root_url: https://${GRAFANA_HOST}"
fi

# ── [8] Update ArgoCD application repo URLs ───────────────────────────────────
echo ""
echo "[8/8] Updating ArgoCD application repo URLs..."
if [ -z "${GITHUB_ORG}" ] || [ -z "${INFRA_REPO}" ]; then
  echo "   ⚠️  Skipping — github_org or infra_repo not set"
else
  for f in "${REPO_ROOT}/argocd/applications/${ENV}"/*.yaml; do
    if [ -f "${f}" ]; then
      yq -i ".spec.source.repoURL = \"${INFRA_REPO_URL}\"" "${f}"
      echo "   ✅ $(basename "${f}")"
    fi
  done
fi

if [ -n "${ESO_ROLE_ARN}" ]; then
  ESO_SA="${REPO_ROOT}/k8s/base/external-secrets/serviceaccount.yaml"
  if [ -f "${ESO_SA}" ]; then
    yq -i \
      ".metadata.annotations[\"eks.amazonaws.com/role-arn\"] = \"${ESO_ROLE_ARN}\"" \
      "${ESO_SA}"
    echo "   ✅ k8s/base/external-secrets/serviceaccount.yaml → ${ESO_ROLE_ARN}"
  fi
fi

CSS="${REPO_ROOT}/k8s/base/external-secrets/cluster-secret-store.yaml"
if [ -f "${CSS}" ]; then
  yq -i ".spec.provider.aws.region = \"${AWS_REGION}\"" "${CSS}"
  echo "   ✅ k8s/base/external-secrets/cluster-secret-store.yaml → region: ${AWS_REGION}"
fi

echo ""
echo "=============================================="
echo " Done! Review all changes before pushing:"
echo "=============================================="
echo ""
echo "  git diff helm-values/${ENV}/"
echo "  git diff k8s/"
echo "  git diff monitoring/"
echo "  git diff argocd/applications/${ENV}/"
echo ""
echo " Then commit and push:"
echo ""
echo "  git add helm-values/${ENV}/ k8s/ monitoring/ argocd/"
echo "  git commit -m 'config: update dynamic values for ${ENV}'"
echo "  git push"
echo "=============================================="
