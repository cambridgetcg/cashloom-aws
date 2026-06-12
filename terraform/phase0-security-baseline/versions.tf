terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "cashloom"
      Component = "security-baseline"
      ManagedBy = "terraform"
      Phase     = "0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
