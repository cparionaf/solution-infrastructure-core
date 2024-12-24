module "ecr_security" {
  source  = "terraform-aws-modules/ecr/aws"

  repository_name = "poc-python-${var.environment}"
  
  repository_read_write_access_arns = [
    module.eks.cluster_iam_role_arn,
    module.karpenter.iam_role_arn,
  ]
  
  repository_image_tag_mutability = "MUTABLE"
  repository_force_delete = var.environment == "dev" ? true : false

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 15 images",
        selection = {
          tagStatus     = "any",
          countType     = "imageCountMoreThan",
          countNumber   = 15
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

module "ecr_lead" {
  source  = "terraform-aws-modules/ecr/aws"

  repository_name = "poc-go-${var.environment}"
  
  repository_read_write_access_arns = [
    module.eks.cluster_iam_role_arn,
    module.karpenter.iam_role_arn,
  ]
  
  repository_image_tag_mutability = "MUTABLE"
  repository_force_delete = var.environment == "dev" ? true : false  

  repository_lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1,
        description  = "Keep last 15 images",
        selection = {
          tagStatus     = "any",
          countType     = "imageCountMoreThan",
          countNumber   = 15
        },
        action = {
          type = "expire"
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

