#!/bin/bash
# ==========================================================
# pre-destroy.sh — Run BEFORE terraform destroy
#
# Cleans up resources Terraform doesn't manage:
#   1. K8s ingresses (causes ALBs to be deleted by LB Controller)
#   2. Leftover ALBs in the VPC
#   3. Leftover LB security groups
#   4. ECR images (so repos can be deleted by Terraform)
#
# Usage:
#   ./scripts/pre-destroy.sh           # defaults to dev
#   ./scripts/pre-destroy.sh --env prod
#   ./scripts/pre-destroy.sh --env dev --region us-west-2
#
# Must be run before terraform destroy, otherwise:
#   - ALBs created by the LB Controller block VPC deletion
#   - ECR repos with images block repo deletion
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────────
ENV="dev"
REGION=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)    ENV="$2";    shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Derive region from tfvars if not provided ─────────────────────────────────
TFVARS="${REPO_ROOT}/terraform/environments/${ENV}/terraform.tfvars"
if [ -z "${REGION}" ]; then
  if [ -f "${TFVARS}" ]; then
    REGION=$(grep "^aws_region" "${TFVARS}" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
  fi
  if [ -z "${REGION}" ]; then
    REGION=$(aws configure get region 2>/dev/null || echo "ap-south-1")
  fi
fi

PROJECT="petclinic"

echo "=============================================="
echo " Pre-Destroy Cleanup"
echo " Environment : ${ENV}"
echo " Region      : ${REGION}"
echo "=============================================="

# ── Get VPC ID from terraform state ──────────────────────────────────────────
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"
VPC_ID=""
if [ -d "${TF_DIR}/.terraform" ]; then
  VPC_ID=$(cd "${TF_DIR}" && terraform output -raw vpc_id 2>/dev/null || echo "")
fi

if [ -n "${VPC_ID}" ]; then
  echo " VPC ID      : ${VPC_ID}"
else
  echo " VPC ID      : NOT FOUND (terraform state not available)"
fi

# ── Step 1: Delete K8s ingresses so LB Controller removes ALBs ───────────────
echo ""
echo "[1/4] Deleting Kubernetes ingresses..."
if kubectl cluster-info &>/dev/null 2>&1; then
  kubectl delete ingress --all -n "petclinic-${ENV}" 2>/dev/null \
    && echo "  ✅ petclinic-${ENV} ingresses deleted" || echo "  ⚠️  No ingresses in petclinic-${ENV}"
  kubectl delete ingress --all -n monitoring 2>/dev/null \
    && echo "  ✅ monitoring ingresses deleted" || echo "  ⚠️  No ingresses in monitoring"
  kubectl delete ingress --all -n argocd 2>/dev/null \
    && echo "  ✅ argocd ingresses deleted" || echo "  ⚠️  No ingresses in argocd"
  echo "  Waiting 90s for LB Controller to delete ALBs..."
  sleep 90
else
  echo "  ⚠️  kubectl not connected — skipping ingress deletion"
  echo "     If ALBs exist, delete them manually in AWS Console before terraform destroy"
fi

# ── Step 2: Force delete any remaining ALBs in VPC ───────────────────────────
echo ""
echo "[2/4] Checking for remaining ALBs..."
if [ -n "${VPC_ID}" ]; then
  ALBS=$(aws elbv2 describe-load-balancers \
    --region "${REGION}" \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")
  if [ -n "${ALBS}" ] && [ "${ALBS}" != "None" ]; then
    for ARN in ${ALBS}; do
      echo "  Deleting ALB: ${ARN}"
      aws elbv2 delete-load-balancer \
        --load-balancer-arn "${ARN}" \
        --region "${REGION}"
    done
    echo "  Waiting 60s for ALBs to finish deleting..."
    sleep 60
    echo "  ✅ ALBs deleted"
  else
    echo "  ✅ No ALBs found in VPC"
  fi
else
  echo "  ⚠️  VPC ID unknown — skipping ALB cleanup"
  echo "     Check manually: aws elbv2 describe-load-balancers --region ${REGION}"
fi

# ── Step 3: Delete leftover LB security groups ────────────────────────────────
echo ""
echo "[3/4] Checking for leftover LB security groups (k8s-* prefix)..."
if [ -n "${VPC_ID}" ]; then
  SGS=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?starts_with(GroupName,'k8s-')].GroupId" \
    --output text 2>/dev/null || echo "")
  if [ -n "${SGS}" ] && [ "${SGS}" != "None" ]; then
    for SG in ${SGS}; do
      echo "  Deleting SG: ${SG}"
      aws ec2 delete-security-group \
        --group-id "${SG}" \
        --region "${REGION}" 2>/dev/null \
        || echo "  ⚠️  Could not delete ${SG} (may still have dependencies — retry after a moment)"
    done
    echo "  ✅ Leftover LB security groups deleted"
  else
    echo "  ✅ No leftover LB security groups found"
  fi
else
  echo "  ⚠️  VPC ID unknown — skipping SG cleanup"
fi

# ── Step 4: Force delete ECR repos (clears images) ───────────────────────────
echo ""
echo "[4/4] Clearing ECR repositories (deleting images so Terraform can delete repos)..."
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
  FULL_REPO="${PROJECT}-${ENV}/${SERVICE}"
  EXISTS=$(aws ecr describe-repositories \
    --repository-names "${FULL_REPO}" \
    --region "${REGION}" \
    --query "repositories[0].repositoryName" \
    --output text 2>/dev/null || echo "")
  if [ -n "${EXISTS}" ] && [ "${EXISTS}" != "None" ]; then
    aws ecr delete-repository \
      --repository-name "${FULL_REPO}" \
      --force \
      --region "${REGION}" &>/dev/null \
      && echo "  ✅ Deleted: ${FULL_REPO}" \
      || echo "  ⚠️  Could not delete: ${FULL_REPO}"
  else
    echo "  ℹ️  Not found (already deleted): ${FULL_REPO}"
  fi
done

# ── Final instructions ────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Pre-destroy cleanup complete!"
echo "=============================================="
echo ""
echo " Now run terraform destroy:"
echo ""
echo "   ./scripts/tf.sh ${ENV} destroy"
echo ""
echo " If destroy fails due to security group dependencies,"
echo " wait 2-3 minutes and retry — AWS takes time to clean up ENIs."
echo "=============================================="
