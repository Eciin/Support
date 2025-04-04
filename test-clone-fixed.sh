#!/bin/bash

# vSphere credentials and connection info
VSPHERE_USER="i416434@fhict.local"
VSPHERE_PASSWORD="Icw5F[MRci"
VSPHERE_SERVER="vcenter.netlab.fontysict.nl"

VSPHERE_DATACENTER="Netlab-DC"
VSPHERE_CLUSTER="Netlab-Cluster-B"
VSPHERE_RESOURCE_POOL="i416434"
VSPHERE_DATASTORE="NIM01-9"
VSPHERE_NETWORK="0124_Internet-DHCP-192.168.124.0_24"
VSPHERE_TEMPLATE="_Courses/I3-DB01/i416434/Templates/upscale"

# VM configuration
TARGET_FOLDER="_Courses/I3-DB01/i416434"
VM_NAME="test-clone-$(date +%s)"  # Unique name using timestamp

echo "Setting up govc environment..."
export GOVC_URL="https://$VSPHERE_SERVER"
export GOVC_USERNAME="$VSPHERE_USER"
export GOVC_PASSWORD="$VSPHERE_PASSWORD"
export GOVC_INSECURE=true
export GOVC_DATACENTER="$VSPHERE_DATACENTER"
export GOVC_RESOURCE_POOL="$VSPHERE_RESOURCE_POOL"
export GOVC_DATASTORE="$VSPHERE_DATASTORE"
export GOVC_NETWORK="$VSPHERE_NETWORK"

# Test connection
echo "Testing vSphere connection..."
if govc about > /dev/null; then
    echo "Successfully connected to vSphere"
else
    echo "Failed to connect to vSphere. Check credentials."
    exit 1
fi

# Check if template exists
echo "Checking if template exists..."
if govc ls "/vm/$VSPHERE_TEMPLATE" > /dev/null; then
    echo "Template found: $VSPHERE_TEMPLATE"
else
    echo "Template not found: $VSPHERE_TEMPLATE"
    echo "Trying to list available templates:"
    govc ls "/vm/_Courses/I3-DB01/i416434/Templates"
    exit 1
fi

# Check if folder exists and list folders
echo "Listing available folders:"
govc ls /vm
echo "---"
govc ls "/vm/_Courses"
echo "---"
govc ls "/vm/_Courses/I3-DB01"

# Clone the VM - trying with different folder formats
echo "Attempt 1: Cloning VM from template with full path..."
govc vm.clone -vm "$VSPHERE_TEMPLATE" -on=true -folder="/vm/$TARGET_FOLDER" "$VM_NAME"

if [ $? -ne 0 ]; then
    echo "Attempt 2: Cloning VM without /vm/ prefix..."
    govc vm.clone -vm "$VSPHERE_TEMPLATE" -on=true -folder="$TARGET_FOLDER" "$VM_NAME"
fi

if [ $? -ne 0 ]; then
    echo "Attempt 3: Cloning VM to root folder..."
    govc vm.clone -vm "$VSPHERE_TEMPLATE" -on=true "$VM_NAME"
fi

# Check if VM was created
if govc ls "/vm/$TARGET_FOLDER/$VM_NAME" > /dev/null 2>&1 || govc ls "/vm/$VM_NAME" > /dev/null 2>&1; then
    echo "VM clone successful"
    
    # Try to get IP (optional)
    echo "Waiting for VM to get an IP..."
    for i in {1..12}; do
        IP=$(govc vm.ip "/vm/$TARGET_FOLDER/$VM_NAME" 2>/dev/null || govc vm.ip "/vm/$VM_NAME" 2>/dev/null)
        if [ -n "$IP" ]; then
            echo "VM IP: $IP"
            break
        fi
        echo "Waiting... (attempt $i/12)"
        sleep 10
    done
else
    echo "All VM clone attempts failed"
fi
