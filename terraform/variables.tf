variable "arm_subscription_id" {
  description = "Azure subscription ID."
  type        = string
}

variable "project_name" {
  description = "Prefix used for Azure resource names."
  type        = string
  default     = "site-mkt"
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
  default     = "prod"
}

variable "location" {
  description = "Azure region used for all resources."
  type        = string
  default     = "westus2"
}

variable "acr_name" {
  description = "Name of the existing Azure Container Registry used for image storage."
  type        = string
  default     = "pgdevwus2001"
}

variable "acr_resource_group_name" {
  description = "Resource group containing the existing Azure Container Registry."
  type        = string
  default     = "rg-pg-dev-001"
}

variable "sql_admin_username" {
  description = "Administrator username for Azure SQL Server."
  type        = string
}

variable "sql_admin_password" {
  description = "Administrator password for Azure SQL Server."
  type        = string
  sensitive   = true
}

variable "site_image_name" {
  description = "Image and tag for the site container in ACR."
  type        = string
  default     = "marketing-site:latest"
}

variable "api_image_name" {
  description = "Image and tag for the API container in ACR."
  type        = string
  default     = "marketing-api:latest"
}

variable "site_sku_name" {
  description = "App Service plan SKU."
  type        = string
  default     = "P1v3"
}

variable "redis_capacity" {
  description = "Redis cache capacity."
  type        = number
  default     = 1
}

variable "redis_family" {
  description = "Redis cache family."
  type        = string
  default     = "C"
}

variable "redis_sku_name" {
  description = "Redis cache sku name (Basic, Standard, Premium)."
  type        = string
  default     = "Standard"
}

variable "vnet_address_space" {
  description = "Virtual network address space in CIDR notation."
  type        = string
  default     = "10.0.0.0/16"
}

variable "app_subnet_prefix" {
  description = "Subnet prefix for web app VNet integration in CIDR notation."
  type        = string
  default     = "10.0.1.0/24"
}

variable "sql_endpoint_subnet_prefix" {
  description = "Subnet prefix for SQL private endpoint in CIDR notation."
  type        = string
  default     = "10.0.2.0/24"
}

variable "redis_endpoint_subnet_prefix" {
  description = "Subnet prefix for Redis private endpoint in CIDR notation."
  type        = string
  default     = "10.0.3.0/24"
}
