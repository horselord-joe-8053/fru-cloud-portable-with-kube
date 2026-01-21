provider "aws" {
  region = var.region
}

data "aws_iam_policy" "ebs_csi_driver" {
  name = "AmazonEBSCSIDriverPolicy"
}

data "aws_availability_zones" "available" {}

locals {
  tags = {
    ProjectId   = var.project_id
    Project     = var.cluster_name
    ManagedBy   = "terraform"
    Repo        = "eks-terraform-portable-ingress-fridge"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.5.3"

  name = "${var.cluster_name}-${var.project_id}-vpc"
  cidr = "10.0.0.0/16"

  azs              = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets   = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = merge(local.tags, {
    "kubernetes.io/role/elb" = "1"
  })

  private_subnet_tags = merge(local.tags, {
    "kubernetes.io/role/internal-elb" = "1"
  })

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.24.0"

  cluster_name    = "${var.cluster_name}-${var.project_id}"
  cluster_version = "1.30"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # Use a fixed IAM role name to avoid AWS 38-character limit for name_prefix
  # IAM role names can be up to 64 characters when not using prefix
  iam_role_use_name_prefix = false
  iam_role_name            = "${var.cluster_name}-${var.project_id}-cluster"

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min
      max_size       = var.node_max
      desired_size   = var.node_desired

      # Use a fixed IAM role name to avoid AWS 38-character limit for name_prefix
      # IAM role names can be up to 64 characters when not using prefix
      iam_role_use_name_prefix = false
      iam_role_name            = "${var.cluster_name}-${var.project_id}-node"

      tags = local.tags
    }
  }

  enable_cluster_creator_admin_permissions = true

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node_ebs_csi" {
  role       = "${var.cluster_name}-${var.project_id}-node"
  policy_arn = data.aws_iam_policy.ebs_csi_driver.arn
}

output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "region"           { value = var.region }
output "project_id"       { value = var.project_id }
