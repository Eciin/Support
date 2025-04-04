#!/bin/bash

# vSphere credentials and connection info
VSPHERE_USER="i416434@fhict.local"
VSPHERE_PASSWORD="Icw5F[MRci"
VSPHERE_SERVER="vcenter.netlab.fontysict.nl"

VSPHERE_DATACENTER="Netlab-DC"
VSPHERE_TEMPLATE="_Courses/I3-DB01/i416434/Templates/upscale"

# Use exactly the same folder as Terraform
TARGET_FOLDER="_Courses/I3-DB01/i416434"
VM_NAME="test-terraform-folder-$(date +%s)"

# Set environment variables
export GOVC_URL="https://$VSPHERE_SERVER"
export GOVC_USERNAME="$VSPHERE_USER"
export GOVC_PASSWORD="$VSPHERE_PASSWORD"
export GOVC_INSECURE=true
export GOVC_DATACENTER="$VSPHERE_DATACENTER"

# Try cloning using the Terraform folder exactly
echo "Cloning VM using Terraform folder..."
govc vm.clone -vm "$VSPHERE_TEMPLATE" -on=true -folder="$TARGET_FOLDER" "$VM_NAME"

if [ $? -eq 0 ]; then
    echo "VM clone successful: $VM_NAME"
else
    echo "VM clone failed"
fi
