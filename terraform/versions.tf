# versions.tf — Terraform version constraints and provider requirements
#
# Provider versions pinned to minor-version ranges (~>) to allow patch
# updates while preventing unexpected breaking changes from major bumps.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  # HCP Terraform remote backend — replace the placeholder values below with
  # your HCP Terraform organization name and desired workspace name before
  # running `terraform init`.
  cloud {
    organization = "<HCP_TERRAFORM_ORG>"

    workspaces {
      name = "mcp-registry"
    }
  }
}
