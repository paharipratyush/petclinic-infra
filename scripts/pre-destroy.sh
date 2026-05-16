#!/bin/bash
# ==========================================================
# pre-destroy.sh — Run BEFORE terraform destroy
# Cleans up resources Terraform doesn't manage:
#   - K8s ingresses (causes ALBs to be deleted by LB Controller)
#   - Leftover ALBs
#   - Leftover LB security groups
#   - ECR images
# ==========================================================
set -e

REGION="ap-south-1"
PROJECT="petclinic"
ENV="dev"
VPC_ID=$(cd terraform/environments/dev && terraform output -raw vpc_id 2>/dev/null || echo "")

echo "=============================================="
echo " Pre-Destroy Cleanup"
echo "=============================================="

# ── Step 1: Delete K8s ingresses so LB Controller removes ALBs ──
echo "[1/4] Deleting Kubernetes ingresses..."
if kubectl cluster-info &>/dev/null; then
  kubectl delete ingress --all -n petclinic-dev 2>/dev/null && echo "  ✅ petclinic-dev ingresses deleted" || true
  kubectl delete ingress --all -n monitoring 2>/dev/null && echo "  ✅ monitoring ingresses deleted" || true
  kubectl delete ingress --all -n argocd 2>/dev/null && echo "  ✅ argocd ingresses deleted" || true
  echo "  Waiting 90s for LB Controller to delete ALBs..."
  sleep 90
else
  echo "  ⚠️  kubectl not connected — skipping ingress deletion"
fi

# ── Step 2: Force delete any remaining ALBs in VPC ──
echo "[2/4] Checking for remaining ALBs..."
if [ -n "$VPC_ID" ]; then
  ALBS=$(aws elbv2 describe-load-balancers \
    --region $REGION \
    --query "LoadBalancers[?VpcId=='${VPC_ID}'].LoadBalancerArn" \
    --output text 2>/dev/null || echo "")
  if [ -n "$ALBS" ]; then
    for ARN in $ALBS; do
      echo "  Deleting ALB: $ARN"
      aws elbv2 delete-load-balancer --load-balancer-arn "$ARN" --region $REGION
    done
    echo "  Waiting 60s for ALBs to finish deleting..."
    sleep 60
  else
    echo "  ✅ No ALBs found"
  fi
fi

# ── Step 3: Delete leftover LB security groups in VPC ──
echo "[3/4] Checking for leftover LB security groups..."
if [ -n "$VPC_ID" ]; then
  SGS=$(aws ec2 describe-security-groups \
    --region $REGION \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[?starts_with(GroupName,'k8s-')].GroupId" \
    --output text 2>/dev/null || echo "")
  if [ -n "$SGS" ]; then
    for SG in $SGS; do
      echo "  Deleting SG: $SG"
      aws ec2 delete-security-group --group-id "$SG" --region $REGION 2>/dev/null || \
        echo "  ⚠️  Could not delete $SG (may still have dependencies)"
    done
  else
    echo "  ✅ No leftover LB security groups"
  fi
fi

# ── Step 4: Force delete ECR repos (clears images) ──
echo "[4/4] Clearing ECR repositories..."
for REPO in admin-server api-gateway config-server customers-service \
            discovery-server genai-service vets-service visits-service; do
  FULL_REPO="${PROJECT}-${ENV}/${REPO}"
  EXISTS=$(aws ecr describe-repositories \
    --repository-names "$FULL_REPO" \
    --region $REGION \
    --query "repositories[0].repositoryName" \
    --output text 2>/dev/null || echo "")
  if [ -n "$EXISTS" ] && [ "$EXISTS" != "None" ]; then
    aws ecr delete-repository \
      --repository-name "$FULL_REPO" \
      --force \
      --region $REGION &>/dev/null && \
      echo "  ✅ Cleared: $FULL_REPO"
  fi
done

echo ""
echo "=============================================="
echo " Pre-destroy cleanup complete!"
echo " Now remove lifecycle prevent_destroy from"
echo " terraform/modules/eks/main.tf, then run:"
echo "   terraform destroy"
echo "=============================================="
