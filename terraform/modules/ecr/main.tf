resource "aws_ecr_repository" "services" {
  for_each = toset(var.service_names)

  name                 = "${var.project}-${var.environment}/${each.key}"
  image_tag_mutability = var.image_tag_mutability
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(var.tags, {
    Name    = "${var.project}-${var.environment}/${each.key}"
    Service = each.key
  })
}

resource "aws_ecr_lifecycle_policy" "services" {
  # Use var.service_names (known at plan time) instead of aws_ecr_repository.services
  # (unknown until apply) to avoid "for_each unknown at plan time" error
  for_each = toset(var.service_names)

  repository = aws_ecr_repository.services[each.key].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 10 images, expire untagged after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
