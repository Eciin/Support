data "vsphere_datacenter" "dc" {
  name = "Netlab-DC"
}
 
data "vsphere_compute_cluster" "cluster" {
  name          = "Netlab-Cluster-B"
  datacenter_id = data.vsphere_datacenter.dc.id
}
 
data "vsphere_resource_pool" "pool" {
  name          = "i416434"
  datacenter_id = data.vsphere_datacenter.dc.id
}
 
data "vsphere_datastore" "datastore" {
  name          = "NIM01-9"
  datacenter_id = data.vsphere_datacenter.dc.id
}
 
data "vsphere_network" "dynamic_network_internet" {
  name          = "0124_Internet-DHCP-192.168.124.0_24"
  datacenter_id = data.vsphere_datacenter.dc.id
}
 
data "vsphere_network" "static_network_internet" {
  name          = "0154_Internet-Static-192.168.154.0_24"
  datacenter_id = data.vsphere_datacenter.dc.id
}
data "vsphere_virtual_machine" "Server" {
  name          = "_Courses/I3-DB01/i416434/Templates/Server"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "Desktop" {
  name          = "_Courses/I3-DB01/i416434/Templates/Desktop"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "Webserver" {
  name          = "_Courses/I3-DB01/i416434/Templates/Server"
  datacenter_id = data.vsphere_datacenter.dc.id
}

