# Design Choices


## Azure services selected

These resources already exist before GH Workflow is run:
- Azure Container Registry stores container images built by CI.
- Azure Storage account to store remote terraform state.
=========
- Azure App Service for Containers was selected due the service's maturity, simplicity for both `site` and `api` for the sake of this POC.
- Azure SQL Database is used because the API already depends on SQL Server semantics (`SELECT GETDATE()`). And the DateTimeService.cs imports the 'Microsoft.Data.SqlClient' package.
- Azure Cache for Redis is used to satisfy the 5-second cache requirement in the Site service.
- Azure Keyvault to store connection strings and secrets.
- Azure Private Link and endpoints are utlized to restrict public access to the database and redis cache.

## Why this works for the traffic profile

- App Service plan autoscale is configured on CPU thresholds to absorb spikes during campaign windows.
- Redis offloads repeated date reads during burst traffic and keeps page response latency stable.
- Application Insights + Log Analytics provide baseline operational visibility.

## Security and operations

- SQL Database is not publicly accessible and uses a private endpoint.
- Redis uses a private endpoint for secure cache connectivity within the VNet.
- Runtime secrets are stored in Key Vault and referenced by Web Apps via managed identities. I try to avoid secret/password management where possible.
- For this POC, the API is publicly accessible. Future hardening can add:
  - Identity-based authorization (Entra token validation on API endpoints),
  - Private endpoint for the API (if internal-only access is needed),
  - Stricter network policies and firewall rules.
  - Application Gateway. I did not implement it as even for testing it can become cost probitive. Considered utlized these module:
  https://github.com/Azure/terraform-azurerm-avm-res-network-applicationgateway/tree/main. Moreover, my understanding is, even if we have a self generated certificate aht is automatically stored in a keyvault to be referenced by the App Gateway or just App Service, an actual domain name is needed. It will not let you use the auto-generated *azurewebsites.net.

## Reusability as a template

- The Terraform stack is parameterized with project/environment/location variables.
- CI build/deploy can be reused by other containerized two-service apps with the same shape. 
- Created a service principal to use to for OIDC in the terraform workflow to minimize secret management and avoid issues with secrets expiring.



## References
- https://learn.microsoft.com/en-us/azure/private-link/private-link-overview
- https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault
- https://learn.microsoft.com/en-us/azure/azure-cache-for-redis/cache-overview
- https://learn.microsoft.com/en-us/azure/app-service/overview
- https://learn.microsoft.com/en-us/azure/app-service/manage-automatic-scaling
- https://learn.microsoft.com/en-us/azure/azure-monitor/autoscale/autoscale-get-started?toc=/azure/app-service/toc.json#scale-based-on-a-repeating-schedule
- https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_autoscale_setting.html
- https://learn.microsoft.com/en-us/azure/key-vault/keys/quick-create-terraform?tabs=azure-cli
- https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview
- https://learn.microsoft.com/en-us/azure/redis/private-link
- https://learn.microsoft.com/en-us/azure/azure-sql/database/sql-database-paas-overview?view=azuresql

