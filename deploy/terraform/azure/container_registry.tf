resource "azurerm_container_registry" "main" {
  name                = var.container_registry_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Basic"
  # admin_enabled is required for Container Apps with Basic SKU ACR.
  # For production use with Standard/Premium SKU, prefer a managed identity
  # assigned the AcrPull role on the registry instead.
  admin_enabled = true
}
