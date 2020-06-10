# Configure the Microsoft Azure Provider
# ToDo: Setup to pull these values from a secure location
provider "azurerm" {
    # The "feature" block is required for AzureRM provider 2.x. 
    # If you're using version 1.x, the "features" block is not allowed.
    version = "~>2.1"
    features {}

    subscription_id = var.subscription_id
    client_id       = var.client_id
    client_secret   = var.client_secret
    tenant_id       = var.tenant_id
}

provider "random" {
  version = "~> 2.2"
}

# Random ID string used to enforce unique names for resources with FQDN
resource "random_string" "randomid" {
  length = 12
  upper = false
  lower = true
  number = false
  special = false
}

# Create a resource group if it doesn't exist.  Errors if existing.
# ToDo: In production, USDA will supply RG.  Must import state, determine RG name
#       then pull in azurerm_resource_group.* values
 resource "azurerm_resource_group" "usda-drupal7-rg" {
    name     = var.resource_group_name
    location = var.location

    tags = {
        environment = "Production"
    }
}

locals {
  resource_group_name            = "${azurerm_resource_group.usda-drupal7-rg.name}"
  resource_group_location        = "${azurerm_resource_group.usda-drupal7-rg.location}"
 }

# Other (cheaper) storage options exist, but performance suffers.
# Remove the "alt" before releasing.
# Share names must be unique even when under different storage accounts.
resource "azurerm_storage_account" "usdadrupal7storagealt" {
  name                     = "usdadrupal7storagealt"
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Premium"
  account_replication_type = "ZRS"
  account_kind             = "FileStorage"
}

resource "azurerm_storage_share" "usda-drupal-uploads-production" {
  name                 = "productionuploads"
  storage_account_name = azurerm_storage_account.usdadrupal7storagealt.name
  quota                = 100
}

resource "azurerm_storage_share" "usda-drupal-db-backup-production" {
  name                 = "productiondb"
  storage_account_name = azurerm_storage_account.usdadrupal7storagealt.name
  quota                = 100
}

resource "azurerm_mariadb_server" "usda-d7-prod-dbserver" {
  name                = "usda-d7-prod-dbserver-${random_string.randomid.result}"
  location            = var.location
  resource_group_name = var.resource_group_name

  sku_name = "GP_Gen5_2"

  storage_profile {
    storage_mb            = 5120
    backup_retention_days = 30
    geo_redundant_backup  = "Disabled"
  }

  administrator_login          = var.db_admin_login
  administrator_login_password = var.db_admin_password
  version                      = "10.2"
  ssl_enforcement              = "Disabled"
}

resource "azurerm_mariadb_database" "usda-d7-prod-database" {
  name                = "usda_d7_prod_db_${random_string.randomid.result}"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.usda-d7-prod-dbserver.name
  charset             = "utf8"
  collation           = "utf8_general_ci"
}

# Default value is 512M
resource "azurerm_mariadb_configuration" "usda-d7-prod-db-map" {
  name                = "max_allowed_packet"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.usda-d7-prod-dbserver.name
  value               = "134217728"
}

# Default value is 1
resource "azurerm_mariadb_configuration" "usda-d7-prod-db-lqt" {
  name                = "long_query_time"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.usda-d7-prod-dbserver.name
  value               = "1"
}

# Opens up DB to any Azure app service.  In prod, must be limited to specific app service.
# ToDo: Update to create rule for each in azurerm_app_service_plan.drupal.outbound_ip_addresses
resource "azurerm_mariadb_firewall_rule" "usda-d7-prod-db-fw-rule-inbound-cli" {
  name                = "usda-d7-prod-fw-rule-inbound-cli"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.usda-d7-prod-dbserver.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}

# Default value is OFF
resource "azurerm_mariadb_configuration" "usda-d7-prod-db-sql" {
  name                = "slow_query_log"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.usda-d7-prod-dbserver.name
  value               = "ON"
}

resource "azurerm_app_service_plan" "usda-d7-prod-asp" {
  name                = "usda-d7-prod-asp"
  location            = var.location
  resource_group_name = var.resource_group_name
  kind                = "Linux"
  reserved            = true
  sku {
    tier = "Standard"
    size = "P1V2"
  }
}

resource "azurerm_app_service" "agdatacommons-prod-web-as" {
  name                = "agdatacommons-prod-web"
  location            = var.location
  resource_group_name = var.resource_group_name
  app_service_plan_id = azurerm_app_service_plan.usda-d7-prod-asp.id
  enabled             = true
  storage_account {
    name              = "agdatacommons-uploads-prod"
    type              = "AzureFiles"
    account_name      = azurerm_storage_account.usdadrupal7storagealt.name
    share_name        = azurerm_storage_share.usda-drupal-uploads-production.name
    access_key        = azurerm_storage_account.usdadrupal7storagealt.primary_access_key
    mount_path	      = "/var/www/docroot/sites/default/files"
  }

  storage_account {
    name              = "agdatacommons-db-prod"
    type              = "AzureFiles"
    account_name      = azurerm_storage_account.usdadrupal7storagealt.name
    share_name        = azurerm_storage_share.usda-drupal-db-backup-production.name
    access_key        = azurerm_storage_account.usdadrupal7storagealt.primary_access_key
    mount_path	      = "/mnt/db_backups"
  }

  site_config {
    app_command_line = ""
    linux_fx_version = "DOCKER|dasumner/php72-web-mysql-drush-combo-as"
  }

  app_settings = {
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "true",
    "WEBSITE_AUTH_ENABLE" = "true",
    "DOCKER_REGISTRY_SERVER_URL"          = "https://index.docker.io"
  }
}

resource "azurerm_app_service" "agdatacommons-prod-solr-as" {
  name                = "agdatacommons-prod-solr"
  location            = var.location
  resource_group_name = var.resource_group_name
  app_service_plan_id = azurerm_app_service_plan.usda-d7-prod-asp.id
  enabled             = true
  site_config {
    app_command_line = ""
    linux_fx_version = "DOCKER|solr"
  }

  app_settings = {
    "WEBSITES_ENABLE_APP_SERVICE_STORAGE" = "true",
    "WEBSITE_AUTH_ENABLE" = "true",
    "DOCKER_REGISTRY_SERVER_URL"          = "https://index.docker.io",
    "WEBSITES_PORT" = "8983"
  }
}