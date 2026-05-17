data "aws_caller_identity" "current" {}

# ── Karpenter Controller IRSA Role ───────────────────────────────────────────
resource "aws_iam_role" "karpenter" {
  name = "${var.project}-${var.environment}-karpenter-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(var.oidc_provider_url, "https://", "")}:aud" = "sts.amazonaws.com"
          "${replace(var.oidc_provider_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:karpenter"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_policy" "karpenter" {
  name        = "${var.project}-${var.environment}-karpenter-policy"
  description = "Karpenter controller permissions for node provisioning"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EC2 permissions for node provisioning
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:RunInstances",
          "ec2:TerminateInstances"
        ]
        Resource = "*"
      },
      {
        # IAM PassRole — scoped to node instance profile only (prevents privilege escalation)
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project}-${var.environment}-karpenter-node-role"
      },
      {
        # EKS cluster access
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:*:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
      {
        # SQS for spot interruption handling
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.interruption.arn
      },
      {
        # Pricing API for instance selection
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = "*"
      },
      {
        # SSM for AMI lookup
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:*:*:parameter/aws/service/*"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter" {
  role       = aws_iam_role.karpenter.name
  policy_arn = aws_iam_policy.karpenter.arn
}

# ── Node Instance Profile ─────────────────────────────────────────────────────
# Karpenter-launched nodes need an IAM role — same policies as managed nodes
resource "aws_iam_role" "karpenter_node" {
  name = "${var.project}-${var.environment}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  # Name must match exactly what EC2NodeClass references
  name = "${var.project}-${var.environment}-karpenter-node-profile"
  role = aws_iam_role.karpenter_node.name
  tags = var.tags
}

# ── SQS Interruption Queue ────────────────────────────────────────────────────
# Receives EC2 Spot interruption notices, rebalance recommendations, etc.
resource "aws_sqs_queue" "interruption" {
  name                      = "${var.project}-${var.environment}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

# Allow EventBridge to publish to this queue
resource "aws_sqs_queue_policy" "interruption" {
  queue_url = aws_sqs_queue.interruption.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.interruption.arn
    }]
  })
}

# ── EventBridge Rules ─────────────────────────────────────────────────────────
# Route EC2 lifecycle events to the SQS queue for graceful node termination

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.project}-${var.environment}-spot-interruption"
  description = "Karpenter: EC2 Spot interruption warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name        = "${var.project}-${var.environment}-rebalance"
  description = "Karpenter: EC2 instance rebalance recommendation"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.project}-${var.environment}-instance-state-change"
  description = "Karpenter: EC2 instance state change"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule = aws_cloudwatch_event_rule.instance_state_change.name
  arn  = aws_sqs_queue.interruption.arn
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${var.project}-${var.environment}-scheduled-change"
  description = "Karpenter: AWS health scheduled change"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule = aws_cloudwatch_event_rule.scheduled_change.name
  arn  = aws_sqs_queue.interruption.arn
}


# ── EKS Access Entry for Karpenter nodes ─────────────────────────────────────
# Karpenter-launched nodes use this IAM role.
# MUST be registered as EC2_LINUX so nodes can join the cluster.
# Without this, EC2 instances launch but never register as Kubernetes nodes.
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
  tags          = var.tags
}
