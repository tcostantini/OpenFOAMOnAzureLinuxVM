terraform {
  required_version = "1.2.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "3.15.1"
    }
  }
  
  backend "azurerm" {}
}

provider "azurerm" {
  features {}
}

locals {
  prefix  = "cfd"
  ssh_key = sensitive(data.azurerm_key_vault_key.vm_key.public_key_openssh)
}

resource "azurerm_resource_group" "cfd_rg" {
  name     = "${local.prefix}-rg"
  location = "eastus"
}

resource "azurerm_public_ip" "cfd_pip" {
  depends_on          = [azurerm_resource_group.cfd_rg]
  name                = "${local.prefix}-pip-vm"
  resource_group_name = azurerm_resource_group.cfd_rg.name
  location            = azurerm_resource_group.cfd_rg.location
  allocation_method   = "Dynamic"
}

resource "azurerm_virtual_network" "cfd_vnet" {
  depends_on          = [azurerm_resource_group.cfd_rg]
  name                = "${local.prefix}-vnet"
  address_space       = ["10.0.0.0/28"]
  location            = azurerm_resource_group.cfd_rg.location
  resource_group_name = azurerm_resource_group.cfd_rg.name
}

resource "azurerm_network_security_group" "cfd_nsg_ssh" {
  depends_on          = [azurerm_resource_group.cfd_rg]
  name                = "${local.prefix}-nsg"
  location            = azurerm_resource_group.cfd_rg.location
  resource_group_name = azurerm_resource_group.cfd_rg.name

  security_rule {
    name                       = "SSH"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "${chomp(data.http.myip.body)}"
    destination_address_prefix = "*"
  }
  
  lifecycle {
    ignore_changes = [
	  security_rule
	]
  }
}

resource "azurerm_subnet" "cfd_subnet" {
  depends_on           = [azurerm_resource_group.cfd_rg, azurerm_virtual_network.cfd_vnet]
  name                 = "${local.prefix}-subnet-vm"
  resource_group_name  = azurerm_resource_group.cfd_rg.name
  virtual_network_name = azurerm_virtual_network.cfd_vnet.name
  address_prefixes     = ["10.0.0.8/29"]
}

resource "azurerm_network_interface" "cfd_nic_internal" {
  depends_on          = [azurerm_subnet.cfd_subnet]
  name                = "${local.prefix}-nic-internal"
  location            = azurerm_resource_group.cfd_rg.location
  resource_group_name = azurerm_resource_group.cfd_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.cfd_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface" "cfd_nic_public" {
  name                = "${local.prefix}-nic-public"
  resource_group_name = azurerm_resource_group.cfd_rg.name
  location            = azurerm_resource_group.cfd_rg.location

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.cfd_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.cfd_pip.id
  }
}

resource "azurerm_network_interface_security_group_association" "cfd_nic_nsg_assoc" {
  depends_on                = [azurerm_network_interface.cfd_nic_public, azurerm_network_security_group.cfd_nsg_ssh]
  network_interface_id      = azurerm_network_interface.cfd_nic_public.id
  network_security_group_id = azurerm_network_security_group.cfd_nsg_ssh.id
}

resource "azurerm_linux_virtual_machine" "cfd_vm" {
  depends_on            = [
    data.azurerm_key_vault_key.vm_key, 
	azurerm_network_interface.cfd_nic_public,
	azurerm_network_interface.cfd_nic_internal
  ] 
  name                  = "${local.prefix}-vm"
  resource_group_name   = azurerm_resource_group.cfd_rg.name
  location              = azurerm_resource_group.cfd_rg.location
  size                  = "Standard_D2s_v3"
  admin_username        = "mruser"
  
  network_interface_ids = [
    azurerm_network_interface.cfd_nic_public.id, 
	azurerm_network_interface.cfd_nic_internal.id
  ]

  admin_ssh_key {
    username   = "mruser"
    public_key = local.ssh_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}

resource "time_sleep" "wait_3_minutes" {
  depends_on = [azurerm_linux_virtual_machine.cfd_vm]

  create_duration = "180s"
}

resource "azurerm_virtual_machine_extension" "cfd_vm_extension" {
  depends_on            = [time_sleep.wait_3_minutes]
  name                 = "${local.prefix}-vm-ext"
  virtual_machine_id   = azurerm_linux_virtual_machine.cfd_vm.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.0"

  protected_settings = <<PROT
  {
      "script": "${base64encode(file(var.script))}"
  }
  PROT
}