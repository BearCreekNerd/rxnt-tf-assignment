locals {
  suffix          = random_string.suffix.result
  base_name       = lower(replace("${var.project_name}-${var.environment}", "_", "-"))
  resource_prefix = substr(local.base_name, 0, 18)

  tags = {
    project     = var.project_name
    environment = var.environment
    managedBy   = "terraform"
  }

  db_connection_string_sql = "Server=tcp:${azurerm_mssql_server.main.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.main.name};Persist Security Info=False;User ID=${var.sql_admin_username};Password=${var.sql_admin_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  db_connection_string     = local.db_connection_string_sql
  redis_connection_string  = "${azurerm_redis_cache.main.hostname}:${azurerm_redis_cache.main.ssl_port},password=${azurerm_redis_cache.main.primary_access_key},ssl=True,abortConnect=False"
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.resource_prefix}-${local.suffix}"
  location = var.location
  tags     = local.tags
}

# Networking resources for private SQL connectivity
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.resource_prefix}-${local.suffix}"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "app" {
  name                              = "snet-app-${local.resource_prefix}-${local.suffix}"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.app_subnet_prefix]
  private_endpoint_network_policies = "Enabled"

  delegation {
    name = "webapp"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "sql_endpoint" {
  name                              = "snet-sql-${local.resource_prefix}-${local.suffix}"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.sql_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet" "redis_endpoint" {
  name                              = "snet-redis-${local.resource_prefix}-${local.suffix}"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.redis_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Enabled"
}

# Network Security Groups
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  # Allow outbound SQL traffic to the SQL private endpoint.
  security_rule {
    name                       = "AllowOutboundSql"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = var.app_subnet_prefix
    destination_address_prefix = var.sql_endpoint_subnet_prefix
    description                = "Allow SQL traffic to the SQL private endpoint subnet"
  }

  # Allow outbound to other Azure services
  security_rule {
    name                       = "AllowOutboundAzureServices"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.app_subnet_prefix
    destination_address_prefix = "AzureCloud"
    description                = "Allow outbound to Azure services"
  }

  # Allow outbound Redis traffic to the Redis private endpoint.
  security_rule {
    name                       = "AllowOutboundRedis"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6380"
    source_address_prefix      = var.app_subnet_prefix
    destination_address_prefix = var.redis_endpoint_subnet_prefix
    description                = "Allow Redis TLS traffic to the Redis private endpoint subnet"
  }

  # Deny all other outbound
  security_rule {
    name                       = "DenyAllOutbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# NSG associations
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

data "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

resource "azurerm_service_plan" "main" {
  name                = "plan-${local.resource_prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.site_sku_name
  tags                = local.tags
}

resource "azurerm_mssql_server" "main" {
  name                          = "sql-${local.resource_prefix}-${local.suffix}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "12.0"
  administrator_login           = var.sql_admin_username
  administrator_login_password  = var.sql_admin_password
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_mssql_database" "main" {
  name           = "marketing"
  server_id      = azurerm_mssql_server.main.id
  sku_name       = "Basic"
  max_size_gb    = 2
  zone_redundant = false
  tags           = local.tags
}

# Private DNS Zone for SQL
resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql" {
  name                  = "vnet-link-${local.resource_prefix}-${local.suffix}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = local.tags
}

# SQL Private Endpoint
resource "azurerm_private_endpoint" "sql" {
  name                = "pep-sql-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.sql_endpoint.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-sql-${local.resource_prefix}-${local.suffix}"
    private_connection_resource_id = azurerm_mssql_server.main.id
    is_manual_connection           = false
    subresource_names              = ["sqlServer"]
  }

  private_dns_zone_group {
    name                 = "pdzg-sql-${local.resource_prefix}-${local.suffix}"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
}

# Private DNS Zone for Redis
resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "vnet-link-redis-${local.resource_prefix}-${local.suffix}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = local.tags
}

resource "azurerm_redis_cache" "main" {
  name                = "redis-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  capacity            = var.redis_capacity
  family              = var.redis_family
  sku_name            = var.redis_sku_name
  minimum_tls_version = "1.2"
  tags                = local.tags
}

# Redis Private Endpoint
resource "azurerm_private_endpoint" "redis" {
  name                = "pep-redis-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.redis_endpoint.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-redis-${local.resource_prefix}-${local.suffix}"
    private_connection_resource_id = azurerm_redis_cache.main.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }

  private_dns_zone_group {
    name                 = "pdzg-redis-${local.resource_prefix}-${local.suffix}"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.main.id
  tags                = local.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_key_vault" "main" {
  name                          = "kv-${local.resource_prefix}-${local.suffix}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_role_assignment" "terraform_keyvault_admin" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db_connection_string" {
  name         = "db-connection-string"
  value        = local.db_connection_string
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.terraform_keyvault_admin]
}

resource "azurerm_key_vault_secret" "redis_connection_string" {
  name         = "redis-connection-string"
  value        = local.redis_connection_string
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.terraform_keyvault_admin]
}

resource "azurerm_linux_web_app" "api" {
  name                = "api-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true
  tags                = local.tags

  virtual_network_subnet_id = azurerm_subnet.app.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2
    vnet_route_all_enabled            = true
    ip_restriction_default_action     = "Allow"

    application_stack {
      docker_image_name   = var.api_image_name
      docker_registry_url = "https://${data.azurerm_container_registry.main.login_server}"
    }

    container_registry_use_managed_identity = true
  }

  app_settings = {
    ASPNETCORE_ENVIRONMENT                = "Production"
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main.connection_string
    DB_CONNECTION_STRING                  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.db_connection_string.versionless_id})"
    WEBSITES_PORT                         = "8080"
  }

  depends_on = [azurerm_private_endpoint.sql, azurerm_private_endpoint.redis]
}

resource "azurerm_linux_web_app" "site" {
  name                = "site-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true
  tags                = local.tags

  virtual_network_subnet_id = azurerm_subnet.app.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2
    vnet_route_all_enabled            = true
    ip_restriction_default_action     = "Allow"

    application_stack {
      docker_image_name   = var.site_image_name
      docker_registry_url = "https://${data.azurerm_container_registry.main.login_server}"
    }

    container_registry_use_managed_identity = true
  }

  app_settings = {
    ASPNETCORE_ENVIRONMENT                = "Production"
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main.connection_string
    MarketingApi__BaseUrl                 = "https://${azurerm_linux_web_app.api.default_hostname}"
    REDIS_CONNECTION_STRING               = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.redis_connection_string.versionless_id})"
    WEBSITES_PORT                         = "8080"
  }
}

resource "azurerm_role_assignment" "api_acr_pull" {
  scope                = data.azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.api.identity[0].principal_id
}

resource "azurerm_role_assignment" "site_acr_pull" {
  scope                = data.azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.site.identity[0].principal_id
}

resource "azurerm_role_assignment" "api_keyvault_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.api.identity[0].principal_id
}

resource "azurerm_role_assignment" "site_keyvault_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.site.identity[0].principal_id
}

resource "azurerm_monitor_autoscale_setting" "plan" {
  name                = "autoscale-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  target_resource_id  = azurerm_service_plan.main.id
  enabled             = true

  profile {
    name = "default"

    capacity {
      default = 2
      minimum = 2
      maximum = 6
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }

  tags = local.tags
}
[perryg@BCS-LENOVO-001 terraform]$ cat main.tf
locals {
  suffix          = random_string.suffix.result
  base_name       = lower(replace("${var.project_name}-${var.environment}", "_", "-"))
  resource_prefix = substr(local.base_name, 0, 18)

  tags = {
    project     = var.project_name
    environment = var.environment
    managedBy   = "terraform"
  }

  db_connection_string_sql = "Server=tcp:${azurerm_mssql_server.main.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.main.name};Persist Security Info=False;User ID=${var.sql_admin_username};Password=${var.sql_admin_password};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
  db_connection_string     = local.db_connection_string_sql
  redis_connection_string  = "${azurerm_redis_cache.main.hostname}:${azurerm_redis_cache.main.ssl_port},password=${azurerm_redis_cache.main.primary_access_key},ssl=True,abortConnect=False"
}

data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.resource_prefix}-${local.suffix}"
  location = var.location
  tags     = local.tags
}

# Networking resources for private SQL connectivity
resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.resource_prefix}-${local.suffix}"
  address_space       = [var.vnet_address_space]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "app" {
  name                              = "snet-app-${local.resource_prefix}-${local.suffix}"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.app_subnet_prefix]
  private_endpoint_network_policies = "Enabled"

  delegation {
    name = "webapp"
    service_delegation {
      name    = "Microsoft.Web/serverFarms"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

resource "azurerm_subnet" "sql_endpoint" {
  name                              = "snet-sql-${local.resource_prefix}-${local.suffix}"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.sql_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Enabled"
}

resource "azurerm_subnet" "redis_endpoint" {
  name                              = "snet-redis-${local.resource_prefix}-${local.suffix}"
  resource_group_name               = azurerm_resource_group.main.name
  virtual_network_name              = azurerm_virtual_network.main.name
  address_prefixes                  = [var.redis_endpoint_subnet_prefix]
  private_endpoint_network_policies = "Enabled"
}

# Network Security Groups
resource "azurerm_network_security_group" "app" {
  name                = "nsg-app-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  # Allow outbound SQL traffic to the SQL private endpoint.
  security_rule {
    name                       = "AllowOutboundSql"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = var.app_subnet_prefix
    destination_address_prefix = var.sql_endpoint_subnet_prefix
    description                = "Allow SQL traffic to the SQL private endpoint subnet"
  }

  # Allow outbound to other Azure services
  security_rule {
    name                       = "AllowOutboundAzureServices"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = var.app_subnet_prefix
    destination_address_prefix = "AzureCloud"
    description                = "Allow outbound to Azure services"
  }

  # Allow outbound Redis traffic to the Redis private endpoint.
  security_rule {
    name                       = "AllowOutboundRedis"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6380"
    source_address_prefix      = var.app_subnet_prefix
    destination_address_prefix = var.redis_endpoint_subnet_prefix
    description                = "Allow Redis TLS traffic to the Redis private endpoint subnet"
  }

  # Deny all other outbound
  security_rule {
    name                       = "DenyAllOutbound"
    priority                   = 4096
    direction                  = "Outbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# NSG associations
resource "azurerm_subnet_network_security_group_association" "app" {
  subnet_id                 = azurerm_subnet.app.id
  network_security_group_id = azurerm_network_security_group.app.id
}

data "azurerm_container_registry" "main" {
  name                = var.acr_name
  resource_group_name = var.acr_resource_group_name
}

resource "azurerm_service_plan" "main" {
  name                = "plan-${local.resource_prefix}-${local.suffix}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  os_type             = "Linux"
  sku_name            = var.site_sku_name
  tags                = local.tags
}

resource "azurerm_mssql_server" "main" {
  name                          = "sql-${local.resource_prefix}-${local.suffix}"
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  version                       = "12.0"
  administrator_login           = var.sql_admin_username
  administrator_login_password  = var.sql_admin_password
  minimum_tls_version           = "1.2"
  public_network_access_enabled = false
  tags                          = local.tags
}

resource "azurerm_mssql_database" "main" {
  name           = "marketing"
  server_id      = azurerm_mssql_server.main.id
  sku_name       = "Basic"
  max_size_gb    = 2
  zone_redundant = false
  tags           = local.tags
}

# Private DNS Zone for SQL
resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql" {
  name                  = "vnet-link-${local.resource_prefix}-${local.suffix}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = local.tags
}

# SQL Private Endpoint
resource "azurerm_private_endpoint" "sql" {
  name                = "pep-sql-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.sql_endpoint.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-sql-${local.resource_prefix}-${local.suffix}"
    private_connection_resource_id = azurerm_mssql_server.main.id
    is_manual_connection           = false
    subresource_names              = ["sqlServer"]
  }

  private_dns_zone_group {
    name                 = "pdzg-sql-${local.resource_prefix}-${local.suffix}"
    private_dns_zone_ids = [azurerm_private_dns_zone.sql.id]
  }
}

# Private DNS Zone for Redis
resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "vnet-link-redis-${local.resource_prefix}-${local.suffix}"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  virtual_network_id    = azurerm_virtual_network.main.id
  tags                  = local.tags
}

resource "azurerm_redis_cache" "main" {
  name                = "redis-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  capacity            = var.redis_capacity
  family              = var.redis_family
  sku_name            = var.redis_sku_name
  minimum_tls_version = "1.2"
  tags                = local.tags
}

# Redis Private Endpoint
resource "azurerm_private_endpoint" "redis" {
  name                = "pep-redis-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.redis_endpoint.id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-redis-${local.resource_prefix}-${local.suffix}"
    private_connection_resource_id = azurerm_redis_cache.main.id
    is_manual_connection           = false
    subresource_names              = ["redisCache"]
  }

  private_dns_zone_group {
    name                 = "pdzg-redis-${local.resource_prefix}-${local.suffix}"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.main.id
  tags                = local.tags
}

resource "azurerm_log_analytics_workspace" "main" {
  name                = "log-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

resource "azurerm_key_vault" "main" {
  name                          = "kv-${local.resource_prefix}-${local.suffix}"
  location                      = azurerm_resource_group.main.location
  resource_group_name           = azurerm_resource_group.main.name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  public_network_access_enabled = true
  tags                          = local.tags
}

resource "azurerm_role_assignment" "terraform_keyvault_admin" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_secret" "db_connection_string" {
  name         = "db-connection-string"
  value        = local.db_connection_string
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.terraform_keyvault_admin]
}

resource "azurerm_key_vault_secret" "redis_connection_string" {
  name         = "redis-connection-string"
  value        = local.redis_connection_string
  key_vault_id = azurerm_key_vault.main.id

  depends_on = [azurerm_role_assignment.terraform_keyvault_admin]
}

resource "azurerm_linux_web_app" "api" {
  name                = "api-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true
  tags                = local.tags

  virtual_network_subnet_id = azurerm_subnet.app.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2
    vnet_route_all_enabled            = true
    ip_restriction_default_action     = "Allow"

    application_stack {
      docker_image_name   = var.api_image_name
      docker_registry_url = "https://${data.azurerm_container_registry.main.login_server}"
    }

    container_registry_use_managed_identity = true
  }

  app_settings = {
    ASPNETCORE_ENVIRONMENT                = "Production"
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main.connection_string
    DB_CONNECTION_STRING                  = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.db_connection_string.versionless_id})"
    WEBSITES_PORT                         = "8080"
  }

  depends_on = [azurerm_private_endpoint.sql, azurerm_private_endpoint.redis]
}

resource "azurerm_linux_web_app" "site" {
  name                = "site-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  service_plan_id     = azurerm_service_plan.main.id
  https_only          = true
  tags                = local.tags

  virtual_network_subnet_id = azurerm_subnet.app.id

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/health"
    health_check_eviction_time_in_min = 2
    vnet_route_all_enabled            = true
    ip_restriction_default_action     = "Allow"

    application_stack {
      docker_image_name   = var.site_image_name
      docker_registry_url = "https://${data.azurerm_container_registry.main.login_server}"
    }

    container_registry_use_managed_identity = true
  }

  app_settings = {
    ASPNETCORE_ENVIRONMENT                = "Production"
    APPLICATIONINSIGHTS_CONNECTION_STRING = azurerm_application_insights.main.connection_string
    MarketingApi__BaseUrl                 = "https://${azurerm_linux_web_app.api.default_hostname}"
    REDIS_CONNECTION_STRING               = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.redis_connection_string.versionless_id})"
    WEBSITES_PORT                         = "8080"
  }
}

resource "azurerm_role_assignment" "api_acr_pull" {
  scope                = data.azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.api.identity[0].principal_id
}

resource "azurerm_role_assignment" "site_acr_pull" {
  scope                = data.azurerm_container_registry.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_linux_web_app.site.identity[0].principal_id
}

resource "azurerm_role_assignment" "api_keyvault_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.api.identity[0].principal_id
}

resource "azurerm_role_assignment" "site_keyvault_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_web_app.site.identity[0].principal_id
}

resource "azurerm_monitor_autoscale_setting" "plan" {
  name                = "autoscale-${local.resource_prefix}-${local.suffix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  target_resource_id  = azurerm_service_plan.main.id
  enabled             = true

  profile {
    name = "default"

    capacity {
      default = 2
      minimum = 2
      maximum = 6
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT5M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "CpuPercentage"
        metric_resource_id = azurerm_service_plan.main.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT10M"
      }
    }
  }

  tags = local.tags
}