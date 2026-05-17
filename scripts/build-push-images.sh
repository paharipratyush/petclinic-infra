#!/bin/bash
# Build ARM64 Docker images for all 8 Petclinic services and push to ECR
#
# Usage:
#   ./scripts/build-push-images.sh                          # auto-detect app repo, git SHA tag
#   ./scripts/build-push-images.sh --tag v1.0.0             # custom tag
#   ./scripts/build-push-images.sh --app-repo /path/to/app  # explicit app repo path
#   ./scripts/build-push-images.sh --env prod               # push to prod ECR repos
#   ./scripts/build-push-images.sh --tag v1.0.0 --env dev --app-repo ~/myapp
#
# App repo auto-detection order:
#   1. --app-repo argument
#   2. APP_REPO environment variable
#   3. Sibling directory: {infra_repo}/../spring-petclinic-microservices
#   4. $HOME/spring-petclinic-microservices (fallback)
#
# Prerequisites:
#   - Docker Desktop with ARM64 support (docker buildx inspect shows linux/arm64)
#   - AWS CLI configured
#   - ECR repos already created (terraform apply + generate-config.sh done)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
ENVIRONMENT="dev"
TAG=""
APP_REPO_ARG=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --tag)      TAG="$2";          shift 2 ;;
    --env)      ENVIRONMENT="$2";  shift 2 ;;
    --app-repo) APP_REPO_ARG="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Resolve app repo path ─────────────────────────────────────────────────────
# Priority: --app-repo arg > APP_REPO env var > sibling dir > $HOME fallback
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
  echo ""
  echo "Options:"
  echo "  1. Pass --app-repo /path/to/spring-petclinic-microservices"
  echo "  2. Set APP_REPO=/path/to/spring-petclinic-microservices"
  echo "  3. Clone it as a sibling of this repo:"
  echo "     git clone https://github.com/your-fork/spring-petclinic-microservices ${REPO_ROOT}/../spring-petclinic-microservices"
  exit 1
fi

if [ ! -d "${APP_REPO}" ]; then
  echo "ERROR: App repo not found at: ${APP_REPO}"
  echo "Pass the correct path with: --app-repo /path/to/spring-petclinic-microservices"
  exit 1
fi

# ── Derive AWS config from tfvars ─────────────────────────────────────────────
TFVARS="${REPO_ROOT}/terraform/environments/${ENVIRONMENT}/terraform.tfvars"
if [ -f "${TFVARS}" ]; then
  AWS_REGION=$(grep "^aws_region" "${TFVARS}" \
    | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
fi
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-south-1}}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
DOCKERFILE="${APP_REPO}/docker/Dockerfile"

# ── Use git SHA if no tag provided ────────────────────────────────────────────
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

# ── Verify Dockerfile exists ──────────────────────────────────────────────────
if [ ! -f "${DOCKERFILE}" ]; then
  echo "ERROR: Dockerfile not found at: ${DOCKERFILE}"
  echo "Make sure you are pointing to the correct app repo."
  exit 1
fi

# ── ECR Login ─────────────────────────────────────────────────────────────────
echo ""
echo "[AUTH] Logging in to ECR..."
aws ecr get-login-password --region "${AWS_REGION}" | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"
echo "  ✅ Authenticated to ECR"

# ── Service definitions ───────────────────────────────────────────────────────
# Format: "ecr-name:maven-module-dir:exposed-port"
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

# ── Build and push each service ───────────────────────────────────────────────
FAILED=()
SUCCEEDED=()

for SERVICE_DEF in "${SERVICES[@]}"; do
  IFS=':' read -r SERVICE_NAME MODULE_DIR EXPOSED_PORT <<< "${SERVICE_DEF}"

  # Find the JAR — look for any matching jar in the target directory
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
    echo "        Run first: cd ${APP_REPO} && ./mvnw clean install -DskipTests"
    FAILED+=("${SERVICE_NAME}")
    continue
  fi

  echo "        JAR    : ${JAR_PATH}"

  # Derive artifact name from JAR filename (without .jar extension)
  ARTIFACT_NAME=$(basename "${JAR_PATH}" .jar)

  # Create isolated build context with just the JAR and Dockerfile
  BUILD_DIR=$(mktemp -d)
  cp "${JAR_PATH}" "${BUILD_DIR}/${ARTIFACT_NAME}.jar"
  cp "${DOCKERFILE}" "${BUILD_DIR}/Dockerfile"

  if docker buildx build \
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

# ── Summary ───────────────────────────────────────────────────────────────────
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
echo ""
echo " Next step — update helm-values with this tag:"
echo "   ./scripts/generate-config.sh ${ENVIRONMENT}"
echo "=================================================="
