# ── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-vpc"
  })
}

# ── Public Subnets ────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                                                        = "${var.project}-${var.environment}-public-${count.index + 1}"
    "kubernetes.io/cluster/${var.project}-${var.environment}"   = "shared"
    "kubernetes.io/role/elb"                                    = "1"
    "karpenter.sh/discovery"                                    = "${var.project}-${var.environment}"
  })
}

# ── Internet Gateway ──────────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-igw"
  })
}

# ── Route Table ───────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Security Group: EKS Cluster (control plane) ───────────────────────────────
resource "aws_security_group" "eks_cluster" {
  name        = "${var.project}-${var.environment}-eks-cluster-sg"
  description = "EKS cluster control plane security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-eks-cluster-sg"
  })
}

resource "aws_security_group_rule" "cluster_ingress_nodes_443" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_node.id
  description              = "Allow nodes to reach API server"
}

resource "aws_security_group_rule" "cluster_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_cluster.id
  description       = "Allow all outbound"
}

# ── Security Group: EKS Nodes ─────────────────────────────────────────────────
resource "aws_security_group" "eks_node" {
  name        = "${var.project}-${var.environment}-eks-node-sg"
  description = "EKS worker node security group"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name                                                      = "${var.project}-${var.environment}-eks-node-sg"
    "kubernetes.io/cluster/${var.project}-${var.environment}" = "owned"
    "karpenter.sh/discovery"                                  = "${var.project}-${var.environment}"
  })
}

resource "aws_security_group_rule" "node_ingress_cluster" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.eks_cluster.id
  description              = "Allow all traffic from cluster control plane"
}

resource "aws_security_group_rule" "node_ingress_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.eks_node.id
  self              = true
  description       = "Allow inter-node communication"
}

resource "aws_security_group_rule" "node_ingress_alb_nodeport" {
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node.id
  source_security_group_id = aws_security_group.alb.id
  description              = "Allow ALB to reach NodePort services"
}

resource "aws_security_group_rule" "node_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.eks_node.id
  description       = "Allow all outbound"
}

# ── Security Group: RDS ───────────────────────────────────────────────────────
resource "aws_security_group" "rds" {
  name        = "${var.project}-${var.environment}-rds-sg"
  description = "RDS MySQL security group - only accessible from EKS nodes"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-rds-sg"
  })
}

resource "aws_security_group_rule" "rds_ingress_nodes" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.eks_node.id
  description              = "MySQL from EKS nodes only"
}

# ── Security Group: ALB ───────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.project}-${var.environment}-alb-sg"
  description = "ALB security group - HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.project}-${var.environment}-alb-sg"
  })
}

resource "aws_security_group_rule" "alb_ingress_http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from internet"
}

resource "aws_security_group_rule" "alb_ingress_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from internet"
}

resource "aws_security_group_rule" "alb_egress_nodes" {
  type                     = "egress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.eks_node.id
  description              = "Outbound to EKS nodes only"
}

resource "aws_security_group_rule" "alb_egress_pods" {
  type              = "egress"
  from_port         = 3000
  to_port           = 9090
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  cidr_blocks       = [var.vpc_cidr]
  description       = "Allow ALB to reach pods directly (target-type: ip)"
}
