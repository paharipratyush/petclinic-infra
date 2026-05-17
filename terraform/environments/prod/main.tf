locals {
  tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── VPC ───────────────────────────────────────────────────────────────────────
module "vpc" {
  source = "../../modules/vpc"

  project             = var.project
  environment         = var.environment
  vpc_cidr            = var.vpc_cidr
  public_subnet_cidrs = var.public_subnet_cidrs
  availability_zones  = var.availability_zones
  tags                = local.tags
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
  rds_sg_id           = module.vpc.rds_sg_id
  alb_sg_id           = module.vpc.alb_sg_id
  iam_admin_username  = var.iam_admin_username
  tags                = local.tags
}

# ── ECR ───────────────────────────────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  project              = var.project
  environment          = var.environment
  image_tag_mutability = "IMMUTABLE"
  tags                 = local.tags
}

# ── RDS ───────────────────────────────────────────────────────────────────────
module "rds" {
  source = "../../modules/rds"

  project                 = var.project
  environment             = var.environment
  subnet_ids              = module.vpc.public_subnet_ids
  rds_sg_id               = module.vpc.rds_sg_id
  instance_class          = var.rds_instance_class
  multi_az                = false
  backup_retention_period = 7
  skip_final_snapshot     = true
  deletion_protection     = false
  tags                    = local.tags
}

# ── Secrets (non-RDS) ─────────────────────────────────────────────────────────
module "secrets" {
  source = "../../modules/secrets"

  project           = var.project
  environment       = var.environment
  openai_api_key    = var.openai_api_key
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.tags
}

# ── DNS + ACM (Cloudflare) ────────────────────────────────────────────────────
module "dns" {
  source = "../../modules/dns"

  project                 = var.project
  environment             = var.environment
  domain_name             = var.domain_name
  cloudflare_zone_id      = var.cloudflare_zone_id
  alb_dns_name            = var.alb_dns_name
  monitoring_alb_dns_name = var.monitoring_alb_dns_name
  tags                    = local.tags
}

# ── GitHub OIDC ───────────────────────────────────────────────────────────────
module "github_oidc" {
  source      = "../../modules/github-oidc"
  project     = var.project
  environment = var.environment
  aws_region  = var.aws_region
  github_org  = var.github_org
  app_repo    = var.app_repo
  create_oidc_provider = false
}

# ── Karpenter (Node Autoscaling) ──────────────────────────────────────────────
module "karpenter" {
  source = "../../modules/karpenter"

  project           = var.project
  environment       = var.environment
  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  node_role_arn     = module.eks.node_role_arn
  tags              = local.tags
}
