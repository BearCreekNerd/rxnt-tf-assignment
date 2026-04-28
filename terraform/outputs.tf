output "resource_group_name" {
  description = "Resource group name."
  value       = azurerm_resource_group.main.name
}

output "site_url" {
  description = "App Service URL for the site."
  value       = "https://${azurerm_linux_web_app.site.default_hostname}"
}

output "api_url" {
  description = "App Service URL for the API."
  value       = "https://${azurerm_linux_web_app.api.default_hostname}"
}

output "key_vault_name" {
  description = "Key Vault name used for application secret references."
  value       = azurerm_key_vault.main.name
}

output "container_registry_login_server" {
  description = "Container registry login server."
  value       = data.azurerm_container_registry.main.login_server
}

output "api_web_app_name" {
  description = "API Web App name, used when creating an Azure SQL Entra user for managed identity."
  value       = azurerm_linux_web_app.api.name
}

output "site_web_app_name" {
  description = "Site Web App name."
  value       = azurerm_linux_web_app.site.name
}