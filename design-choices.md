# Design Choices


## Azure services selected

Must already exist before GH Workflow is run:
- Azure Container Registry stores container images built by CI.
- Azure Storage account to store remote terraform state.


- Azure App Service for Containers was selected due the service's maturity, simplicity for both `site` and `api` for the sake of this POC.
- Azure SQL Database is used because the API already depends on SQL Server semantics (`SELECT GETDATE()`). And the DateTimeService.cs imports the 'Microsoft.Data.SqlClient' package.
- Azure Cache for Redis is used to satisfy the 5-second cache requirement in the Site service.
- Azure Keyvault to store connection strings and secrets

## Why this works for the traffic profile

- App Service plan autoscale is configured on CPU thresholds to absorb spikes during campaign windows.
- Redis offloads repeated date reads during burst traffic and keeps page response latency stable.
- Application Insights + Log Analytics provide baseline operational visibility.

## Security and operations posture

- SQL Database is not publicly accessible and uses a private endpoint.
- Redis uses a private endpoint for secure cache connectivity within the VNet.
- Runtime secrets are stored in Key Vault and referenced by Web Apps via managed identities.
- For this POC, the API is publicly accessible. Future hardening can add:
  - Identity-based authorization (Entra token validation on API endpoints),
  - Private endpoint for the API (if internal-only access is needed),
  - Stricter network policies and firewall rules.
  - Application Gateway

## Reusability as a template

- The Terraform stack is parameterized with project/environment/location variables.
- CI build/deploy can be reused by other containerized two-service apps with the same shape.