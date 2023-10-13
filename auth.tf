# Require Terraform 0.12 or greater
terraform {
  required_version = ">= 0.12"
}

# Set AWS provider region
provider "aws" {
  region = var.aws_region
}