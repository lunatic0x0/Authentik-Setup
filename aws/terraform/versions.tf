terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "authentik-idp-lab"
      Owner       = var.owner_tag
      Environment = var.environment
      ManagedBy   = "terraform"
      Purpose     = "mitre-er8-eval-prep"
    }
  }
}
