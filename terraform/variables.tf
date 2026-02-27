# variables.tf — Input variable definitions (alphabetical order)
#
# Sensitive variables (github_client_secret, jwt_private_key,
# google_oauth_client_secret) must never be stored in plain-text files.
# Supply them via:
#   - HCP Terraform workspace variables (recommended)
#   - Environment variables: TF_VAR_<name>
#   - An encrypted secrets manager piped to terraform apply

variable "environment" {
  description = "Deployment environment. Accepted values: 'staging' or 'prod'."
  type        = string

  validation {
    condition     = contains(["staging", "prod"], var.environment)
    error_message = "The 'environment' variable must be either 'staging' or 'prod'."
  }
}

variable "github_client_id" {
  description = "GitHub OAuth App Client ID used for mcp-registry user authentication."
  type        = string
}

variable "github_client_secret" {
  description = <<-EOT
    GitHub OAuth App Client Secret.
    Stored in the 'mcp-registry-secrets' Kubernetes Secret.
    Mark as sensitive in HCP Terraform; never commit to source control.
  EOT
  type        = string
  sensitive   = true
}

variable "google_oauth_client_secret" {
  description = <<-EOT
    Google OAuth 2.0 client secret for Grafana SSO authentication.
    Stored in the 'grafana-secrets' Kubernetes Secret.
    Mark as sensitive in HCP Terraform; never commit to source control.
  EOT
  type        = string
  sensitive   = true
}

variable "image_tag" {
  description = <<-EOT
    Docker image tag for ghcr.io/modelcontextprotocol/registry.
    Defaults to 'main' (latest staging build).
    For production deployments, pin to an explicit release tag (e.g. '1.4.1')
    to ensure deterministic rollouts and prevent accidental promotion.
  EOT
  type        = string
  default     = "main"
}

variable "jwt_private_key" {
  description = <<-EOT
    RSA private key (PEM format) used to sign JWT tokens in the mcp-registry app.
    Stored in the 'mcp-registry-secrets' Kubernetes Secret.
    Mark as sensitive in HCP Terraform; never commit to source control.
  EOT
  type        = string
  sensitive   = true
}

variable "project_id" {
  description = "GCP project ID in which all infrastructure resources are created."
  type        = string
}

variable "region" {
  description = "GCP region for the GKE cluster. The cluster zone is derived as '<region>-b'."
  type        = string
  default     = "us-central1"
}
