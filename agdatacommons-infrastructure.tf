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

# Create a vnet to support the infrastructure.
resource "azurerm_virtual_network" "nal-adc-prod-vnet" {
  name                = "production-network"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = ["10.0.0.0/16"]
  depends_on          = [azurerm_resource_group.nal-adc-prod-rg]
}

# Private subnet for the container groups.  This subnet has no external
# connectivity.
resource "azurerm_subnet" "nal-adc-prod-subnet" {
  name                 = "internal"
  virtual_network_name = azurerm_virtual_network.nal-adc-prod-vnet.name
  resource_group_name = var.resource_group_name
  address_prefix       = "10.0.1.0/24"
  delegation {
    name = "acctestdelegation"

    service_delegation {
      name    = "Microsoft.ContainerInstance/containerGroups"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Public subnet for the Application Gateway.  This subnet has external connectivity.
resource "azurerm_subnet" "nal-adc-prod-public-subnet" {
  name                 = "external"
  virtual_network_name = azurerm_virtual_network.nal-adc-prod-vnet.name
  resource_group_name  = var.resource_group_name
  address_prefix       = "10.0.2.0/24"
}

# Public IP for inbound traffic
resource "azurerm_public_ip" "nal-adc-public-ip" {
  name                = "prod-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  depends_on          = [azurerm_resource_group.nal-adc-prod-rg]
}

locals {
  resource_group_name            = "${azurerm_resource_group.nal-adc-prod-rg.name}"
  resource_group_location        = "${azurerm_resource_group.nal-adc-prod-rg.location}"
  backend_address_pool_web_name  = "azurerm_virtual_network.nal-adc-prod-vnet.name-web-beap"
  backend_address_pool_solr_name = "azurerm_virtual_network.nal-adc-prod-vnet.name-solr-beap"
  frontend_port_name             = "azurerm_virtual_network.nal-adc-prod-vnet.name-feport"
  frontend_ip_configuration_name = "azurerm_virtual_network.nal-adc-prod-vnet.name-feip"
  http_setting_name              = "azurerm_virtual_network.nal-adc-prod-vnet.name-be-htst"
  listener_name_http             = "azurerm_virtual_network.nal-adc-prod-vnet.name-httplstn"
  listener_name_solr             = "azurerm_virtual_network.nal-adc-prod-vnet.name-solrlstn"
  request_routing_rule_name_web  = "azurerm_virtual_network.nal-adc-prod-vnet.name-rqrt-web"
  request_routing_rule_name_solr = "azurerm_virtual_network.nal-adc-prod-vnet.name-rqrt-solr"
  redirect_configuration_name    = "azurerm_virtual_network.nal-adc-prod-vnet.name-rdrcfg"
}

# Application gateway to route inbound traffic through the public subnet to the
# private subnet to the container group.  Routing rules are setup to direct port 80 traffic
# to the web container and port 8983 traffic to the Solr container.
resource "azurerm_application_gateway" "network" {
  name                = "nal-adc-appgateway"
  resource_group_name = var.resource_group_name
  location            = var.location

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "my-gateway-ip-configuration"
    subnet_id = azurerm_subnet.nal-adc-prod-public-subnet.id
  }

  frontend_port {
    name = local.frontend_port_name
    port = 80
  }

  frontend_port {
     name = "port_8983"
    port = 8983
  }

  frontend_ip_configuration {
    name                 = local.frontend_ip_configuration_name
    public_ip_address_id = azurerm_public_ip.nal-adc-public-ip.id
  }

  backend_address_pool {
    name = local.backend_address_pool_web_name
    ip_addresses = ["${azurerm_container_group.nal-adc-prod-container-group-1.ip_address}"]
  }

  backend_address_pool {
    name = local.backend_address_pool_solr_name
    ip_addresses = ["${azurerm_container_group.nal-adc-prod-container-group-2.ip_address}"]
  }

  backend_http_settings {
    name                  = local.http_setting_name
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 1
  }

  backend_http_settings {
    name                  = "solr"
    cookie_based_affinity = "Disabled"
    port                  = 8983
    protocol              = "Http"
    request_timeout       = 1
  }

  http_listener {
    name                           = local.listener_name_http
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = local.frontend_port_name
    protocol                       = "Http"
  }

  http_listener {
    name                           = local.listener_name_solr
    frontend_ip_configuration_name = local.frontend_ip_configuration_name
    frontend_port_name             = "port_8983"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = local.request_routing_rule_name_web
    rule_type                  = "Basic"
    http_listener_name         = local.listener_name_http
    backend_address_pool_name  = local.backend_address_pool_web_name
    backend_http_settings_name = local.http_setting_name
  }

  request_routing_rule {
    name                       = local.request_routing_rule_name_solr
    rule_type                  = "Basic"
    http_listener_name         = local.listener_name_solr
    backend_address_pool_name  = local.backend_address_pool_solr_name
    backend_http_settings_name = "solr"
  }
}

# Network profile required by Azure to serve as the wrapper that connects
# container group.
resource "azurerm_network_profile" "nal-adc-prod-np" {
  name                = "prodnetprofile"
  resource_group_name = var.resource_group_name
  location            = var.location

  container_network_interface {
    name = "prodcnic"

    ip_configuration {
      name      = "prodipconfig"
      subnet_id = azurerm_subnet.nal-adc-prod-subnet.id
    }
  }
}

resource "azurerm_network_security_group" "nal-adc-prod-nsg" {
  name                = "production-nsg"
  resource_group_name = var.resource_group_name
  location            = var.location
  depends_on          = [azurerm_resource_group.nal-adc-prod-rg]
}

# Other (cheaper) storage options exist, but performance suffers.
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
  name                = "nal-adc-prod-dbserver"
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
  name                = "nal_adc_prod_db"
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

resource "azurerm_container_group" "nal-adc-prod-container-group-1" {
  name                = "nal-adc-prod-container_group-1"
  resource_group_name = var.resource_group_name
  location            = var.location
  ip_address_type     = "private"
  os_type             = "Linux"
  network_profile_id  = azurerm_network_profile.nal-adc-prod-np.id

  container {
    name   = "webcli"
    image  = "dasumner/adc-web-cli-combo"
    cpu    = "2.0"
    memory = "8.0"
    
    ports { 
      port     =  80
      protocol = "TCP"
    }

    environment_variables  = {
      DKTL_MODE = "HOST"
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

resource "azurerm_container_group" "nal-adc-prod-container-group-2" {
  name                = "nal-adc-prod-container_group-2"
  resource_group_name = var.resource_group_name
  location            = var.location
  ip_address_type     = "private"
  os_type             = "Linux"
  network_profile_id  = azurerm_network_profile.nal-adc-prod-np.id

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
