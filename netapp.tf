resource "azurerm_netapp_account" "jhub" {
  count = var.enable_netapp ? 1 : 0
  name                = "${local.cluster_name}-netapp"
  location            = azurerm_resource_group.jhub.location
  resource_group_name = azurerm_resource_group.jhub.name
}

resource "azurerm_netapp_pool" "jhub" {
  count = var.enable_netapp ? 1 : 0
  name                = "${local.cluster_name}-netapppool"
  account_name        = azurerm_netapp_account.jhub[0].name
  location            = azurerm_resource_group.jhub.location
  resource_group_name = azurerm_resource_group.jhub.name
  service_level       = "Premium"
  size_in_tb          = 4
}

resource "azurerm_virtual_network" "netapp_vnet" {
  address_space = ["10.7.0.0/16"]
  location = azurerm_resource_group.jhub.location
  name = "${local.cluster_name}-netapp-vnet"
  resource_group_name = azurerm_resource_group.jhub.name
}

resource "azurerm_subnet" "netapp_subnet" {
  name = "${local.cluster_name}-netapp-subnet"
  resource_group_name = azurerm_resource_group.jhub.name
  virtual_network_name = azurerm_virtual_network.netapp_vnet.name
  address_prefixes = ["10.7.0.0/24"]
  delegation {
	name = "${local.cluster_name}-netapp-subnet-delegation"
	service_delegation {
	  name = "Microsoft.Netapp/volumes"
	}
  }
}

resource "null_resource" "wait_for_k8s" {
  depends_on = [azurerm_kubernetes_cluster.jhub]
  provisioner "local-exec" {
	command = "sleep 90"
  }
}

provider "kubernetes" {
  config_context = azurerm_kubernetes_cluster.jhub.name
}

resource "kubernetes_namespace" "trident" {
  metadata {
	name = "trident"
  }

  provisioner "local-exec" {
	when = destroy
	command = "tridentctl obliviate crd --yesireallymeanit"
	on_failure = "continue"
  }

  depends_on = [null_resource.wait_for_k8s]
}

resource "null_resource" "trident_crd" {
  provisioner "local-exec" {
	command = "kubectl create -f trident/trident.netapp.io_tridentprovisioners_crd_post1.16.yaml"
  }
  depends_on = [kubernetes_namespace.trident]
}

resource "null_resource" "trident_bundle" {
  provisioner "local-exec" {
	command = "kubectl create -f trident/bundle.yaml"
  }
  depends_on = [null_resource.trident_crd]
}

resource "null_resource" "trident_provisioner_cr" {
  provisioner "local-exec" {
	command = "kubectl create -f trident/tridentprovisioner_cr.yaml"
  }
  depends_on = [null_resource.trident_bundle]
}

resource "null_resource" "wait_for_trident_pod" {
  depends_on = [null_resource.trident_bundle]
  provisioner "local-exec" {
	command = "sleep 90"
  }
}

locals {
  trident_backend_json = jsonencode({
	"version": 1,
	"storageDriverName": "azure-netapp-files",
	"subscriptionID": var.subscription_id,
	"tenantID": var.tenant_id,
	"clientID": var.kubernetes_client_id,
	"clientSecret": var.kubernetes_client_secret,
	"location": var.location,
	"serviceLevel": "Premium",
	"virtualNetwork": azurerm_virtual_network.netapp_vnet.name,
	"subnet": azurerm_subnet.netapp_subnet.name,
	"nfsMountOptions": "vers=3,proto=tcp,timeo=600",
	"limitVolumeSize": "500Gi",
	"defaults": {
	  "exportRule": "10.0.0.0/16",
	  "size": "200Gi"
	}
  })
}

resource "null_resource" "trident_provisioner_backend" {
  provisioner "local-exec" {
	command = "echo '${local.trident_backend_json}' | tridentctl -n trident create backend -f -"
  }

  depends_on = [null_resource.wait_for_trident_pod]
}

resource "kubernetes_storage_class" "netapp_storage_class" {
  storage_provisioner = "csi.trident.netapp.io"
  parameters = {
	backendType = "azure-netapp-files"
  }
  metadata {
	name = "netapp"
  }

  depends_on = [null_resource.trident_provisioner_backend]
}
