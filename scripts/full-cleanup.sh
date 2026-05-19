#!/bin/bash
# ==========================================================
# full-cleanup.sh — Destroys ALL infrastructure for both
# dev and prod environments in the correct order.
#
# Usage:
#   ./scripts/full-cleanup.sh           # destroys both
#   ./scripts/full-cleanup.sh --env dev  # destroys dev only
#   ./scripts/full-cleanup.sh --env prod # destroys prod only
# ==========================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TARGET_ENV="${1:-both}"
if [[ "$*" == *"--env dev"* ]]; then TARGET_ENV="dev"; fi
if [[ "$*" == *"--env prod"* ]]; then TARGET_ENV="prod"; fi

REGION="ap-south-1"

echo "=============================================="
echo " Full Cleanup"
echo " Target      : ${TARGET_ENV}"
echo " Region      : ${REGION}"
echo "=============================================="
echo ""
echo " This will PERMANENTLY DESTROY:"
if [ "${TARGET_ENV}" = "both" ] || [ "${TARGET_ENV}" = "dev" ]; then
  echo "   - petclinic-dev EKS cluster"
  echo "   - petclinic-dev RDS instance"
  echo "   - petclinic-dev VPC and all networking"
  echo "   - petclinic-dev ECR repositories"
fi
if [ "${TARGET_ENV}" = "both" ] || [ "${TARGET_ENV}" = "prod" ]; then
  echo "   - petclinic-prod EKS cluster"
  echo "   - petclinic-prod RDS instance"
  echo "   - petclinic-prod VPC and all networking"
  echo "   - petclinic-prod ECR repositories"
fi
echo ""
read -r -p " Type 'destroy' to confirm: " CONFIRM
if [ "${CONFIRM}" != "destroy" ]; then
  echo " Aborted."
  exit 1
fi

# ── Helper: cleanup one environment ──────────────────────────────────────────
cleanup_env() {
  local ENV="$1"
  local TF_DIR="${REPO_ROOT}/terraform/environments/${ENV}"

  echo ""
  echo "=============================================="
  echo " Cleaning up ${ENV} environment"
  echo "=============================================="

  # ── Step 1: Switch kubectl context ─────────────────────────────────────────
  echo ""
  echo "[1/4] Switching kubectl to ${ENV} cluster..."
  aws eks update-kubeconfig \
    --name "petclinic-${ENV}" \
    --region "${REGION}" 2>/dev/null && \
    echo "  ✅ kubectl configured for petclinic-${ENV}" || \
    echo "  ⚠️  Could not configure kubectl — cluster may already be gone"

  # ── Step 2: Delete Helm releases and K8s resources ─────────────────────────
  echo ""
  echo "[2/4] Deleting Kubernetes resources..."

  if kubectl cluster-info &>/dev/null 2>&1; then
    # Delete ArgoCD apps first — stops recreation of K8s resources
    echo "  Deleting ArgoCD applications..."
    kubectl delete applications --all -n argocd \
      --timeout=60s 2>/dev/null || true
    sleep 10

    # Delete ingresses — releases ALBs before VPC destroy
    echo "  Deleting ingresses..."
    for NS in "petclinic-${ENV}" monitoring argocd tracing; do
      kubectl delete ingress --all -n "${NS}" \
        2>/dev/null || true
    done
    echo "  Waiting 60s for ALB Controller to release ALBs..."
    sleep 60

    # Delete Karpenter resources — terminates Karpenter-provisioned nodes
    echo "  Deleting Karpenter NodePool and EC2NodeClass..."
    kubectl delete nodepool --all 2>/dev/null || true
    kubectl delete ec2nodeclass --all 2>/dev/null || true
    sleep 30

    # Uninstall Helm releases in correct order
    echo "  Uninstalling Helm releases..."
    helm uninstall karpenter \
      -n kube-system 2>/dev/null && \
      echo "  ✅ karpenter" || true
    helm uninstall aws-load-balancer-controller \
      -n kube-system 2>/dev/null && \
      echo "  ✅ aws-load-balancer-controller" || true
    helm uninstall prometheus \
      -n monitoring 2>/dev/null && \
      echo "  ✅ prometheus" || true
    helm uninstall grafana \
      -n monitoring 2>/dev/null && \
      echo "  ✅ grafana" || true
    helm uninstall loki \
      -n monitoring 2>/dev/null && \
      echo "  ✅ loki" || true
    helm uninstall fluent-bit \
      -n monitoring 2>/dev/null && \
      echo "  ✅ fluent-bit" || true
    helm uninstall external-secrets \
      -n external-secrets 2>/dev/null && \
      echo "  ✅ external-secrets" || true
    helm uninstall argocd \
      -n argocd 2>/dev/null && \
      echo "  ✅ argocd" || true
    sleep 20
    echo "  ✅ Helm releases uninstalled"
  else
    echo "  ⚠️  kubectl not connected — skipping K8s cleanup"
  fi

  # ── Step 3: Run pre-destroy.sh ─────────────────────────────────────────────
  echo ""
  echo "[3/4] Running pre-destroy cleanup..."
  "${SCRIPT_DIR}/pre-destroy.sh" --env "${ENV}" --region "${REGION}" || true

  # ── Step 4: Terraform destroy ──────────────────────────────────────────────
  echo ""
  echo "[4/4] Running terraform destroy for ${ENV}..."
  if [ -d "${TF_DIR}/.terraform" ]; then
    cd "${TF_DIR}"
    terraform destroy -auto-approve 2>&1 | tail -20
    cd "${REPO_ROOT}"
    echo "  ✅ Terraform destroy complete for ${ENV}"
  else
    echo "  ⚠️  Terraform not initialized in ${TF_DIR}"
    echo "      Run: cd ${TF_DIR} && terraform init"
  fi
}

# ── Run cleanup for target environments ──────────────────────────────────────
if [ "${TARGET_ENV}" = "both" ] || [ "${TARGET_ENV}" = "prod" ]; then
  cleanup_env "prod"
fi

if [ "${TARGET_ENV}" = "both" ] || [ "${TARGET_ENV}" = "dev" ]; then
  cleanup_env "dev"
fi

# ── Final verification ────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo " Verifying cleanup..."
echo "=============================================="

echo ""
echo "=== EC2 Instances (should be empty) ==="
aws ec2 describe-instances \
  --region "${REGION}" \
  --filters "Name=instance-state-name,Values=running,pending,stopping" \
  --query "Reservations[].Instances[].[InstanceId,InstanceType,Tags[?Key=='Name'].Value|[0]]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== RDS Instances (should be empty) ==="
aws rds describe-db-instances \
  --region "${REGION}" \
  --query "DBInstances[].[DBInstanceIdentifier,DBInstanceStatus]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== EKS Clusters (should be empty) ==="
aws eks list-clusters \
  --region "${REGION}" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== Load Balancers (should be empty) ==="
aws elbv2 describe-load-balancers \
  --region "${REGION}" \
  --query "LoadBalancers[].[LoadBalancerName,State.Code]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=== NAT Gateways (should be empty) ==="
aws ec2 describe-nat-gateways \
  --region "${REGION}" \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].[NatGatewayId,VpcId]" \
  --output table 2>/dev/null || echo "None"

echo ""
echo "=============================================="
echo " Cleanup complete!"
echo " All resources destroyed."
echo "=============================================="
