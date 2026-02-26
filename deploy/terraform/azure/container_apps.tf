locals {
  db_name     = "mcp-registry"
  db_user     = "mcpregistry"
  db_host     = "postgres"
  db_port     = 5432
  database_url = "postgres://${local.db_user}:${var.db_password}@${local.db_host}:${local.db_port}/${local.db_name}"

  # Build the IP security restriction list. When allowed_ip_address is set,
  # restrict inbound traffic to that CIDR; otherwise allow all traffic.
  ip_security_restrictions = var.allowed_ip_address != "" ? [
    {
      action           = "Allow"
      ip_address_range = var.allowed_ip_address
      name             = "AllowMyIP"
      description      = "Allow access from the configured public IP"
    }
  ] : []
}

resource "azurerm_container_app_environment" "main" {
  name                       = var.container_app_environment_name
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id
}

resource "azurerm_container_app" "main" {
  name                         = var.container_app_name
  container_app_environment_id = azurerm_container_app_environment.main.id
  resource_group_name          = azurerm_resource_group.main.name
  revision_mode                = "Single"

  registry {
    server               = azurerm_container_registry.main.login_server
    username             = azurerm_container_registry.main.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.main.admin_password
  }

  secret {
    name  = "github-client-secret"
    value = var.github_client_secret
  }

  secret {
    name  = "jwt-private-key"
    value = var.jwt_private_key
  }

  secret {
    name  = "database-url"
    value = local.database_url
  }

  template {
    container {
      name   = var.container_app_name
      image  = "${azurerm_container_registry.main.login_server}/${var.container_app_name}:${var.image_tag}"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name        = "MCP_REGISTRY_DATABASE_URL"
        secret_name = "database-url"
      }

      env {
        name  = "MCP_REGISTRY_ENVIRONMENT"
        value = var.environment
      }

      env {
        name  = "MCP_REGISTRY_GITHUB_CLIENT_ID"
        value = var.github_client_id
      }

      env {
        name        = "MCP_REGISTRY_GITHUB_CLIENT_SECRET"
        secret_name = "github-client-secret"
      }

      env {
        name        = "MCP_REGISTRY_JWT_PRIVATE_KEY"
        secret_name = "jwt-private-key"
      }

      env {
        name  = "MCP_REGISTRY_ENABLE_ANONYMOUS_AUTH"
        value = "false"
      }
    }

    min_replicas = 1
    max_replicas = 3
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "http"

    traffic_weight {
      percentage      = 100
      latest_revision = true
    }

    dynamic "ip_security_restriction" {
      for_each = local.ip_security_restrictions
      content {
        action           = ip_security_restriction.value.action
        ip_address_range = ip_security_restriction.value.ip_address_range
        name             = ip_security_restriction.value.name
        description      = ip_security_restriction.value.description
      }
    }
  }
}
