#!/bin/bash
# Build ARM64 Docker images for all 8 Petclinic services and push to ECR
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENVIRONMENT="dev"
TAG=""
APP_REPO_ARG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --tag)      TAG="$2";          shift 2 ;;
    --env)      ENVIRONMENT="$2";  shift 2 ;;
    --app-repo) APP_REPO_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

if [ -n "${APP_REPO_ARG}" ]; then
  APP_REPO="${APP_REPO_ARG}"
elif [ -n "${APP_REPO:-}" ]; then
  APP_REPO="${APP_REPO}"
elif [ -d "${REPO_ROOT}/../spring-petclinic-microservices" ]; then
  APP_REPO="$(cd "${REPO_ROOT}/../spring-petclinic-microservices" && pwd)"
elif [ -d "${HOME}/spring-petclinic-microservices" ]; then
  APP_REPO="${HOME}/spring-petclinic-microservices"
else
  echo "ERROR: Could not find spring-petclinic-microservices."
  exit 1
fi

if [ ! -d "${APP_REPO}" ]; then
  echo "ERROR: App repo not found at: ${APP_REPO}"
  exit 1
fi

TFVARS="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}/terraform.tfvars"
if [ -f "${TFVARS}" ]; then
  AWS_REGION=$(grep "^aws_region" "${TFVARS}" \
    | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
fi
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-south-1}}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
DOCKERFILE="${APP_REPO}/docker/Dockerfile"

if [ -z "${TAG}" ]; then
  TAG=$(cd "${APP_REPO}" && git rev-parse --short HEAD 2>/dev/null || echo "v1.0.0")
fi

echo "=================================================="
echo " Build & Push Petclinic Images"
echo "=================================================="
echo " App repo  : ${APP_REPO}"
echo " Registry  : ${ECR_REGISTRY}"
echo " Env       : ${ENVIRONMENT}"
echo " Tag       : ${TAG}"
echo " Platform  : linux/arm64"
echo " Region    : ${AWS_REGION}"
echo "=================================================="

if [ ! -f "${DOCKERFILE}" ]; then
  echo "ERROR: Dockerfile not found at: ${DOCKERFILE}"
  exit 1
fi

echo ""
echo "[AUTH] Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"
echo "  ✅ Authenticated to ECR"

# ── Ensure buildx builder is healthy ─────────────────────────────────────────
# The petclinic-builder uses docker-container driver. After Docker Desktop
# restarts, the builder's mount becomes stale and all builds fail with:
#   "bind source path does not exist"
# This block auto-detects a stale builder and recreates it — fully automated,
# no manual "docker buildx rm" needed after every Docker Desktop restart.
echo ""
echo "[BUILDX] Checking buildx builder..."
BUILDER_NAME="petclinic-builder"
BUILDER_OK=false

if docker buildx inspect "${BUILDER_NAME}" &>/dev/null 2>&1; then
  # Builder exists — test if it actually works by running a no-op build
  if docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform linux/arm64 \
    --file - \
    . <<< "FROM scratch" \
    &>/dev/null 2>&1; then
    BUILDER_OK=true
    echo "  ✅ Builder ${BUILDER_NAME} is healthy"
  else
    echo "  ⚠️  Builder ${BUILDER_NAME} exists but is stale — recreating..."
  fi
else
  echo "  ⚠️  Builder ${BUILDER_NAME} not found — creating..."
fi

if [ "${BUILDER_OK}" = "false" ]; then
  # Remove stale builder (ignore errors if it doesn't exist)
  docker buildx rm "${BUILDER_NAME}" 2>/dev/null || true
  sleep 2

  # Create fresh builder with docker-container driver
  docker buildx create \
    --name "${BUILDER_NAME}" \
    --driver docker-container \
    --use

  # Bootstrap the builder (pulls buildkit image, verifies ARM64 support)
  docker buildx inspect "${BUILDER_NAME}" --bootstrap
  echo "  ✅ Builder ${BUILDER_NAME} created and ready"
fi

# Set this builder as active for all subsequent builds
docker buildx use "${BUILDER_NAME}"

declare -a SERVICES=(
  "config-server:spring-petclinic-config-server:8888"
  "discovery-server:spring-petclinic-discovery-server:8761"
  "api-gateway:spring-petclinic-api-gateway:8080"
  "customers-service:spring-petclinic-customers-service:8081"
  "visits-service:spring-petclinic-visits-service:8082"
  "vets-service:spring-petclinic-vets-service:8083"
  "genai-service:spring-petclinic-genai-service:8084"
  "admin-server:spring-petclinic-admin-server:9090"
)

FAILED=()
SUCCEEDED=()

for SERVICE_DEF in "${SERVICES[@]}"; do
  IFS=':' read -r SERVICE_NAME MODULE_DIR EXPOSED_PORT <<< "${SERVICE_DEF}"

  JAR_PATH=$(find "${APP_REPO}/${MODULE_DIR}/target" \
    -name "*.jar" \
    ! -name "*sources*" \
    ! -name "*javadoc*" \
    -maxdepth 1 2>/dev/null | head -1 || echo "")

  ECR_REPO="${ECR_REGISTRY}/petclinic-${ENVIRONMENT}/${SERVICE_NAME}"
  IMAGE_URI="${ECR_REPO}:${TAG}"

  echo ""
  echo "────────────────────────────────────────────────"
  echo "[BUILD] ${SERVICE_NAME}"
  echo "        Module : ${APP_REPO}/${MODULE_DIR}"
  echo "        Port   : ${EXPOSED_PORT}"
  echo "        Image  : ${IMAGE_URI}"
  echo "────────────────────────────────────────────────"

  if [ -z "${JAR_PATH}" ] || [ ! -f "${JAR_PATH}" ]; then
    echo "[ERROR] JAR not found in ${APP_REPO}/${MODULE_DIR}/target/"
    FAILED+=("${SERVICE_NAME}")
    continue
  fi

  echo "        JAR    : ${JAR_PATH}"
  ARTIFACT_NAME=$(basename "${JAR_PATH}" .jar)
  BUILD_DIR=$(mktemp -d)
  cp "${JAR_PATH}" "${BUILD_DIR}/${ARTIFACT_NAME}.jar"
  cp "${DOCKERFILE}" "${BUILD_DIR}/Dockerfile"

  # Use named builder explicitly — avoids fallback to stale default builder
  if docker buildx build \
    --builder "${BUILDER_NAME}" \
    --platform linux/arm64 \
    --build-arg "ARTIFACT_NAME=${ARTIFACT_NAME}" \
    --build-arg "EXPOSED_PORT=${EXPOSED_PORT}" \
    --tag "${IMAGE_URI}" \
    --push \
    "${BUILD_DIR}"; then
    echo "[OK] Pushed: ${IMAGE_URI}"
    SUCCEEDED+=("${SERVICE_NAME}")
  else
    echo "[FAIL] Build failed for: ${SERVICE_NAME}"
    FAILED+=("${SERVICE_NAME}")
  fi

  rm -rf "${BUILD_DIR}"
done

echo ""
echo "=================================================="
echo " Build Summary"
echo "=================================================="
echo " Tag: ${TAG}"
echo " Env: ${ENVIRONMENT}"
echo ""
if [ ${#SUCCEEDED[@]} -gt 0 ]; then
  echo " ✅ Succeeded (${#SUCCEEDED[@]}):"
  for s in "${SUCCEEDED[@]}"; do echo "    - ${s}"; done
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo " ❌ Failed (${#FAILED[@]}):"
  for f in "${FAILED[@]}"; do echo "    - ${f}"; done
  echo ""
  echo " To build JARs first:"
  echo "   cd ${APP_REPO}"
  echo "   ./mvnw clean install -DskipTests --no-transfer-progress --batch-mode"
  exit 1
fi

echo ""
echo " All images pushed successfully!"
echo " Registry : ${ECR_REGISTRY}/petclinic-${ENVIRONMENT}/"
echo " Tag      : ${TAG}"

# ── Auto-update helm-values/{env}/ image tags ────────────────────────────────
# Updates helm-values/{env}/{service}.yaml with the pushed tag.
# Dev and prod are now separate directories — no cross-contamination.
# CI/CD (update-image-tags.yml) also updates helm-values/dev/ automatically.
# This local update is for manual builds via build-push-images.sh.
echo ""
echo " Auto-updating helm-values/${ENVIRONMENT}/ image tags to ${TAG}..."

HELM_VALUES_ENV_DIR="${REPO_ROOT}/helm-values/${ENVIRONMENT}"

SERVICES_LIST=(
  "config-server" "discovery-server" "api-gateway"
  "customers-service" "visits-service" "vets-service"
  "genai-service" "admin-server"
)
UPDATED=0
for SERVICE in "${SERVICES_LIST[@]}"; do
  FILE="${HELM_VALUES_ENV_DIR}/${SERVICE}.yaml"
  if [ -f "${FILE}" ]; then
    CURRENT_TAG=$(yq '.image.tag' "${FILE}" 2>/dev/null || echo "")
    if [ "${CURRENT_TAG}" != "${TAG}" ]; then
      yq -i ".image.tag = \"${TAG}\"" "${FILE}"
      echo "   ✅ helm-values/${ENVIRONMENT}/${SERVICE}.yaml: ${CURRENT_TAG} → ${TAG}"
      UPDATED=$((UPDATED + 1))
    else
      echo "   ✅ helm-values/${ENVIRONMENT}/${SERVICE}.yaml: already ${TAG}"
    fi
  else
    echo "   ⚠️  helm-values/${ENVIRONMENT}/${SERVICE}.yaml not found — skipping"
  fi
done

if [ "${UPDATED}" -gt 0 ]; then
  echo ""
  echo " ⚠️  ${UPDATED} helm-values file(s) updated."
  echo "    Commit and push so ArgoCD picks up the new tags:"
  echo ""
  echo "   git add helm-values/${ENVIRONMENT}/"
  echo "   git commit -m 'config: update image tags to ${TAG}'"
  echo "   git push"
fi
echo "=================================================="
