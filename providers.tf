terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

# Las credenciales salen de ~/.aws/credentials (las del Learner Lab, con session
# token). Terraform las lee igual que la AWS CLI, no hay que pasarlas por acá.
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Proyecto   = "prisma"
      Gestionado = "terraform"
    }
  }
}
