# Terraform Setup Guide

---

## Prerequisites

| Tool | Minimum Version |
|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | 1.6.0 |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | 2.x |
| [Docker](https://docs.docker.com/engine/install/) | 20.x |

---

## 1. Authenticate with Azure

```bash
az login
az account set --subscription "<subscription-id>"
```

Terraform uses your active Azure CLI session for both provider authentication and remote state access.

---

## 2. Create the Remote State Backend

Skip this section if a shared backend storage account already exists.

Terraform state is stored in an Azure Storage blob. The storage account must exist **before** running `terraform init`.

```bash
# Variables — adjust to suit your naming convention
STATE_RG="rg-tfstate"
STATE_SA="tfstate$RANDOM"   # must be globally unique, 3-24 lowercase alphanumeric
STATE_CONTAINER="tfstate"
LOCATION="westus2"

# Resource group
az group create \
  --name "$STATE_RG" \
  --location "$LOCATION"

# Storage account (Standard LRS is sufficient for state)
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

Record the printed values — you will need them in the next step.
---

## 3. Create the Azure Container Registry

Skip this section if a shared ACR already exists. The name you use here must match the `acr_name` and `acr_resource_group_name` variables in `terraform.tfvars`.

```bash
ACR_RG="rg-pg-dev-001"       # acr_resource_group_name
ACR_NAME="pgdevwus2001"      # acr_name
LOCATION="westus2"

# Resource group (skip if it already exists)
az group create \
  --name "$ACR_RG" \
  --location "$LOCATION"

# Container registry (Standard tier supports geo-replication and webhooks)
az acr create \
  --name "$ACR_NAME" \
  --resource-group "$ACR_RG" \
  --location "$LOCATION" \
  --sku Standard \
  --admin-enabled false

# Confirm the login server
az acr show --name "$ACR_NAME" --query loginServer --output tsv
```

The `loginServer` value (e.g. `pgdevwus2001.azurecr.io`) is what Terraform reads via the `data "azurerm_container_registry"` data source.

---

## 4. Configure the Remote Backend

The backend block in `providers.tf` is intentionally empty — backend values are supplied at `init` time via a local config file that is **never committed to source control**.

Create `terraform/backend.conf` using the values from step 2:

```hcl
resource_group_name  = "<state-rg>"
storage_account_name = "<state-storage-account>"
container_name       = "tfstate"
key                  = "site-mkt.tfstate"
```

---

## 5. Create `terraform.tfvars`

Create `terraform/terraform.tfvars`. The only required values (no defaults) are the SQL credentials:

```hcl
sql_admin_username = "sqladmin"
sql_admin_password = "YourStr0ngP@ssword!"
```

See `variables.tf` for all optional overrides and their defaults.

> **Both `backend.conf` and `terraform.tfvars` must be added to `.gitignore` — they contain secrets.**

---

## 6. Set the Subscription ID Environment Variable

Terraform requires the Azure subscription ID to be provided via the `TF_VAR_arm_subscription_id` environment variable. This is used by the AzureRM provider during `plan` and `apply`.

Get your subscription ID and set the environment variable:

**PowerShell:**
```powershell
$env:TF_VAR_arm_subscription_id = $(az account show --query id -o tsv)
```

**Bash:**
```bash
export TF_VAR_arm_subscription_id=$(az account show --query id -o tsv)
```

Verify it's set:

**PowerShell:**
```powershell
$env:TF_VAR_arm_subscription_id
```

**Bash:**
```bash
echo $TF_VAR_arm_subscription_id
```

> **Note:** In GitHub Actions, this is automatically provided via the `AZURE_SUBSCRIPTION_ID` secret through the workflow environment variable configuration.

---

## 7. Initialize

```bash
cd terraform
terraform init -backend-config=backend.conf
```

This connects to the remote state backend and downloads required providers. Confirm any state migration prompts if switching from a different backend.

---

## 8. Plan and Apply

```bash
terraform plan
terraform apply
```

On completion, Terraform outputs the following:

| Output | Description |
|---|---|
| `site_url` | Public URL for the marketing site |
| `api_url` | Public URL for the API |
| `resource_group_name` | Azure resource group containing all resources |
| `key_vault_name` | Key Vault used for secret references |
| `container_registry_login_server` | ACR login server for image pushes |
| `site_web_app_name` | App Service name for the site |
| `api_web_app_name` | App Service name for the API (used for SQL managed identity setup) |

---

## 9. Push Container Images to ACR

The App Services pull images from the existing ACR. Build and push after `apply`:

```bash
ACR=$(terraform output -raw container_registry_login_server)

az acr login --name "$ACR"

docker build -f ../Dockerfile.site -t "$ACR/marketing-site:latest" ..
docker push "$ACR/marketing-site:latest"

docker build -f ../Dockerfile.api -t "$ACR/marketing-api:latest" ..
docker push "$ACR/marketing-api:latest"
```

Image names must match `site_image_name` and `api_image_name` variable values (defaults: `marketing-site:latest`, `marketing-api:latest`).

---

## 10. Tear Down

```bash
terraform destroy
```

Removes all Azure resources provisioned by this configuration. The remote state file in the storage account is preserved.
