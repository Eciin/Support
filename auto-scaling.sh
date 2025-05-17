#!/bin/bash

# vSphere connection configuration
VSPHERE_USER="${VSPHERE_USER:-i416434@fhict.local}"
VSPHERE_PASSWORD="${VSPHERE_PASSWORD:-Icw5F[MRci}"
VSPHERE_SERVER="${VSPHERE_SERVER:-vcenter.netlab.fontysict.nl}"

# vSphere environment settings
VSPHERE_DATACENTER="${VSPHERE_DATACENTER:-Netlab-DC}"
VSPHERE_CLUSTER="${VSPHERE_CLUSTER:-Netlab-Cluster-B}"
VSPHERE_RESOURCE_POOL="${VSPHERE_RESOURCE_POOL:-i416434}"
VSPHERE_DATASTORE="${VSPHERE_DATASTORE:-NIM01-9}"
VSPHERE_NETWORK="${VSPHERE_NETWORK:-0124_Internet-DHCP-192.168.124.0_24}"  
VSPHERE_TEMPLATE="${VSPHERE_TEMPLATE:-/Netlab-DC/vm/_Courses/I3-DB01/i416434/Templates/upscale}"  

# Auto-scaling configuration
MAX_LOAD="${MAX_LOAD:-70}"
MIN_LOAD="${MIN_LOAD:-30}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
MAX_SERVERS="${MAX_SERVERS:-10}"
MIN_SERVERS="${MIN_SERVERS:-1}"
VM_BASE_NAME="${VM_BASE_NAME:-webserver}"
APP_PORT="${APP_PORT:-80}"
LOAD_BALANCER_PORT="${LOAD_BALANCER_PORT:-8080}"
LOG_FILE="/tmp/auto-scaling.log"
VM_FOLDER="${VM_FOLDER:-/Netlab-DC/vm/_Courses/I3-DB01/i416434/autoscaling}"
NGINX_CONF="/etc/nginx/conf.d/load-balancer.conf"
SERVER_LIST_FILE="/tmp/server-list.txt"

echo "Auto-Scaling Script Started at $(date)" > $LOG_FILE

log_message() {
    echo "$(date): $1" | tee -a $LOG_FILE >&2
}

log_message "Initializing auto-scaling environment for vSphere"

check_dependencies() {
    log_message "Checking for required dependencies..."
    
    if ! command -v govc &> /dev/null; then
        log_message "Installing govc (vSphere CLI tool)..."
        curl -L -o /tmp/govc.tar.gz https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz
        mkdir -p /tmp/govc
        tar -xzf /tmp/govc.tar.gz -C /tmp/govc
        chmod +x /tmp/govc/govc
        sudo mv /tmp/govc/govc /usr/local/bin/
        rm -rf /tmp/govc /tmp/govc.tar.gz
    fi
    
    if ! command -v nginx &> /dev/null; then
        log_message "Installing nginx..."
        sudo apt-get update
        sudo apt-get install -y nginx
    fi
    
    if ! command -v stress &> /dev/null; then
        log_message "Installing stress tool for load testing..."
        sudo apt-get update
        sudo apt-get install -y stress
    fi
    
    if ! command -v sshpass &> /dev/null; then
        log_message "Installing sshpass for non-interactive SSH..."
        sudo apt-get update
        sudo apt-get install -y sshpass
    fi
    
    log_message "All dependencies installed."
}

setup_govc() {
    log_message "Setting up govc environment..."
    
    export GOVC_URL="https://$VSPHERE_SERVER"
    export GOVC_USERNAME="$VSPHERE_USER"
    export GOVC_PASSWORD="$VSPHERE_PASSWORD"
    export GOVC_INSECURE=true 
    export GOVC_DATACENTER="$VSPHERE_DATACENTER"
    export GOVC_RESOURCE_POOL="$VSPHERE_RESOURCE_POOL"
    export GOVC_DATASTORE="$VSPHERE_DATASTORE"
    export GOVC_NETWORK="$VSPHERE_NETWORK"
    
    if govc about &> /dev/null; then
        log_message "Successfully connected to vSphere server"
    else
        log_message "Failed to connect to vSphere server. Check credentials and connection."
        exit 1
    fi
}

get_vm_list() {
    govc ls "/$VM_FOLDER/" | grep $VM_BASE_NAME | grep -v "${VM_BASE_NAME}-lb" || echo ""
}

# Initialize or load the server list
init_server_list() {
    if [ ! -f "$SERVER_LIST_FILE" ]; then
        echo "vm_name,ip_address,status" > $SERVER_LIST_FILE
    fi
}

# Add a server to the list
add_server_to_list() {
    local vm_name=$1
    local ip=$2
    echo "$vm_name,$ip,active" >> $SERVER_LIST_FILE
}

# Remove a server from the list
remove_server_from_list() {
    local vm_name=$1
    sed -i "\|$vm_name|d" $SERVER_LIST_FILE
}

# Get all servers from the list
get_server_list() {
    if [ -f "$SERVER_LIST_FILE" ]; then
        tail -n +2 $SERVER_LIST_FILE
    fi
}

# Generate nginx configuration based on current server list
update_nginx_config() {
    log_message "Updating nginx load balancer configuration"
    
    # Get list of active server IPs
    local server_ips=()
    while IFS=, read -r vm_name ip status; do
        if [ "$status" = "active" ]; then
            server_ips+=("$ip")
        fi
    done < <(get_server_list)
    
    # Generate upstream server entries
    local upstream_entries=""
    for ip in "${server_ips[@]}"; do
        upstream_entries="${upstream_entries}    server ${ip}:${APP_PORT} max_fails=3 fail_timeout=30s;\n"
    done
    
    # If no servers, add a placeholder comment
    if [ ${#server_ips[@]} -eq 0 ]; then
        upstream_entries="    # No servers currently available\n"
    fi
    
    # Create nginx configuration
    sudo mkdir -p /etc/nginx/conf.d/
    sudo tee $NGINX_CONF > /dev/null << EOF
upstream app_servers {
    least_conn;
$(echo -e "$upstream_entries")
}

server {
    listen ${LOAD_BALANCER_PORT};
    
    location / {
        proxy_pass http://app_servers;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Server \$host;
        
        # Add this to disable caching for better load balancer demonstration
        add_header Cache-Control "no-store, no-cache, must-revalidate, post-check=0, pre-check=0";
        expires -1;
    }
    
    # Simple load balancer status page
    location /lb-status {
        default_type text/html;
        return 200 '<html><head><title>Load Balancer</title></head><body><h1>Load Balancer Status</h1><p>Load Balancer is running with ${#server_ips[@]} active servers</p><p><a href="/">Go to Web Application</a></p></body></html>';
    }
    
    # Health check endpoint
    location /health {
        default_type text/plain;
        return 200 'Load balancer is healthy\n';
    }
}
EOF

    # Reload nginx
    sudo systemctl reload nginx || sudo systemctl restart nginx
    
    log_message "Nginx configuration updated with ${#server_ips[@]} servers"
}

create_vm() {
    local vm_num=$1
    local vm_name="${VM_BASE_NAME}-${vm_num}"
    local vm_path="/$VM_FOLDER/$vm_name"
    
    log_message "Creating new VM: $vm_name (will get dynamic IP from DHCP)"
    
    # Clone the VM with DHCP
    govc vm.clone -vm "$VSPHERE_TEMPLATE" -on=true -template=false \
        -ds="$VSPHERE_DATASTORE" -pool="$VSPHERE_RESOURCE_POOL" \
        -folder="$VM_FOLDER" \
        -c=2 -m=4096 \
        -net="$VSPHERE_NETWORK" \
        "$vm_name"
    
    if [ $? -ne 0 ]; then
        log_message "Failed to clone VM. Check template path and permissions."
        return 1
    fi
    
    # Wait for VM to get an IP (shorter timeout)
    log_message "Waiting for VM $vm_name to boot and get an IP address..."
    local vm_ip=""
    for i in {1..20}; do
        vm_ip=$(govc vm.ip "$vm_path" 2>/dev/null)
        if [[ $vm_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            log_message "VM obtained IP: $vm_ip"
            break
        fi
        log_message "Waiting for IP address... attempt $i/20"
        sleep 10
        
        if [ $i -eq 20 ]; then
            log_message "Could not get VM IP address after 20 attempts. Aborting."
            govc vm.destroy "$vm_path"
            return 1
        fi
    done
    
    # Wait for SSH (shorter timeout)
    log_message "Waiting for SSH to be available on $vm_ip..."
    for i in {1..15}; do
        if sshpass -p "student" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 student@$vm_ip "echo SSH is up" &> /dev/null; then
            log_message "SSH is available after $i attempts"
            break
        fi
        
        log_message "Attempt $i/15: Waiting for SSH..."
        sleep 5
        
        if [ $i -eq 15 ]; then
            log_message "Failed to connect via SSH after 15 attempts. Aborting."
            govc vm.destroy "$vm_path"
            return 1
        fi
    done
    
    # Configure the new webserver
    log_message "Configuring webserver $vm_name with IP $vm_ip..."
    
    # Create a temporary configuration script
    cat > /tmp/configure-webserver-$vm_num.sh << EOF
#!/bin/bash
# Update and install packages
echo 'student' | sudo -S apt-get update
echo 'student' | sudo -S apt-get install -y nginx ufw

# Create the custom HTML file
cat << INNEREOF | sudo tee /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
    <title>Web Server $vm_num</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            text-align: center;
            margin-top: 50px;
            background-color: $([ $vm_num -eq 1 ] && echo "#f0f8ff" || [ $vm_num -eq 2 ] && echo "#ffe4e1" || [ $vm_num -eq 3 ] && echo "#f0fff0" || [ $vm_num -eq 4 ] && echo "#fff8dc" || echo "#e6e6fa");
        }
        .container {
            background-color: white;
            border-radius: 10px;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
            padding: 20px;
            display: inline-block;
            min-width: 400px;
        }
        h1 {
            color: $([ $vm_num -eq 1 ] && echo "#4682b4" || [ $vm_num -eq 2 ] && echo "#cd5c5c" || [ $vm_num -eq 3 ] && echo "#2e8b57" || [ $vm_num -eq 4 ] && echo "#daa520" || echo "#9370db");
        }
        .server-info {
            margin: 20px;
            font-size: 18px;
        }
        .timestamp {
            font-size: 14px;
            color: gray;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <div class='container'>
        <h1>Web Server $vm_num</h1>
        <div class='server-info'>
            <p><strong>Server Name:</strong> ${VM_BASE_NAME}-$vm_num</p>
            <p><strong>Server IP:</strong> $vm_ip</p>
            <p><strong>Unique ID:</strong> $vm_num</p>
        </div>
        <div class='timestamp'>
            <p>Page loaded at: <span id='timestamp'></span></p>
        </div>
    </div>
    <script>
        document.getElementById('timestamp').textContent = new Date().toLocaleString();
        // Refresh the page every 5 seconds to demonstrate load balancing
        setTimeout(function() {
            window.location.reload();
        }, 5000);
    </script>
</body>
</html>
INNEREOF

# Configure UFW firewall
echo 'student' | sudo -S ufw allow 22/tcp comment 'Allow SSH'
echo 'student' | sudo -S ufw allow 80/tcp comment 'Allow HTTP'
echo 'student' | sudo -S ufw allow 443/tcp comment 'Allow HTTPS'
echo 'student' | sudo -S ufw allow 8080/tcp comment 'Allow alternate HTTP port'

# Enable UFW non-interactively
echo 'student' | sudo -S bash -c 'echo "y" | ufw enable'
echo 'student' | sudo -S ufw status

# Start and enable nginx
echo 'student' | sudo -S systemctl enable nginx
echo 'student' | sudo -S systemctl restart nginx

# Report success
echo "Webserver $vm_num configuration completed successfully with IP $vm_ip"
EOF
    
    # Copy and execute the configuration script on the new VM
    sshpass -p "student" scp -o StrictHostKeyChecking=no /tmp/configure-webserver-$vm_num.sh student@$vm_ip:/tmp/
    sshpass -p "student" ssh -o StrictHostKeyChecking=no student@$vm_ip "chmod +x /tmp/configure-webserver-$vm_num.sh && /tmp/configure-webserver-$vm_num.sh"
    
    if [ $? -ne 0 ]; then
        log_message "Failed to configure webserver $vm_name. VM may not be set up correctly."
        return 1
    else
        log_message "Successfully configured webserver $vm_name with IP $vm_ip"
    fi
    
    # Clean up
    rm -f /tmp/configure-webserver-$vm_num.sh
    
    # Verify webserver is responding
    log_message "Verifying webserver is accessible at IP $vm_ip..."
    if check_vm_web_service $vm_ip; then
        log_message "Webserver $vm_name is responding correctly at $vm_ip"
        
        # Add the server to our list and update nginx
        add_server_to_list "$vm_name" "$vm_ip"
        update_nginx_config
        
        # Return the IP address to the caller
        echo $vm_ip
        return 0
    else
        log_message "Webserver $vm_name is not responding at $vm_ip. Aborting."
        govc vm.destroy "$vm_path"
        return 1
    fi
}

delete_vm() {
    local vm_path=$1
    local vm_name=$(basename "$vm_path")
    
    log_message "Deleting VM: $vm_path"
    
    govc vm.power -off "$vm_path"
    govc vm.destroy "$vm_path"
    
    if [ $? -eq 0 ]; then
        log_message "VM $vm_path deleted successfully"
        # Remove from server list and update nginx
        remove_server_from_list "$vm_name"
        update_nginx_config
        return 0
    else
        log_message "Failed to delete VM $vm_path"
        return 1
    fi
}

get_cpu_load() {
    top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4)}'
}

setup_load_balancer() {
    log_message "Setting up initial load balancer configuration"
    update_nginx_config
}

check_vm_web_service() {
    local vm_ip=$1
    local timeout=5
    
    if curl -s --connect-timeout $timeout "http://${vm_ip}:${APP_PORT}" > /dev/null; then
        return 0
    else
        return 1
    fi
}

update_server_status() {
    local vm_name=$1
    local ip=$2
    local status=$3
    
    sed -i "s/^$vm_name,$ip,[^,]*/$vm_name,$ip,$status/" $SERVER_LIST_FILE
}

# Function to scale up - create a new VM
scale_up() {
    local vm_list=$(get_vm_list)
    local current_vms=$(echo "$vm_list" | grep -v "^$" | wc -l)
    local next_vm_num=$((current_vms + 1))
    
    if [ $next_vm_num -gt $MAX_SERVERS ]; then
        log_message "Cannot scale up. Maximum number of servers ($MAX_SERVERS) reached."
        return 0
    fi
    
    log_message "Scaling up to $next_vm_num servers"
    
    local vm_ip=$(create_vm $next_vm_num)
    
    if [ -n "$vm_ip" ]; then
        log_message "Scale up complete: ${VM_BASE_NAME}-${next_vm_num} ($vm_ip) added to pool"
    else
        log_message "Failed to create new VM. Scale up aborted."
    fi
}

scale_down() {
    local vm_list=$(get_vm_list)
    local current_vms=$(echo "$vm_list" | grep -v "^$" | wc -l)
    
    if [ $current_vms -le $MIN_SERVERS ]; then
        log_message "Cannot scale down. Minimum number of servers ($MIN_SERVERS) reached."
        return 0
    fi
    
    log_message "Scaling down from $current_vms servers"
    
    # Find the highest-numbered VM (not webserver-1)
    local vm_to_delete=""
    local highest_number=0
    
    for vm in $vm_list; do
        # Extract the VM number from the name
        vm_name=$(basename "$vm")
        vm_number=$(echo "$vm_name" | grep -o '[0-9]\+$')
        
        # Skip webserver-1
        if [ "$vm_number" = "1" ]; then
            continue
        fi
        
        # Find the VM with the highest number
        if [ "$vm_number" -gt "$highest_number" ]; then
            highest_number=$vm_number
            vm_to_delete=$vm
        fi
    done
    
    # If we found a VM to delete
    if [ -n "$vm_to_delete" ]; then
        log_message "Selected VM to delete: $vm_to_delete (number: $highest_number)"
        delete_vm "$vm_to_delete"
        log_message "Scale down complete"
    else
        log_message "No suitable VM found for deletion. All remaining VMs are essential."
    fi
}

get_system_load() {
    if [ -f /tmp/simulated_load ]; then
        cat /tmp/simulated_load
    else
        get_cpu_load
    fi
}

check_servers() {
    log_message "Checking server pool health..."
    
    local update_needed=0
    while IFS=, read -r vm_name ip status; do
        # Skip header line
        if [ "$vm_name" = "vm_name" ]; then
            continue
        fi
        
        if check_vm_web_service $ip; then
            # Update status to active if it wasn't
            if [ "$status" != "active" ]; then
                update_server_status "$vm_name" "$ip" "active"
                update_needed=1
            fi
        else
            # Update status to inactive if it wasn't
            if [ "$status" != "inactive" ]; then
                update_server_status "$vm_name" "$ip" "inactive"
                update_needed=1
            fi
        fi
    done < $SERVER_LIST_FILE
    
    # Update nginx if needed
    if [ $update_needed -eq 1 ]; then
        update_nginx_config
    fi
}

monitor_load() {
    log_message "Starting load monitoring..."
    
    local check_health_counter=0
    
    while true; do
        CURRENT_LOAD=$(get_system_load)
        
        local vm_list=$(get_vm_list)
        local CURRENT_SERVERS=$(echo "$vm_list" | grep -v "^$" | wc -l)
        
        log_message "Current load: $CURRENT_LOAD%, Running servers: $CURRENT_SERVERS"
        
        check_health_counter=$((check_health_counter + 1))
        if [ $check_health_counter -ge 12 ]; then
            check_servers
            check_health_counter=0
        fi
        
        if [ $CURRENT_LOAD -gt $MAX_LOAD ] && [ $CURRENT_SERVERS -lt $MAX_SERVERS ]; then
            scale_up
        fi
        
        if [ $CURRENT_LOAD -lt $MIN_LOAD ] && [ $CURRENT_SERVERS -gt $MIN_SERVERS ]; then
            scale_down
        fi
        
        sleep $CHECK_INTERVAL
    done
}

test_load_balancing() {
    log_message "Testing load balancing..."
    
    for i in {1..10}; do
        echo "Request $i:"
        curl -s "http://localhost:${LOAD_BALANCER_PORT}/" | grep -o '<h1>Web Server [0-9]</h1>'
        sleep 1
    done
}

# Main execution
check_dependencies
setup_govc
init_server_list

if ! govc ls "/$VM_FOLDER" &>/dev/null; then
    log_message "VM folder /$VM_FOLDER not found. Please check your folder name."
    exit 1
fi

if ! govc ls "$VSPHERE_TEMPLATE" &>/dev/null; then
    log_message "Template $VSPHERE_TEMPLATE not found. Please check the template path."
    exit 1
fi

setup_load_balancer

EXISTING_VMS=$(get_vm_list | grep $VM_BASE_NAME)

if [ -z "$EXISTING_VMS" ]; then
    log_message "No existing servers found. Creating initial server..."
    scale_up
else
    log_message "Found existing servers. Recording in server list."
    
    for vm in $EXISTING_VMS; do
        vm_ip=$(govc vm.ip "$vm" 2>/dev/null)
        if [ -n "$vm_ip" ]; then
            vm_name=$(basename "$vm")
            add_server_to_list "$vm_name" "$vm_ip"
            log_message "Recorded existing server $vm_name ($vm_ip)"
        fi
    done
    
    # Update nginx with found servers
    update_nginx_config
fi

if [ "$1" = "test-lb" ]; then
    log_message "Running load balancer test..."
    test_load_balancing
    exit 0
fi

log_message "Starting load monitoring in background..."
monitor_load &
MONITOR_PID=$!

echo $MONITOR_PID > auto-scaling.pid

log_message "Setup complete. Auto-scaling system is now running."