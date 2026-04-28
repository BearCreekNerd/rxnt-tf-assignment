
# Problem Statement

The marketing department is launching a new promotional landing page that displays a 'hello world' message with the current date, pulled from a sensitive SQL database, which is cached for 5 seconds. They expect significant traffic from 10:00 AM to 8:00 PM EST, especially during the first few days of the campaign.

Your task is to use Terraform to provision the Azure infrastructure to support this application. You are responsible for designing the full solution architecture to meet the requirements of a production environment.

### Strategic Context

This deployment is more than a one-time project. It is a Proof of Concept (POC) designed to establish a reusable and standardized pattern for deploying similar containerized applications within the organization. A successful outcome will serve as a template, allowing other teams to quickly adopt a secure and scalable architecture for their own initiatives.

## Requirements

- **Use Terraform** to provision all Azure infrastructure
- **Deploy to Azure** (your choice of services)

## Deliverables

A repository link containing a git repository with your Terraform code, and a readme file with instructions for deployment. The README should also include a brief overview of your design choices.


# Further Information

This site is the first version of the Hello World Site. It is composed of two projects `Site` and `Api`.

## Requirements to run the site

The Site container expects the following environment variables:
- `REDIS_CONNECTION_STRING` to contain a connection string for a Redis server.
- `MarketingApi__BaseUrl` to contain the base URL of the Api project.

The Api container expects the following environment variables:
- `DB_CONNECTION_STRING` to contain a connection string for a SQL Server.

The solution also contains a `docker-compose.yml` file that can be used to run the site locally using Docker.

## Setup and Deployment Guide

### Prerequisites

| Tool | Minimum Version |
|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.6.0 |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | 2.x |
| [Docker](https://docs.docker.com/engine/install/) | 20.x |

### 1. Authenticate with Azure

```bash
az login
az account set --subscription "<subscription-id>"
```

Terraform uses your active Azure CLI session for both provider authentication and remote state access.

### 2. Create the Remote State Backend

Skip this section if a shared backend storage account already exists.

Terraform state is stored in an Azure Storage blob. The storage account must exist before running `terraform init`.

```bash
# Variables - adjust to suit your naming convention
STATE_RG="rg-tfstate"
STATE_SA="tfstate$RANDOM"   # must be globally unique, 3-24 lowercase alphanumeric
STATE_CONTAINER="tfstate"
LOCATION="westus2"

# Resource group
az group create \
	--name "$STATE_RG" \
	--location "$LOCATION"

# Storage account
az storage account create \
	--name "$STATE_SA" \
	--resource-group "$STATE_RG" \
	--location "$LOCATION" \
	--sku Standard_LRS \
	--allow-blob-public-access false \
	--min-tls-version TLS1_2

# Blob container
az storage container create \
	--name "$STATE_CONTAINER" \
	--account-name "$STATE_SA" \
	--auth-mode login

# Print the values needed for backend.conf
echo "resource_group_name  = \"$STATE_RG\""
echo "storage_account_name = \"$STATE_SA\""
echo "container_name       = \"$STATE_CONTAINER\""
```

### 3. Create the Azure Container Registry

Skip this section if a shared ACR already exists. The name must match `acr_name` and `acr_resource_group_name` in `terraform.tfvars`.

```bash
ACR_RG="rg-pg-dev-001"
ACR_NAME="pgdevwus2001"
LOCATION="westus2"

az group create \
	--name "$ACR_RG" \
	--location "$LOCATION"

az acr create \
	--name "$ACR_NAME" \
	--resource-group "$ACR_RG" \
	--location "$LOCATION" \
	--sku Standard \
	--admin-enabled false

az acr show --name "$ACR_NAME" --query loginServer --output tsv
```

### 4. Configure the Remote Backend

Create `terraform/backend.conf`:

```hcl
resource_group_name  = "<state-rg>"
storage_account_name = "<state-storage-account>"
container_name       = "tfstate"
key                  = "site-mkt.tfstate"
```

### 5. Create terraform.tfvars

Create `terraform/terraform.tfvars` with required SQL credentials:

```hcl
sql_admin_username = "sqladmin"
sql_admin_password = "YourStr0ngP@ssword!"
```

See `terraform/variables.tf` for optional overrides and defaults.

### 6. Set Subscription ID Environment Variable

Terraform requires `TF_VAR_arm_subscription_id` for azurerm provider `~> 4.7.0`:

```bash
export TF_VAR_arm_subscription_id=$(az account show --query id -o tsv)
echo $TF_VAR_arm_subscription_id
```

In GitHub Actions, this is supplied from `AZURE_SUBSCRIPTION_ID`.

### 7. Configure Terraform GitHub Workflow (Secrets, Variables, and OIDC)

The workflow file is [.github/workflows/terraform.yml](.github/workflows/terraform.yml) and uses OIDC-based login via `azure/login@v2`.

Required GitHub repository secrets:

- `AZURE_CLIENT_ID`: Application (client) ID of the Entra app/service principal used by GitHub Actions.
- `AZURE_TENANT_ID`: Entra tenant ID.
- `AZURE_SUBSCRIPTION_ID`: Azure subscription used for deployment.
- `TFSTATE_RESOURCE_GROUP`: Resource group containing the Terraform state storage account.
- `TFSTATE_STORAGE_ACCOUNT`: Storage account name for remote state.
- `TFSTATE_CONTAINER`: Blob container name for remote state (for example `tfstate`).
- `TFSTATE_KEY`: State file key (for example `site-mkt.tfstate`).
- `TF_VAR_SQL_ADMIN_USERNAME`: SQL admin username passed to Terraform.
- `TF_VAR_SQL_ADMIN_PASSWORD`: SQL admin password passed to Terraform.

Repository variables are optional in this workflow because sensitive and backend values are currently sourced from secrets. Use repository variables only for non-sensitive values (for example static region names or feature toggles) if you later refactor the workflow.

OIDC prerequisites in Azure:

1. Create or choose an Entra app registration and service principal.
2. Grant it enough Azure RBAC on the target scope (subscription or resource group), for example Contributor.
3. Add a federated credential on the app registration with:
	 - Issuer: `https://token.actions.githubusercontent.com`
	 - Audience: `api://AzureADTokenExchange`
	 - Subject for main branch deploys: `repo:BearCreekNerd/rxnt-tf-assignment:ref:refs/heads/main`
4. Ensure workflow permissions include `id-token: write` (already configured).

Example Azure CLI for federated credential:

```bash
APP_OBJECT_ID="<entra-app-object-id>"

az ad app federated-credential create \
	--id "$APP_OBJECT_ID" \
	--parameters '{
		"name": "github-main",
		"issuer": "https://token.actions.githubusercontent.com",
		"subject": "repo:BearCreekNerd/rxnt-tf-assignment:ref:refs/heads/main",
		"audiences": ["api://AzureADTokenExchange"]
	}'
```

After configuration, run the workflow manually with `workflow_dispatch` or push to `main` for automatic execution.

### 8. Initialize

```bash
cd terraform
terraform init -backend-config=backend.conf
```

### 9. Plan and Apply

```bash
terraform plan
terraform apply
```

### 10. Push Container Images to ACR

```bash
ACR=$(terraform output -raw container_registry_login_server)

az acr login --name "$ACR"

docker build -f ../Dockerfile.site -t "$ACR/marketing-site:latest" ..
docker push "$ACR/marketing-site:latest"

docker build -f ../Dockerfile.api -t "$ACR/marketing-api:latest" ..
docker push "$ACR/marketing-api:latest"
```

### 11. Tear Down

```bash
terraform destroy
```

## Design Choices

### Azure Services Selected

These resources should already exist before GH Workflow is run:
- Azure Container Registry stores container images built by CI.
- Azure Storage account to store remote terraform state.
=========
- Azure App Service for Containers was selected due the service's maturity, simplicity for both `site` and `api` for the sake of this POC.
- Azure SQL Database is used because the API already depends on SQL Server semantics (`SELECT GETDATE()`). And the DateTimeService.cs imports the 'Microsoft.Data.SqlClient' package.
- Azure Cache for Redis is used to satisfy the 5-second cache requirement in the Site service.
- Azure Keyvault to store connection strings and secrets.
- Azure Private Link and endpoints are utlized to restrict public access to the database and redis cache.

### Why This Works for Traffic Profile

- App Service autoscale is configured on CPU thresholds to absorb spikes. Rules have been applied for on and off hours to match with the time frame requirements.
- Redis offloads repeated date reads during burst traffic.
- Application Insights and Log Analytics provide baseline observability.

### Security and Operations

- SQL Database is not publicly accessible and uses a private endpoint.
- Redis uses a private endpoint for secure cache connectivity within the VNet.
- Runtime secrets are stored in Key Vault and referenced by Web Apps via managed identities. I try to avoid secret/password management where possible.
- For this POC, the API is publicly accessible. Future hardening can add:
  - Identity-based authorization (Entra token validation on API endpoints),
  - Private endpoint for the API (if internal-only access is needed),
  - Stricter network policies and firewall rules.
  - Application Gateway. I did not implement it as even for testing it can become cost probitive. Considered utlized these module:
  https://github.com/Azure/terraform-azurerm-avm-res-network-applicationgateway/tree/main. Moreover, my understanding is, even if we have a self generated certificate aht is automatically stored in a keyvault to be referenced by the App Gateway or just App Service, an actual domain name is needed. It will not let you use the auto-generated *azurewebsites.net.

### Reusability as a Template

- The Terraform stack is parameterized with project/environment/location variables.
- CI build/deploy can be reused by other containerized two-service apps with the same shape. 
- Created a service principal to use to for OIDC in the terraform workflow to minimize secret management and avoid issues with secrets expiring.ret sprawl and credential rotation overhead.

### References

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
- https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect
