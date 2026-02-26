# MCP Registry – Azure Terraform Deployment

This directory contains a Terraform project that provisions the Azure infrastructure used to run the MCP Registry API, mirroring the setup from [`.github/workflows/deploy-azure.yml`](../../.github/workflows/deploy-azure.yml).

## Resources Created

| Resource | Name (default) | Description |
|---|---|---|
| Resource Group | `mcp-registry-rg` | Container for all Azure resources |
| Log Analytics Workspace | `mcp-registry-logs` | Logs backend for Container Apps |
| Azure Container Registry | `mcpregistry16287` | Private Docker registry |
| Container App Environment | `mcp-registry-env` | Managed environment for Container Apps |
| Container App | `mcp-registry` | The MCP Registry API container |

All resources are deployed to **West Europe** by default.

## Prerequisites

- [Terraform ≥ 1.5](https://developer.hashicorp.com/terraform/install)
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) logged in (`az login`)
- A Docker image already pushed to the ACR (done by the GitHub Actions workflow, or manually with `docker push`)

## Quick Start

### 1. Authenticate with Azure

```bash
az login
```

### 2. Create a `terraform.tfvars` file

```hcl
# Required secrets – never commit these to source control
db_password          = "change-me-strong-password"
github_client_id     = "Iv23licy3GSiM9Km5jtd"
github_client_secret = "<your-github-oauth-secret>"
jwt_private_key      = "<32-byte hex seed – openssl rand -hex 32>"

# Optional: restrict access to your public IP only
allowed_ip_address = "203.0.113.42/32"
```

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

After `apply` completes, the public endpoint is printed as `container_app_url`.

### 4. Push an image and trigger a new revision

The GitHub Actions workflow ([`deploy-azure.yml`](../../.github/workflows/deploy-azure.yml)) builds and pushes images automatically on every push to `main`. To deploy manually:

```bash
# Log in to the registry
az acr login --name mcpregistry16287

# Build and push
docker build -t mcpregistry16287.azurecr.io/mcp-registry:latest .
docker push mcpregistry16287.azurecr.io/mcp-registry:latest

# Update the running revision (re-apply Terraform with a new image_tag, or use the CLI)
az containerapp update \
  --name mcp-registry \
  --resource-group mcp-registry-rg \
  --image mcpregistry16287.azurecr.io/mcp-registry:latest
```

### 5. Destroy

```bash
terraform destroy
```

This is equivalent to the `az group delete --name mcp-registry-rg --yes` command used to stop incurring costs.

## Variables

| Variable | Description | Default | Required |
|---|---|---|---|
| `resource_group_name` | Azure resource group name | `mcp-registry-rg` | No |
| `location` | Azure region | `West Europe` | No |
| `container_registry_name` | ACR name (globally unique, alphanumeric) | `mcpregistry16287` | No |
| `container_app_name` | Container App name | `mcp-registry` | No |
| `container_app_environment_name` | Container Apps Environment name | `mcp-registry-env` | No |
| `log_analytics_workspace_name` | Log Analytics Workspace name | `mcp-registry-logs` | No |
| `image_tag` | Docker image tag to deploy | `latest` | No |
| `allowed_ip_address` | CIDR to restrict inbound traffic (e.g. `1.2.3.4/32`). Empty = allow all. | `""` | No |
| `db_password` | PostgreSQL password | — | **Yes** |
| `github_client_id` | GitHub OAuth App client ID | — | **Yes** |
| `github_client_secret` | GitHub OAuth App client secret | — | **Yes** |
| `jwt_private_key` | 32-byte hex Ed25519 seed for JWT signing | — | **Yes** |
| `environment` | Deployment environment label | `prod` | No |

## Outputs

| Output | Description |
|---|---|
| `resource_group_name` | Name of the resource group |
| `container_registry_login_server` | ACR login server (set as `ACR_REGISTRY` in the workflow) |
| `container_app_fqdn` | Raw FQDN of the Container App |
| `container_app_url` | Full HTTPS URL of the MCP Registry API |

## Storing Terraform State

By default Terraform stores state locally. For team or CI use, configure a [remote backend](https://developer.hashicorp.com/terraform/language/backend). A common choice is Azure Blob Storage:

```hcl
# backend.tf  (create this file alongside the others)
terraform {
  backend "azurerm" {
    resource_group_name  = "tfstate-rg"
    storage_account_name = "tfstatemcpregistry"
    container_name       = "tfstate"
    key                  = "mcp-registry.tfstate"
  }
}
```

## CI/CD Integration

The [GitHub Actions workflow](../../.github/workflows/deploy-azure.yml) builds and pushes images to the ACR on every push to `main`. The workflow uses the following secrets that correspond to Terraform outputs / resources:

| Secret | Source |
|---|---|
| `AZURE_CREDENTIALS` | Service principal JSON (`az ad sp create-for-rbac`) |
| `ACR_USERNAME` | `container_registry_admin_username` output |
| `ACR_PASSWORD` | ACR admin password (sensitive) |
