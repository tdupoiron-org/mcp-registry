variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "mcp-registry-rg"
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "West Europe"
}

variable "container_registry_name" {
  description = "Name of the Azure Container Registry (must be globally unique, alphanumeric only)"
  type        = string
  default     = "mcpregistry16287"
}

variable "container_app_name" {
  description = "Name of the Azure Container App"
  type        = string
  default     = "mcp-registry"
}

variable "container_app_environment_name" {
  description = "Name of the Azure Container Apps Environment"
  type        = string
  default     = "mcp-registry-env"
}

variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics Workspace"
  type        = string
  default     = "mcp-registry-logs"
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "allowed_ip_address" {
  description = "Public IP address allowed to access the Container App (CIDR notation, e.g. 1.2.3.4/32). Leave empty to allow all traffic."
  type        = string
  default     = ""
}

variable "db_password" {
  description = "PostgreSQL database password"
  type        = string
  sensitive   = true
}

variable "github_client_id" {
  description = "GitHub OAuth App client ID"
  type        = string
}

variable "github_client_secret" {
  description = "GitHub OAuth App client secret"
  type        = string
  sensitive   = true
}

variable "jwt_private_key" {
  description = "32-byte Ed25519 seed for JWT signing (hex-encoded). Generate with: openssl rand -hex 32"
  type        = string
  sensitive   = true
}

variable "environment" {
  description = "Deployment environment name (e.g. prod, staging)"
  type        = string
  default     = "prod"
}
