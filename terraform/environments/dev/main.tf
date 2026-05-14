# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  project             = var.project
  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  availability_zones  = var.availability_zones
}

# ── EKS ───────────────────────────────────────────────────────────────────────
module "eks" {
  source = "../../modules/eks"

  project             = var.project
  environment         = var.environment
  aws_region          = var.aws_region
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.public_subnet_ids
  cluster_sg_id       = module.vpc.eks_cluster_sg_id
  node_sg_id          = module.vpc.eks_node_sg_id
  cluster_version     = var.eks_cluster_version
  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
}


# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  project              = var.project
  environment          = var.environment
  image_tag_mutability = "MUTABLE"
}
