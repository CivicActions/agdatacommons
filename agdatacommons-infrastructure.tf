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
 resource "azurerm_resource_group" "nal-adc-prod-rg" {
    name     = "nal-adc-prod-rg"
    location = var.location

    tags = {
        environment = "Production"
    }
}

locals {
  resource_group_name            = "${azurerm_resource_group.nal-adc-prod-rg.name}"
  resource_group_location        = "${azurerm_resource_group.nal-adc-prod-rg.location}"
}

# Share names must be unique even when under different storage accounts.
resource "azurerm_storage_account" "naladcstorage" {
  name                     = "naladcstorage"
  resource_group_name = var.resource_group_name
  location            = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  depends_on          = [azurerm_resource_group.nal-adc-prod-rg]
}

resource "azurerm_storage_share" "naladc-uploads-production" {
  name                 = "productionuploads"
  storage_account_name = azurerm_storage_account.naladcstorage.name
  quota                = 500
}

resource "azurerm_storage_share" "naladc-db-backup-production" {
  name                 = "productiondb"
  storage_account_name = azurerm_storage_account.naladcstorage.name
  quota                = 500
}

resource "azurerm_mariadb_server" "nal-adc-prod-dbserver" {
  name                = "nal-adc-prod-dbserver-${random_string.randomid.result}"
  location            = var.location
  resource_group_name = var.resource_group_name

  sku_name = "GP_Gen5_2"

  storage_profile {
    storage_mb            = 5120
    backup_retention_days = 30
    geo_redundant_backup  = "Disabled"
  }

  administrator_login          = "drupal"
  administrator_login_password = "Admin!23"
  version                      = "10.2"
  ssl_enforcement              = "Disabled"
  depends_on          = [azurerm_resource_group.nal-adc-prod-rg]
}

resource "azurerm_mariadb_database" "nal-adc-prod-database" {
  name                = "nal_adc_prod_db_${random_string.randomid.result}"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.nal-adc-prod-dbserver.name
  charset             = "utf8"
  collation           = "utf8_general_ci"
}

# Default value is 512M
resource "azurerm_mariadb_configuration" "nal-adc-prod-db-map" {
  name                = "max_allowed_packet"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.nal-adc-prod-dbserver.name
  value               = "134217728"
}

# Default value is 1
resource "azurerm_mariadb_configuration" "nal-adc-prod-db-lqt" {
  name                = "long_query_time"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.nal-adc-prod-dbserver.name
  value               = "1"
}

# Default value is OFF
resource "azurerm_mariadb_configuration" "nal-adc-prod-db-sql" {
  name                = "slow_query_log"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.nal-adc-prod-dbserver.name
  value               = "ON"
}

resource "azurerm_container_group" "nal-adc-prod-container-group-web-1" {
  name                = "nal-adc-prod-container-group-web-1"
  resource_group_name = var.resource_group_name
  location            = var.location
  ip_address_type     = "public"
  os_type             = "Linux"

  container {
    name   = "webcli"
    image  = "dasumner/php72-web-mysql-drush-combo"
    cpu    = "2.0"
    memory = "8.0"
    
    ports { 
      port     =  80
      protocol = "TCP"
    }

    ports { 
      port     =  443
      protocol = "TCP"
    }

    ports { 
      port     =  22
      protocol = "TCP"
    }

    # This volume is persistent storage, an Azure file share where the files will remain regardless of what happens
    # to the container.
    volume {
      name       = "productionuploads"
      mount_path = "/var/www/docroot/sites/default/files"
      read_only  = false
      share_name = azurerm_storage_share.naladc-uploads-production.name
      storage_account_name = azurerm_storage_account.naladcstorage.name
      storage_account_key  = azurerm_storage_account.naladcstorage.primary_access_key
    }

    # This volume is persistent storage, an Azure file share where the files will remain regardless of what happens
    # to the container.
    volume {
      name       = "productiondbbackup"
      mount_path = "/mnt/db_backups"
      read_only  = false
      share_name = azurerm_storage_share.naladc-db-backup-production.name
      storage_account_name = azurerm_storage_account.naladcstorage.name
      storage_account_key  = azurerm_storage_account.naladcstorage.primary_access_key
    }
  }

  tags = {
    environment = "production"
  }
}

resource "azurerm_container_group" "nal-adc-prod-container-group-web-2" {
  name                = "nal-adc-prod-container-group-web-2"
  resource_group_name = var.resource_group_name
  location            = var.location
  ip_address_type     = "public"
  os_type             = "Linux"

  container {
    name   = "webcli"
    image  = "dasumner/php72-web-mysql-drush-combo"
    cpu    = "2.0"
    memory = "8.0"
    
    ports { 
      port     =  80
      protocol = "TCP"
    }

    ports { 
      port     =  443
      protocol = "TCP"
    }

    ports { 
      port     =  22
      protocol = "TCP"
    }

    # This volume is persistent storage, an Azure file share where the files will remain regardless of what happens
    # to the container.
    volume {
      name       = "productionuploads"
      mount_path = "/var/www/docroot/sites/default/files"
      read_only  = false
      share_name = azurerm_storage_share.naladc-uploads-production.name
      storage_account_name = azurerm_storage_account.naladcstorage.name
      storage_account_key  = azurerm_storage_account.naladcstorage.primary_access_key
    }

    # This volume is persistent storage, an Azure file share where the files will remain regardless of what happens
    # to the container.
    volume {
      name       = "productiondbbackup"
      mount_path = "/mnt/db_backups"
      read_only  = false
      share_name = azurerm_storage_share.naladc-db-backup-production.name
      storage_account_name = azurerm_storage_account.naladcstorage.name
      storage_account_key  = azurerm_storage_account.naladcstorage.primary_access_key
    }
  }

  tags = {
    environment = "production"
  }
}

resource "azurerm_container_group" "nal-adc-prod-container-group-solr-1" {
  name                = "nal-adc-prod-container-group-solr-1"
  resource_group_name = var.resource_group_name
  location            = var.location
  ip_address_type     = "Public"
  os_type             = "Linux"

  container {
    name   = "solr"
    image  = "solr"
    cpu    = "2.0"
    memory = "8.0"

    ports {
      port     = 8983
      protocol = "TCP"
    }

    environment_variables = {
      SOLR_PORT_NUMBER = 8983
    }
  }

  tags = {
    environment = "production"
  }
}

# Opens up DB to any Azure app service.  In prod, must be limited to specific app service.
# ToDo: Update to create rule for each in azurerm_app_service_plan.drupal.outbound_ip_addresses
resource "azurerm_mariadb_firewall_rule" "nal-adc-prod-db-fw-rule-inbound-cli" {
  name                = "nal-adc-prod-fw-rule-inbound-cli"
  resource_group_name = var.resource_group_name
  server_name         = azurerm_mariadb_server.nal-adc-prod-dbserver.name
  start_ip_address    = "0.0.0.0"
  end_ip_address      = "0.0.0.0"
}
