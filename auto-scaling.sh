#!/bin/bash

VSPHERE_USER="${VSPHERE_USER:-i416434@fhict.local}"
VSPHERE_PASSWORD="${VSPHERE_PASSWORD:-Icw5F[MRci}"
VSPHERE_SERVER="${VSPHERE_SERVER:-vcenter.netlab.fontysict.nl}"

VSPHERE_DATACENTER="${VSPHERE_DATACENTER:-Netlab-DC}"
VSPHERE_CLUSTER="${VSPHERE_CLUSTER:-Netlab-Cluster-B}"
VSPHERE_RESOURCE_POOL="${VSPHERE_RESOURCE_POOL:-i416434}"
VSPHERE_DATASTORE="${VSPHERE_DATASTORE:-NIM01-9}"
VSPHERE_NETWORK="${VSPHERE_NETWORK:-0124_Internet-DHCP-192.168.124.0_24}"  
VSPHERE_TEMPLATE="${VSPHERE_TEMPLATE:-/Netlab-DC/vm/_Courses/I3-DB01/i416434/Templates/upscale}"  

MAX_LOAD="${MAX_LOAD:-70}"
MIN_LOAD="${MIN_LOAD:-30}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
MAX_SERVERS="${MAX_SERVERS:-5}"
MIN_SERVERS="${MIN_SERVERS:-1}"
VM_BASE_NAME="${VM_BASE_NAME:-webserver}"
APP_PORT="${APP_PORT:-80}"
LOAD_BALANCER_PORT="${LOAD_BALANCER_PORT:-8080}"
LOG_FILE="${LOG_FILE:-auto-scaling.log}" 
VM_FOLDER="${VM_FOLDER:-/Netlab-DC/vm/_Courses/I3-DB01/i416434/autoscaling}"

echo "Auto-Scaling Script Started at $(date)" > $LOG_FILE

log_message() {
    echo "$(date): $1" | tee -a $LOG_FILE
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
    govc ls /$VM_FOLDER/ | grep $VM_BASE_NAME | grep -v "${VM_BASE_NAME}-lb" || echo ""
}

create_vm() {
    local vm_num=$1
    local vm_name="${VM_BASE_NAME}-${vm_num}"
    local vm_path="/$VM_FOLDER/$vm_name"
    
    log_message "Creating new VM: $vm_name by cloning template $VSPHERE_TEMPLATE"
    
govc vm.clone -vm "/$VSPHERE_TEMPLATE" -on=true -template=false -ds="$VSPHERE_DATASTORE" -pool="$VSPHERE_RESOURCE_POOL" -folder="$VM_FOLDER" "$vm_name"
    
    if [ $? -ne 0 ]; then
        log_message "Failed to clone VM. Check template path and permissions."
        return 1
    fi
    
    local max_attempts=100
    local attempts=0
    local vm_ip=""
    
    log_message "Waiting for VM $vm_name to get an IP address..."
    
    while [ -z "$vm_ip" ] && [ $attempts -lt $max_attempts ]; do
        sleep 10
        attempts=$((attempts + 1))
        vm_ip=$(govc vm.ip "$vm_path" 2>/dev/null)
        log_message "Attempt $attempts: VM IP check - $vm_ip"
    done
    
    if [ -z "$vm_ip" ]; then
        log_message "Failed to get IP for VM $vm_name after $max_attempts attempts"
        return 1
    fi
    
    log_message "VM $vm_name created with IP: $vm_ip"
    echo "$vm_ip"
}

delete_vm() {
    local vm_path=$1
    
    log_message "Deleting VM: $vm_path"
    
    govc vm.power -off "$vm_path"
    
    govc vm.destroy "$vm_path"
    
    if [ $? -eq 0 ]; then
        log_message "VM $vm_path deleted successfully"
    else
        log_message "Failed to delete VM $vm_path"
    fi
}

get_cpu_load() {
    top -bn1 | grep "Cpu(s)" | awk '{print int($2 + $4)}'
}

setup_load_balancer() {
    log_message "Setting up load balancer configuration"
    
    sudo mkdir -p /etc/nginx/conf.d/
    sudo tee /etc/nginx/conf.d/load-balancer.conf > /dev/null << EOF
upstream app_servers {
    least_conn;
    server 127.0.0.1:80 down;
    # Servers will be added dynamically
}

server {
    listen ${LOAD_BALANCER_PORT};
    
    location / {
        proxy_pass http://app_servers;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
    
    # Health check endpoint
    location /health {
        return 200 'Load balancer is healthy\n';
    }
}
EOF

    echo "server_name,ip_address,status" > servers.txt
    
    sudo systemctl restart nginx >> $LOG_FILE 2>&1 || {
        log_message "Failed to reload nginx. Check if it's installed and running."
        exit 1
    }
    
    log_message "Load balancer configured on port $LOAD_BALANCER_PORT"
}

add_server_to_lb() {
    local vm_ip=$1
    
    log_message "Adding server $vm_ip to load balancer"
    
    if grep -q "$vm_ip:$APP_PORT" /etc/nginx/conf.d/load-balancer.conf; then
        log_message "Server $vm_ip already in load balancer configuration"
        return 0
    fi
    
    sudo sed -i "/upstream app_servers {/a\\    server ${vm_ip}:${APP_PORT};" /etc/nginx/conf.d/load-balancer.conf
    
    sudo nginx -s reload >> $LOG_FILE 2>&1 || {
        log_message "Failed to reload nginx after adding server $vm_ip"
        return 1
    }
    
    log_message "Server $vm_ip added to load balancer"
    return 0
}

remove_server_from_lb() {
    local vm_ip=$1
    
    log_message "Removing server $vm_ip from load balancer"
    
    sudo sed -i "\|server ${vm_ip}:${APP_PORT};|d" /etc/nginx/conf.d/load-balancer.conf
    
    sudo nginx -s reload >> $LOG_FILE 2>&1 || {
        log_message "Failed to reload nginx after removing server $vm_ip"
        return 1
    }
    
    log_message "Server $vm_ip removed from load balancer"
    return 0
}

check_vm_web_service() {
    local vm_ip=$1
    local timeout=5
    
    log_message "Checking if $vm_ip web service is responding..."
    
    if curl -s --connect-timeout $timeout "http://${vm_ip}:${APP_PORT}" > /dev/null; then
        log_message "Web service on $vm_ip is responding"
        return 0
    else
        log_message "Web service on $vm_ip is not responding"
        return 1
    fi
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
        echo "${VM_BASE_NAME}-${next_vm_num},$vm_ip,active" >> servers.txt
        
        log_message "Waiting for web service to start on $vm_ip..."
        sleep 30
        
        if check_vm_web_service $vm_ip; then
            add_server_to_lb $vm_ip
            log_message "Scale up complete: ${VM_BASE_NAME}-${next_vm_num} ($vm_ip) added to pool"
        else
            log_message "Web service not responding on new VM. Will try again later."
            sed -i "s/${VM_BASE_NAME}-${next_vm_num},$vm_ip,active/${VM_BASE_NAME}-${next_vm_num},$vm_ip,pending/" servers.txt
        fi
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
    
    local last_vm=$(echo "$vm_list" | tail -1)
    
    local last_vm_ip=$(govc vm.ip "$last_vm" 2>/dev/null)
    
    if [ -z "$last_vm_ip" ]; then
        log_message "Could not get IP for VM $last_vm. Trying to delete anyway."
    else
        remove_server_from_lb $last_vm_ip
    fi
    
    delete_vm "$last_vm"
    
    local vm_name=$(basename "$last_vm")
    sed -i "\|$vm_name|d" servers.txt
    
    log_message "Scale down complete: $vm_name removed from pool"
}

simulate_load() {
    log_message "Starting load simulation for demonstration"
    
    for i in {1..3}; do
        echo "75" > /tmp/simulated_load
        log_message "Simulated load increased to 75% (should trigger scale up)"
        sleep 90
        
        echo "25" > /tmp/simulated_load
        log_message "Simulated load decreased to 25% (should trigger scale down)"
        sleep 90
    done
    
    rm -f /tmp/simulated_load
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
    
    local lb_servers=$(grep "server" /etc/nginx/conf.d/load-balancer.conf | grep -v "127.0.0.1" | awk '{print $2}' | cut -d: -f1)

    for server_ip in $lb_servers; do
        if ! check_vm_web_service $server_ip; then
            log_message "Server $server_ip not responding. Removing from load balancer."
            remove_server_from_lb $server_ip
            
            sed -i "s/,[^,]*,$server_ip,active/,$server_ip,failed/" servers.txt
        fi
    done
    
    while IFS=, read -r vm_name vm_ip status; do
        if [ "$status" = "pending" ]; then
            if check_vm_web_service $vm_ip; then
                log_message "Pending server $vm_ip now responding. Adding to load balancer."
                add_server_to_lb $vm_ip
                sed -i "s/$vm_name,$vm_ip,pending/$vm_name,$vm_ip,active/" servers.txt
            fi
        fi
    done < <(tail -n +2 servers.txt)
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
        if [ $check_health_counter -ge 5 ]; then
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
        curl -s -I "http://localhost:${LOAD_BALANCER_PORT}/" | grep "Server"
        sleep 1
    done
}

check_dependencies
setup_govc

if ! govc ls "$VM_FOLDER" &>/dev/null; then
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
    log_message "No existing servers found. Waiting for Terraform to create initial servers..."
    
    sleep 60
    
    EXISTING_VMS=$(get_vm_list | grep $VM_BASE_NAME)
fi

if [ -n "$EXISTING_VMS" ]; then
    log_message "Found existing servers. Adding to load balancer."
    
    for vm in $EXISTING_VMS; do
        vm_ip=$(govc vm.ip "$vm" 2>/dev/null)
        if [ -n "$vm_ip" ]; then
            vm_name=$(basename "$vm")
            echo "$vm_name,$vm_ip,active" >> servers.txt
            
            if check_vm_web_service $vm_ip; then
                add_server_to_lb $vm_ip
                log_message "Added existing server $vm_name ($vm_ip) to load balancer"
            else
                log_message "Existing server $vm_name ($vm_ip) not responding. Marking as pending."
                sed -i "s/$vm_name,$vm_ip,active/$vm_name,$vm_ip,pending/" servers.txt
            fi
        fi
    done
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