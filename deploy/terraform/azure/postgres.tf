resource "azurerm_postgresql_flexible_server" "main" {
  name                   = "mcp-registry-pg"
  resource_group_name    = azurerm_resource_group.main.name
  location               = azurerm_resource_group.main.location
  version                = "16"
  administrator_login    = local.db_user
  administrator_password = var.db_password
  storage_mb             = 32768
  sku_name               = "B_Standard_B1ms"
  backup_retention_days  = 7

  authentication {
    active_directory_auth_enabled = false
    password_auth_enabled         = true
  }

  lifecycle {
    ignore_changes = [zone, high_availability]
  }
}

resource "azurerm_postgresql_flexible_server_database" "main" {
  name      = local.db_name
  server_id = azurerm_postgresql_flexible_server.main.id
  collation = "en_US.utf8"
  charset   = "UTF8"
}

resource "azurerm_postgresql_flexible_server_configuration" "extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.main.id
  value     = "uuid-ossp,pg_trgm"
}

# Allow all Azure services (0.0.0.0 is the Azure-internal magic rule)
resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAllAzureServices"
  server_id        = azurerm_postgresql_flexible_server.main.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Seed the database with the GitHub MCP server once the registry is healthy.
# The health check ensures the app has run its migrations before we insert data.
# az postgres flexible-server execute runs through the Azure control plane —
# no local network access to the database is required.
resource "null_resource" "seed_github_mcp_server" {
  depends_on = [
    azurerm_container_app.main,
  ]

  # Re-run the seed whenever seed.sql changes.
  triggers = {
    seed_sql_hash = filemd5("${path.module}/seed.sql")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      FQDN="${azurerm_container_app.main.latest_revision_fqdn}"
      MAX_RETRIES=30
      RETRIES=0
      echo "Waiting for registry to be healthy at https://$FQDN/v0/health ..."
      until curl -sf --max-time 5 "https://$FQDN/v0/health" > /dev/null 2>&1; do
        RETRIES=$((RETRIES + 1))
        if [ $RETRIES -ge $MAX_RETRIES ]; then
          echo "ERROR: health check timed out after $((MAX_RETRIES * 10))s"
          exit 1
        fi
        echo "  still waiting... ($RETRIES/$MAX_RETRIES)"
        sleep 10
      done
      echo "Registry is healthy. Seeding GitHub MCP server..."
      az postgres flexible-server execute \
        --name "${azurerm_postgresql_flexible_server.main.name}" \
        --resource-group "${azurerm_resource_group.main.name}" \
        --database-name "${azurerm_postgresql_flexible_server_database.main.name}" \
        --admin-user "${local.db_user}" \
        --admin-password "${var.db_password}" \
        --file-path "${path.module}/seed.sql"
      echo "Seed complete."
    EOT
  }
}
