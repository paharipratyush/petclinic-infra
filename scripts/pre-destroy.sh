#!/bin/bash
# ==========================================================
# pre-destroy.sh — Run BEFORE terraform destroy
# ==========================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV="dev"
REGION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)    ENV="$2";    shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

TFVARS="${REPO_ROOT}/terraform/environments/${ENV}/terraform.tfvars"
if [ -z "${REGION}" ]; then
  if [ -f "${TFVARS}" ]; then
    REGION=$(grep "^aws_region" "${TFVARS}" \
      | sed 's/.*=\s*//' | tr -d '"' | tr -d "'" | tr -d ' ')
  fi
  REGION=${REGION:-$(aws configure get region 2>/dev/null || echo "ap-south-1")}
fi

PROJECT="petclinic"
TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

echo "=============================================="
echo " Pre-Destroy Cleanup"
echo " Environment : ${ENV}"
echo " Region      : ${REGION}"
echo "=============================================="

VPC_ID=""
if [ -d "${TF_DIR}/.terraform" ]; then
  VPC_ID=$(cd "${TF_DIR}" && terraform output -raw vpc_id 2>/dev/null || echo "")
fi

echo " VPC ID      : ${VPC_ID:-NOT FOUND}"

# ── Step 0: Terminate ALL EC2 instances in VPC ────────────────────────────────
# Terminates both Karpenter nodes and EKS managed nodes.
# Must wait for full termination before proceeding — otherwise ENIs block cleanup.
echo ""
echo "[0/6] Terminating all EC2 instances in VPC..."

# 0a: Delete Karpenter NodeClaims
if kubectl cluster-info &>/dev/null 2>&1; then
  NODECLAIMS=$(kubectl get nodeclaim \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [ -n "${NODECLAIMS}" ]; then
    echo "  Deleting NodeClaims: ${NODECLAIMS}"
    kubectl delete nodeclaim --all --timeout=60s 2>/dev/null || true
  else
    echo "  ✅ No NodeClaims found"
  fi
fi

# 0b: Terminate ALL instances in VPC (Karpenter + managed nodes)
if [ -n "${VPC_ID}" ]; then
  ALL_INSTANCES=$(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
              "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query "Reservations[*].Instances[*].InstanceId" \
    --output text 2>/dev/null || echo "")

  if [ -n "${ALL_INSTANCES}" ] && [ "${ALL_INSTANCES}" != "None" ]; then
    echo "  Terminating instances: ${ALL_INSTANCES}"
    aws ec2 terminate-instances \
      --instance-ids ${ALL_INSTANCES} \
      --region "${REGION}" 2>/dev/null || true
    echo "  Waiting for all instances to terminate (up to 5 min)..."
    aws ec2 wait instance-terminated \
      --instance-ids ${ALL_INSTANCES} \
      --region "${REGION}" 2>/dev/null || true
    echo "  ✅ All instances terminated"
  else
    echo "  ✅ No running instances found"
  fi
fi

# ── Step 1: Delete K8s ingresses ──────────────────────────────────────────────
echo ""
echo "[1/6] Deleting Kubernetes ingresses..."
if kubectl cluster-info &>/dev/null 2>&1; then
  for NS in "petclinic-${ENV}" monitoring argocd tracing; do
    kubectl delete ingress --all -n "${NS}" 2>/dev/null \
      && echo "  ✅ ${NS} ingresses deleted" \
      || echo "  ⚠️  No ingresses in ${NS}"
  done
  echo "  Waiting 120s for LB Controller to delete ALBs..."
  sleep 120
else
  echo "  ⚠️  kubectl not connected — skipping"
fi

# ── Step 2: Force delete remaining ALBs ───────────────────────────────────────
echo ""
echo "[2/6] Checking for remaining ALBs..."
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
        --region "${REGION}" 2>/dev/null || true
    done
    echo "  Waiting 60s for ALBs to finish deleting..."
    sleep 60
    echo "  ✅ ALBs deleted"
  else
    echo "  ✅ No ALBs found"
  fi
fi

# ── Step 3: Revoke ALL cross-SG ingress rules in VPC ─────────────────────────
# CRITICAL: Must revoke cross-SG rules BEFORE deleting SGs.
# Terraform cross-module deletion order is unpredictable — rules added in
# environments/dev/main.tf may not be revoked before vpc module SGs are deleted.
echo ""
echo "[3/6] Revoking all cross-SG ingress rules in VPC..."
if [ -n "${VPC_ID}" ]; then
  ALL_SGS=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || echo "")

  for SG in ${ALL_SGS}; do
    PERMS=$(aws ec2 describe-security-groups \
      --region "${REGION}" \
      --group-ids "${SG}" \
      --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId!='']]" \
      --output json 2>/dev/null || echo "[]")

    COUNT=$(echo "${PERMS}" | python3 -c \
      "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [ "${COUNT}" != "0" ] && [ "${PERMS}" != "[]" ]; then
      echo "  Revoking ${COUNT} cross-SG rule(s) from ${SG}..."
      aws ec2 revoke-security-group-ingress \
        --group-id "${SG}" \
        --ip-permissions "${PERMS}" \
        --region "${REGION}" 2>/dev/null && \
        echo "  ✅ Revoked from ${SG}" || \
        echo "  ⚠️  Could not revoke from ${SG}"
    fi
  done
  echo "  ✅ Cross-SG rules revoked"
fi

# ── Step 4: Delete leftover k8s-* security groups ────────────────────────────
echo ""
echo "[4/6] Checking for leftover LB security groups (k8s-* prefix)..."
if [ -n "${VPC_ID}" ]; then
  SGS=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?starts_with(GroupName,'k8s-')].GroupId" \
    --output text 2>/dev/null || echo "")

  if [ -n "${SGS}" ] && [ "${SGS}" != "None" ]; then
    sleep 15
    for SG in ${SGS}; do
      for attempt in 1 2 3; do
        if aws ec2 delete-security-group \
          --group-id "${SG}" \
          --region "${REGION}" 2>/dev/null; then
          echo "  ✅ Deleted: ${SG}"
          break
        else
          [ $attempt -lt 3 ] && sleep 15 || \
            echo "  ⚠️  Could not delete ${SG} — terraform will handle it"
        fi
      done
    done
  else
    echo "  ✅ No leftover LB security groups found"
  fi
fi

# ── Step 5: Delete any remaining non-default SGs ──────────────────────────────
# Catches EKS cluster managed SG and any other orphaned SGs
echo ""
echo "[5/6] Cleaning up remaining non-default security groups..."
if [ -n "${VPC_ID}" ]; then
  REMAINING_SGS=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" \
    --output text 2>/dev/null || echo "")

  if [ -n "${REMAINING_SGS}" ] && [ "${REMAINING_SGS}" != "None" ]; then
    for SG in ${REMAINING_SGS}; do
      aws ec2 delete-security-group \
        --group-id "${SG}" \
        --region "${REGION}" 2>/dev/null && \
        echo "  ✅ Deleted: ${SG}" || \
        echo "  ⚠️  Could not delete ${SG} — terraform will handle it"
    done
  else
    echo "  ✅ No remaining security groups"
  fi
fi

# ── Step 6: Clear ECR repositories ───────────────────────────────────────────
echo ""
echo "[6/6] Clearing ECR repositories..."
SERVICES=(
  "config-server" "discovery-server" "api-gateway"
  "customers-service" "visits-service" "vets-service"
  "genai-service" "admin-server"
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
    echo "  ℹ️  Not found: ${FULL_REPO}"
  fi
done

echo ""
echo "=============================================="
echo " Pre-destroy cleanup complete!"
echo "=============================================="
echo ""
echo " Now run terraform destroy:"
echo "   cd terraform/environments/${ENV}"
echo "   terraform destroy"
echo "=============================================="
