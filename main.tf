provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

# Local variables for use in this configuration
locals {
  vm_folder           = "_Courses/I3-DB01/i416434/autoscaling"
  vm_base_name        = "webserver"
  initial_server_count = 1
  cpu_count           = 2
  memory              = 4096
}

# Load Balancer VM
resource "vsphere_virtual_machine" "load_balancer" {
  name             = "${local.vm_base_name}-lb"
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id
  folder           = local.vm_folder
  
  num_cpus         = local.cpu_count
  memory           = local.memory
  guest_id         = data.vsphere_virtual_machine.Server.guest_id
  scsi_type        = data.vsphere_virtual_machine.Server.scsi_type
  
  network_interface {
    network_id   = data.vsphere_network.static_network_internet.id
    adapter_type = data.vsphere_virtual_machine.Server.network_interface_types[0]
  }
  
  disk {
    label            = "disk0"
    size             = data.vsphere_virtual_machine.Server.disks.0.size
    eagerly_scrub    = data.vsphere_virtual_machine.Server.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.Server.disks.0.thin_provisioned
  }
  
  clone {
    template_uuid = data.vsphere_virtual_machine.Server.id
    
    customize {
      linux_options {
        host_name = "${local.vm_base_name}-lb"
        domain    = "local"
      }
      
      network_interface {
        ipv4_address = "192.168.154.135"
        ipv4_netmask = 24        
      }
      ipv4_gateway    = "192.168.154.1"
      dns_server_list = ["192.168.200.10"]      
    }
  }
  
  # Install and configure load balancer
  provisioner "file" {
    source      = "auto-scaling.sh"
    destination = "/tmp/auto-scaling.sh"
    
    connection {
      type        = "ssh"
      user        = "student"
      password    = "student"
      host        = self.default_ip_address
    }
  }
  
  provisioner "remote-exec" {
    inline = [
      "echo 'student' | sudo -S chmod +x /tmp/auto-scaling.sh",
      "echo 'student' | sudo -S bash -c \"export VSPHERE_USER='${var.vsphere_user}'\"",
      "echo 'student' | sudo -S bash -c \"export VSPHERE_PASSWORD='${var.vsphere_password}'\"",
      "echo 'student' | sudo -S bash -c \"export VSPHERE_SERVER='${var.vsphere_server}'\"",
      "echo 'student' | sudo -S bash -c \"export VM_FOLDER='${local.vm_folder}'\"",
      "echo 'student' | sudo -S bash -c \"export VM_BASE_NAME='${local.vm_base_name}'\"",
      "echo 'student' | sudo -S bash -c \"nohup bash /tmp/auto-scaling.sh > /tmp/auto-scaling-init.log 2>&1 &\"",
      "echo 'student' | sudo -S ufw allow 22/tcp comment 'Allow SSH'",
      "echo 'student' | sudo -S ufw allow 80/tcp comment 'Allow HTTP'",
      "echo 'student' | sudo -S ufw allow 443/tcp comment 'Allow HTTPS'",
      "echo 'student' | sudo -S ufw allow 8080/tcp comment 'Allow alternate HTTP port'",
      "sleep 5"
    ]
    
    connection {
      type        = "ssh"
      user        = "student"
      password    = "student"
      host        = self.default_ip_address
    }
  }
}

# Web server VMs - initial pool
resource "vsphere_virtual_machine" "webserver" {
  count            = local.initial_server_count
  name             = "${local.vm_base_name}-${count.index + 1}"
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.datastore.id
  folder           = local.vm_folder
  
  num_cpus         = local.cpu_count
  memory           = local.memory
  guest_id         = data.vsphere_virtual_machine.Webserver.guest_id
  scsi_type        = data.vsphere_virtual_machine.Webserver.scsi_type
  
  network_interface {
    network_id   = data.vsphere_network.static_network_internet.id
    adapter_type = data.vsphere_virtual_machine.Webserver.network_interface_types[0]
  }
  
  disk {
    label            = "disk0"
    size             = data.vsphere_virtual_machine.Webserver.disks.0.size
    eagerly_scrub    = data.vsphere_virtual_machine.Webserver.disks.0.eagerly_scrub
    thin_provisioned = data.vsphere_virtual_machine.Webserver.disks.0.thin_provisioned
  }
  
  clone {
    template_uuid = data.vsphere_virtual_machine.Webserver.id
    
    customize {
      linux_options {
        host_name = "${local.vm_base_name}-${count.index + 1}"
        domain    = "local"
      }
      
      network_interface {
        ipv4_address = "192.168.154.137"
        ipv4_netmask = 24          
      }
      ipv4_gateway    = "192.168.154.1"
      dns_server_list = ["192.168.200.10"]      
    }
  }
  
  # Install and configure web server with UFW
  provisioner "remote-exec" {
    inline = [
      "echo 'student' | sudo -S apt-get update",
      "echo 'student' | sudo -S apt-get install -y nginx ufw",
      "echo 'student' | sudo -S mkdir -p /var/www/html",
      
      # Create a more distinctive website for each server 
      "cat << EOF | sudo tee /var/www/html/index.html",
      "<!DOCTYPE html>",
      "<html>",
      "<head>",
      "    <title>Web Server ${count.index + 1}</title>",
      "    <style>",
      "        body {",
      "            font-family: Arial, sans-serif;",
      "            text-align: center;",
      "            margin-top: 50px;",
      "            background-color: ${count.index == 0 ? "#f0f8ff" : count.index == 1 ? "#ffe4e1" : count.index == 2 ? "#f0fff0" : count.index == 3 ? "#fff8dc" : "#e6e6fa"};",
      "        }",
      "        .container {",
      "            background-color: white;",
      "            border-radius: 10px;",
      "            box-shadow: 0 0 10px rgba(0,0,0,0.1);",
      "            padding: 20px;",
      "            display: inline-block;",
      "            min-width: 400px;",
      "        }",
      "        h1 {",
      "            color: ${count.index == 0 ? "#4682b4" : count.index == 1 ? "#cd5c5c" : count.index == 2 ? "#2e8b57" : count.index == 3 ? "#daa520" : "#9370db"};",
      "        }",
      "        .server-info {",
      "            margin: 20px;",
      "            font-size: 18px;",
      "        }",
      "        .timestamp {",
      "            font-size: 14px;",
      "            color: gray;",
      "            margin-top: 20px;",
      "        }",
      "    </style>",
      "</head>",
      "<body>",
      "    <div class='container'>",
      "        <h1>Web Server ${count.index + 1}</h1>",
      "        <div class='server-info'>",
      "            <p><strong>Server Name:</strong> ${local.vm_base_name}-${count.index + 1}</p>",
      "            <p><strong>Server IP:</strong> <span id='server-ip'></span></p>",
      "            <p><strong>Unique ID:</strong> ${count.index + 1}</p>",
      "        </div>",
      "        <div class='timestamp'>",
      "            <p>Page loaded at: <span id='timestamp'></span></p>",
      "        </div>",
      "    </div>",
      "    <script>",
      "        document.getElementById('server-ip').textContent = location.hostname;",
      "        document.getElementById('timestamp').textContent = new Date().toLocaleString();",
      "        // Refresh the page every 5 seconds to demonstrate load balancing",
      "        setTimeout(function() {",
      "            window.location.reload();",
      "        }, 5000);",
      "    </script>",
      "</body>",
      "</html>",
      "EOF",
      
      # Configure UFW
      "echo 'student' | sudo -S ufw allow 22/tcp comment 'Allow SSH'",
      "echo 'student' | sudo -S ufw allow 80/tcp comment 'Allow HTTP'",
      "echo 'student' | sudo -S ufw allow 443/tcp comment 'Allow HTTPS'",
      "echo 'student' | sudo -S ufw allow 8080/tcp comment 'Allow alternate HTTP port'",
      
      # Enable UFW non-interactively
      "echo 'student' | sudo -S bash -c 'echo \"y\" | ufw enable'",
      "echo 'student' | sudo -S ufw status",
      
      # Configure and start nginx
      "echo 'student' | sudo -S systemctl enable nginx",
      "echo 'student' | sudo -S systemctl restart nginx"
    ]
    
    connection {
      type        = "ssh"
      user        = "student"
      password    = "student"
      host        = self.default_ip_address
    }
  }
  
  # Wait for the load balancer VM to be created first
  depends_on = [vsphere_virtual_machine.load_balancer]
}

# Output information
output "load_balancer_ip" {
  value = vsphere_virtual_machine.load_balancer.default_ip_address
  description = "IP address of the load balancer"
}

output "webserver_ips" {
  value = {
    for idx, server in vsphere_virtual_machine.webserver : 
    server.name => server.default_ip_address
  }
  description = "IP addresses of the web servers"
}