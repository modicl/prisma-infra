# Todo lo que cambia de una cuenta a otra se resuelve acá, en tiempo de plan.
# Nada de este archivo se hardcodea en los demás .tf.

data "aws_caller_identity" "actual" {}

data "aws_region" "actual" {}

# El Learner Lab no permite crear roles IAM: todo lo que necesite un rol
# (ECS execution/task, Lambda) usa LabRole.
data "aws_iam_role" "lab" {
  name = "LabRole"
}

# La VPC por defecto del lab. Sus IDs son distintos en cada cuenta.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  account_id = data.aws_caller_identity.actual.account_id
  region     = data.aws_region.actual.region
  ecr_base   = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"
}

locals {
  subnet_ids = var.subnet_ids != null ? var.subnet_ids : slice(sort(data.aws_subnets.default.ids), 0, 2)

  # Cognito y CORS se derivan de la misma lista para que nunca se desincronicen.
  callback_urls = [for u in var.front_urls : "${u}/auth/callback"]
  logout_urls   = [for u in var.front_urls : "${u}/login"]
  cors_origins  = [for u in var.front_urls : u if !startswith(u, "http://localhost")]
}
