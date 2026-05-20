#!/bin/bash
# ==========================================================
# promote-to-prod.sh — Safely promote a tag from dev to prod
#
# Usage:
#   ./scripts/promote-to-prod.sh                    # promotes dev tag
#   ./scripts/promote-to-prod.sh --tag 60ebde6      # promotes specific tag
#   ./scripts/promote-to-prod.sh --service vets-service  # promotes one service
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TAG=""
SERVICE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --tag)     TAG="$2";     shift 2 ;;
    --service) SERVICE="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# Default to current dev tag
if [ -z "${TAG}" ]; then
  TAG=$(grep "tag:" "${REPO_ROOT}/helm-values/dev/api-gateway.yaml" | \
    awk '{print $2}')
fi

echo "=============================================="
echo " Promote to Prod"
echo " Tag    : ${TAG}"
echo " Service: ${SERVICE:-all}"
echo "=============================================="

# Verify tag exists in prod ECR for all services
echo ""
echo "[1/4] Verifying images exist in prod ECR..."
SERVICES=(
  "config-server" "discovery-server" "api-gateway"
  "customers-service" "visits-service" "vets-service"
  "genai-service" "admin-server"
)
if [ -n "${SERVICE}" ]; then
  SERVICES=("${SERVICE}")
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(grep "^aws_region" \
  "${REPO_ROOT}/terraform/environments/prod/terraform.tfvars" | \
  sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
REGION="${REGION:-ap-south-1}"

MISSING=()
for SVC in "${SERVICES[@]}"; do
  EXISTS=$(aws ecr describe-images \
    --repository-name "petclinic-prod/${SVC}" \
    --region "${REGION}" \
    --image-ids imageTag="${TAG}" \
    --query "imageDetails[0].imageTags[0]" \
    --output text 2>/dev/null || echo "")
  if [ -z "${EXISTS}" ] || [ "${EXISTS}" = "None" ]; then
    echo "  ❌ Image NOT in prod ECR: petclinic-prod/${SVC}:${TAG}"
    MISSING+=("${SVC}")
  else
    echo "  ✅ Image exists: petclinic-prod/${SVC}:${TAG}"
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  echo "  ⚠️  ${#MISSING[@]} image(s) missing from prod ECR."
  echo "  Build and push them first:"
  echo "  ./scripts/build-push-images.sh --tag ${TAG} --env prod"
  exit 1
fi

# Update prod helm-values
echo ""
echo "[2/4] Updating prod helm-values..."
for SVC in "${SERVICES[@]}"; do
  FILE="${REPO_ROOT}/helm-values/prod/${SVC}.yaml"
  if [ -f "${FILE}" ]; then
    CURRENT=$(grep "tag:" "${FILE}" | awk '{print $2}')
    yq -i ".image.tag = \"${TAG}\"" "${FILE}"
    echo "  ✅ helm-values/prod/${SVC}.yaml: ${CURRENT} → ${TAG}"
  fi
done

git -C "${REPO_ROOT}" add helm-values/prod/
git -C "${REPO_ROOT}" commit \
  -m "deploy: promote ${SERVICE:-all services} to ${TAG} in prod" \
  2>/dev/null || echo "  ℹ️  No changes to commit"
git -C "${REPO_ROOT}" push

# Sync ArgoCD in correct order with health checks
echo ""
echo "[3/4] Syncing prod ArgoCD apps in correct order..."

# Order matters:
# 1. config-server first — all others depend on it
# 2. discovery-server — all others register with it
# 3. Everything else in parallel
ORDERED_APPS=(
  "config-server-prod"
  "discovery-server-prod"
  "api-gateway-prod"
  "customers-service-prod"
  "visits-service-prod"
  "vets-service-prod"
  "genai-service-prod"
  "admin-server-prod"
)

if [ -n "${SERVICE}" ]; then
  ORDERED_APPS=("${SERVICE}-prod")
fi

for APP in "${ORDERED_APPS[@]}"; do
  DEPLOY=$(echo "${APP}" | sed 's/-prod$//')

  kubectl patch application "${APP}" -n argocd \
    --type merge \
    -p '{"operation":{"sync":{"syncStrategy":{"apply":{"force":false}}}}}' \
    2>/dev/null && echo "  ▶ Syncing: ${APP}"

  # Wait for rollout to complete before moving to next service
  echo "    Waiting for ${DEPLOY} rollout..."
  kubectl rollout status deployment "${DEPLOY}" \
    -n petclinic-prod --timeout=5m 2>/dev/null && \
    echo "  ✅ ${DEPLOY} rollout complete" || \
    echo "  ⚠️  ${DEPLOY} rollout timeout — continuing"
done

# Run smoke test
echo ""
echo "[4/4] Running smoke test..."
sleep 30
"${SCRIPT_DIR}/smoke-test.sh" petclinic-prod

echo ""
echo "=============================================="
echo " Promotion complete!"
echo " Tag ${TAG} is now running in prod"
echo "=============================================="
