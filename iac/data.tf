data "azurerm_client_config" "current" {}

data "azurerm_key_vault" "tf_kv" {
  name                = "trfrm-kv"
  resource_group_name = "terraform-rg"
}

data "azurerm_key_vault_key" "vm_key" {
  name         = "vm-key"
  key_vault_id = data.azurerm_key_vault.tf_kv.id
}

data "http" "myip" {
  url = "https://api.ipify.org/"
}