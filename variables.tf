variable "subscription_id" {
    type = string
    default = "000a000c-00b0-0c00-00d0-00000ee00000"
}

variable "client_id" {
    type = string
    default = "000a000-00b0-0c00-00d0-00000ee00000"
}

variable "client_secret" {
    type = string
    default = "000a0000-00b0-0c00-00d0-00000ee00000"
}

variable "tenant_id" {
    type = string
    default = "000a000-00b0-0c00-00d0-00000ee00000"
}

variable "location" {
    type = string
    default = "eastus"
}

variable "db_admin_login" {
    type = string
    default = "drupal"
}

variable "db_admin_password" {
    type = string
    default = "Admin!23"
}

variable "resource_group_name" {
    type = string
    default = "nal-adc-prod-rg"
}
