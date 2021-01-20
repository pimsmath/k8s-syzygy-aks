terraform {
  # The configuration for this backend will be filled in by Terragrunt
  backend "s3" {
  }
}

terraform {
  required_version = ">= 0.12.0"
}

# This is necessary for the state file
provider "aws" {
  region = "ca-central-1"
   version = ">=2.35"
}

provider "azurerm" {
  version = ">=2.20.0"
  subscription_id = var.subscription_id
  client_id       = var.kubernetes_client_id
  client_secret   = var.kubernetes_client_secret
  tenant_id       = var.tenant_id
  features {}
}

provider "random" {
  version = "~> 2.2"
}

provider "local" {
  version = "~> 1.2"
}

provider "null" {
  version = "~> 2.1"
}

provider "template" {
  version = "~> 2.1"
}

locals {
  cluster_name = "syzygy-aks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length = 8
  special = false
}

resource "azurerm_resource_group" "jhub" {
  name     = "${local.cluster_name}-k8s-resources"
  location = var.location
}

resource "azurerm_kubernetes_cluster" "jhub" {
  name                = local.cluster_name
  location            = azurerm_resource_group.jhub.location
  resource_group_name = azurerm_resource_group.jhub.name
  dns_prefix          = "${var.prefix}-k8s"

  default_node_pool {
	name            = "default"
	node_count      = 3
	vm_size    	    = var.node_size
	os_disk_size_gb = 30
  }

  service_principal {
    client_id     = var.kubernetes_client_id
    client_secret = var.kubernetes_client_secret
  }

  tags = {
    Environment = "Production"
  }

  provisioner "local-exec" {
	command = "az aks get-credentials --resource-group ${azurerm_kubernetes_cluster.jhub.resource_group_name} --name ${azurerm_kubernetes_cluster.jhub.name}"
  }
}
