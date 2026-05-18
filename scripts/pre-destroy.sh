#!/bin/bash
# ==========================================================
# pre-destroy.sh — Run BEFORE terraform destroy
#
# Cleans up resources Terraform doesn't manage:
#   0. Karpenter-provisioned nodes (EC2 instances)
#   1. K8s ingresses (causes ALBs to be deleted by LB Controller)
#   2. Leftover ALBs in the VPC
#   3. Leftover LB security groups (k8s-* prefix)
#      - Revokes cross-SG references before deleting
#   4. ECR images (so repos can be deleted by Terraform)
#
# Usage:
#   ./scripts/pre-destroy.sh           # defaults to dev
#   ./scripts/pre-destroy.sh --env prod
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
  if [ -z "${REGION}" ]; then
    REGION=$(aws configure get region 2>/dev/null || echo "ap-south-1")
  fi
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

if [ -n "${VPC_ID}" ]; then
  echo " VPC ID      : ${VPC_ID}"
else
  echo " VPC ID      : NOT FOUND (terraform state not available)"
fi

# ── Step 0: Terminate Karpenter-provisioned nodes ─────────────────────────────
echo ""
echo "[0/5] Terminating Karpenter-provisioned nodes..."
if kubectl cluster-info &>/dev/null 2>&1; then
  NODECLAIMS=$(kubectl get nodeclaim \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  if [ -n "${NODECLAIMS}" ]; then
    echo "  Deleting NodeClaims: ${NODECLAIMS}"
    kubectl delete nodeclaim --all --timeout=60s 2>/dev/null || true
    echo "  Waiting 60s for Karpenter to terminate EC2 instances..."
    sleep 60
  else
    echo "  ✅ No NodeClaims found"
  fi
fi

KARPENTER_INSTANCES=$(aws ec2 describe-instances \
  --region "${REGION}" \
  --filters "Name=tag:karpenter.sh/nodepool,Values=default" \
            "Name=instance-state-name,Values=pending,running,stopping" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text 2>/dev/null || echo "")

if [ -n "${KARPENTER_INSTANCES}" ] && [ "${KARPENTER_INSTANCES}" != "None" ]; then
  echo "  Force terminating Karpenter instances: ${KARPENTER_INSTANCES}"
  aws ec2 terminate-instances \
    --instance-ids ${KARPENTER_INSTANCES} \
    --region "${REGION}" 2>/dev/null || true
  echo "  Waiting 45s for instances to terminate..."
  sleep 45
  echo "  ✅ Karpenter instances terminated"
else
  echo "  ✅ No Karpenter EC2 instances found"
fi

# ── Step 1: Delete K8s ingresses ──────────────────────────────────────────────
echo ""
echo "[1/5] Deleting Kubernetes ingresses..."
if kubectl cluster-info &>/dev/null 2>&1; then
  kubectl delete ingress --all -n "petclinic-${ENV}" 2>/dev/null \
    && echo "  ✅ petclinic-${ENV} ingresses deleted" \
    || echo "  ⚠️  No ingresses in petclinic-${ENV}"
  kubectl delete ingress --all -n monitoring 2>/dev/null \
    && echo "  ✅ monitoring ingresses deleted" \
    || echo "  ⚠️  No ingresses in monitoring"
  kubectl delete ingress --all -n argocd 2>/dev/null \
    && echo "  ✅ argocd ingresses deleted" \
    || echo "  ⚠️  No ingresses in argocd"
  kubectl delete ingress --all -n tracing 2>/dev/null \
    && echo "  ✅ tracing ingresses deleted" \
    || echo "  ⚠️  No ingresses in tracing"
  echo "  Waiting 120s for LB Controller to delete ALBs..."
  sleep 120
else
  echo "  ⚠️  kubectl not connected — skipping ingress deletion"
fi

# ── Step 2: Force delete remaining ALBs ───────────────────────────────────────
echo ""
echo "[2/5] Checking for remaining ALBs..."
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
    echo "  ✅ No ALBs found in VPC"
  fi
fi

# ── Step 3: Delete leftover LB security groups ────────────────────────────────
# ALB Controller creates k8s-* and k8s-traffic-* SGs.
# These SGs may be referenced by other SGs (cross-SG rules).
# Must revoke those references before deleting the SG.
echo ""
echo "[3/5] Checking for leftover LB security groups (k8s-* prefix)..."
if [ -n "${VPC_ID}" ]; then
  SGS=$(aws ec2 describe-security-groups \
    --region "${REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?starts_with(GroupName,'k8s-')].GroupId" \
    --output text 2>/dev/null || echo "")

  if [ -n "${SGS}" ] && [ "${SGS}" != "None" ]; then
    echo "  Waiting 30s for ENIs to detach..."
    sleep 30

    for SG in ${SGS}; do
      echo "  Processing SG: ${SG}"

      # Step 3a: Find all OTHER SGs that have inbound rules referencing this SG
      # and revoke those rules first — otherwise deletion fails with DependencyViolation
      REFERENCING_SGS=$(aws ec2 describe-security-groups \
        --region "${REGION}" \
        --filters "Name=vpc-id,Values=${VPC_ID}" \
        --query "SecurityGroups[?IpPermissions[?UserIdGroupPairs[?GroupId=='${SG}']]].GroupId" \
        --output text 2>/dev/null || echo "")

      if [ -n "${REFERENCING_SGS}" ] && [ "${REFERENCING_SGS}" != "None" ]; then
        for REF_SG in ${REFERENCING_SGS}; do
          echo "  Revoking inbound rule in ${REF_SG} that references ${SG}..."
          # Get the full permission set for the referencing rule
          PERMS=$(aws ec2 describe-security-groups \
            --region "${REGION}" \
            --group-ids "${REF_SG}" \
            --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId=='${SG}']]" \
            --output json 2>/dev/null || echo "[]")
          if [ "${PERMS}" != "[]" ] && [ -n "${PERMS}" ]; then
            aws ec2 revoke-security-group-ingress \
              --group-id "${REF_SG}" \
              --ip-permissions "${PERMS}" \
              --region "${REGION}" 2>/dev/null && \
              echo "  ✅ Revoked reference in ${REF_SG}" || \
              echo "  ⚠️  Could not revoke reference in ${REF_SG}"
          fi
        done
      fi

      # Step 3b: Also revoke egress rules in this SG that reference other SGs
      EGRESS_REFS=$(aws ec2 describe-security-groups \
        --region "${REGION}" \
        --group-ids "${SG}" \
        --query "SecurityGroups[0].IpPermissionsEgress[?UserIdGroupPairs[?GroupId!='']].UserIdGroupPairs[*].GroupId" \
        --output text 2>/dev/null || echo "")

      # Step 3c: Delete the SG with retries
      DELETED=false
      for attempt in 1 2 3; do
        if aws ec2 delete-security-group \
          --group-id "${SG}" \
          --region "${REGION}" 2>/dev/null; then
          echo "  ✅ Deleted: ${SG}"
          DELETED=true
          break
        else
          if [ $attempt -lt 3 ]; then
            echo "  ⚠️  Attempt ${attempt} failed — waiting 20s..."
            sleep 20
          else
            echo "  ⚠️  Could not delete ${SG} — terraform destroy will handle it"
          fi
        fi
      done
    done
    echo "  ✅ Leftover LB security groups processed"
  else
    echo "  ✅ No leftover LB security groups found"
  fi
fi

# ── Step 4: Clear ECR repositories ───────────────────────────────────────────
echo ""
echo "[4/5] Clearing ECR repositories..."
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
