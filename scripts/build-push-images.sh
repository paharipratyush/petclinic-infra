#!/bin/bash
# Build ARM64 Docker images for all 8 Petclinic services and push to ECR
#
# Usage:
#   ./scripts/build-push-images.sh
#   ./scripts/build-push-images.sh --tag v1.0.0
#
# Prerequisites:
#   - Docker Desktop with ARM64 support (docker buildx inspect shows linux/arm64)
#   - AWS CLI configured
#   - ECR repos already created (terraform apply done)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_DEFAULT_REGION:-ap-south-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
APP_REPO="${HOME}/spring-petclinic-microservices"
DOCKERFILE="${APP_REPO}/docker/Dockerfile"
ENVIRONMENT="dev"
TAG="${1:-}"

# Use git SHA if no tag provided
if [ -z "${TAG}" ]; then
  TAG=$(cd "${APP_REPO}" && git rev-parse --short HEAD)
fi

# Parse --tag argument
while [[ $# -gt 0 ]]; do
  case $1 in
    --tag) TAG="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "=================================================="
echo " Build & Push Petclinic Images"
echo "=================================================="
echo " Registry  : ${ECR_REGISTRY}"
echo " Tag       : ${TAG}"
echo " Platform  : linux/arm64"
echo " App repo  : ${APP_REPO}"
echo "=================================================="

# ── ECR Login ─────────────────────────────────────────────────────────────────
echo ""
echo "[AUTH] Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ── Service definitions ───────────────────────────────────────────────────────
# Format: "service-name:jar-artifact-name:exposed-port"
declare -a SERVICES=(
  "config-server:spring-petclinic-config-server-4.0.1:8888"
  "discovery-server:spring-petclinic-discovery-server-4.0.1:8761"
  "api-gateway:spring-petclinic-api-gateway-4.0.1:8080"
  "customers-service:spring-petclinic-customers-service-4.0.1:8081"
  "visits-service:spring-petclinic-visits-service-4.0.1:8082"
  "vets-service:spring-petclinic-vets-service-4.0.1:8083"
  "genai-service:spring-petclinic-genai-service-4.0.1:8084"
  "admin-server:spring-petclinic-admin-server-4.0.1:9090"
)

# ── Build and push each service ───────────────────────────────────────────────
FAILED=()
SUCCEEDED=()

for SERVICE_DEF in "${SERVICES[@]}"; do
  IFS=':' read -r SERVICE_NAME ARTIFACT_NAME EXPOSED_PORT <<< "${SERVICE_DEF}"

  JAR_PATH="${APP_REPO}/${SERVICE_NAME//-service/}-service/target/${ARTIFACT_NAME}.jar"

  # Handle naming mismatches between dir names and service names
  case "${SERVICE_NAME}" in
    config-server)
      JAR_PATH="${APP_REPO}/spring-petclinic-config-server/target/${ARTIFACT_NAME}.jar" ;;
    discovery-server)
      JAR_PATH="${APP_REPO}/spring-petclinic-discovery-server/target/${ARTIFACT_NAME}.jar" ;;
    api-gateway)
      JAR_PATH="${APP_REPO}/spring-petclinic-api-gateway/target/${ARTIFACT_NAME}.jar" ;;
    customers-service)
      JAR_PATH="${APP_REPO}/spring-petclinic-customers-service/target/${ARTIFACT_NAME}.jar" ;;
    visits-service)
      JAR_PATH="${APP_REPO}/spring-petclinic-visits-service/target/${ARTIFACT_NAME}.jar" ;;
    vets-service)
      JAR_PATH="${APP_REPO}/spring-petclinic-vets-service/target/${ARTIFACT_NAME}.jar" ;;
    genai-service)
      JAR_PATH="${APP_REPO}/spring-petclinic-genai-service/target/${ARTIFACT_NAME}.jar" ;;
    admin-server)
      JAR_PATH="${APP_REPO}/spring-petclinic-admin-server/target/${ARTIFACT_NAME}.jar" ;;
  esac

  ECR_REPO="${ECR_REGISTRY}/petclinic-${ENVIRONMENT}/${SERVICE_NAME}"
  IMAGE_URI="${ECR_REPO}:${TAG}"

  echo ""
  echo "────────────────────────────────────────────────"
  echo "[BUILD] ${SERVICE_NAME}"
  echo "        JAR  : ${JAR_PATH}"
  echo "        Image: ${IMAGE_URI}"
  echo "────────────────────────────────────────────────"

  if [ ! -f "${JAR_PATH}" ]; then
    echo "[ERROR] JAR not found: ${JAR_PATH}"
    FAILED+=("${SERVICE_NAME}")
    continue
  fi

  # Copy JAR to build context (Dockerfile expects it in same dir)
  BUILD_DIR=$(mktemp -d)
  cp "${JAR_PATH}" "${BUILD_DIR}/${ARTIFACT_NAME}.jar"
  cp "${DOCKERFILE}" "${BUILD_DIR}/Dockerfile"

  if docker buildx build \
    --platform linux/arm64 \
    --build-arg ARTIFACT_NAME="${ARTIFACT_NAME}" \
    --build-arg EXPOSED_PORT="${EXPOSED_PORT}" \
    --tag "${IMAGE_URI}" \
    --push \
    "${BUILD_DIR}"; then
    echo "[OK] ${SERVICE_NAME} pushed: ${IMAGE_URI}"
    SUCCEEDED+=("${SERVICE_NAME}")
  else
    echo "[FAIL] ${SERVICE_NAME} build failed"
    FAILED+=("${SERVICE_NAME}")
  fi

  rm -rf "${BUILD_DIR}"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=================================================="
echo " Build Summary"
echo "=================================================="
echo " Tag: ${TAG}"
echo ""
echo " ✅ Succeeded (${#SUCCEEDED[@]}):"
for s in "${SUCCEEDED[@]}"; do echo "    - ${s}"; done

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  echo " ❌ Failed (${#FAILED[@]}):"
  for f in "${FAILED[@]}"; do echo "    - ${f}"; done
  exit 1
fi

echo ""
echo "All images pushed successfully!"
echo "Image tag: ${TAG}"
echo ""
echo "Use this tag when deploying:"
echo "  export IMAGE_TAG=${TAG}"
