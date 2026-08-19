#!/bin/bash
#
# Copyright 2024 Cohesity Inc.
#
# Author: Kanak Agarwal
#
# Script to cleanup azure snapshots using bash.
#

set -euo pipefail

# Logging functions for INFO and ERROR messages
log_info() {
    local message="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "\033[34m[$timestamp] INFO: $message\033[0m"
}

log_error() {
    local message="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo -e "\033[31m[$timestamp] ERROR: $message\033[0m"
}

# Fail fast if the Azure CLI is not available
if ! command -v az >/dev/null 2>&1; then
    log_error "Azure CLI (az) is required but was not found."
    exit 1
fi

# Prompt the user to input the Application ID
read -p "Enter Application ID: " app_id

# Prompt the user to input the Service Principal Key
read -s -p "Enter Service Principal Key: " service_principal_key
echo # for newline after the password prompt

# Prompt the user to input the Tenant ID
read -p "Enter Tenant ID: " tenant_id

# Prompt the user for the number of days
read -p "Enter the number of days for snapshots to be older than: " n

# Validate the number of days
if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    log_error "Number of days must be a positive integer, got: '$n'"
    exit 1
fi

# Prompt the user to input the Job ID (optional)
read -p "Enter Job ID (optional): " job_id

# Log the login action
log_info "Logging in with service principal"

# Login with service principal
if ! az login --service-principal -u "$app_id" -p "$service_principal_key" --tenant "$tenant_id" >/dev/null; then
    log_error "Azure login failed."
    exit 1
fi
log_info "Azure login successful"

# Get the current date in seconds since epoch
current_date=$(date +%s)

# Calculate the threshold date in seconds since epoch
threshold_date=$((current_date - n * 86400))  # 86400 seconds in a day

log_info "Threshold date calculated as $(date -d @$threshold_date)"

# Construct the query for snapshots based on the presence of the Job ID
if [ -n "$job_id" ]; then
    log_info "Fetching snapshots with 'cohesity-tag' and Job ID: $job_id"
    snapshots=$(az snapshot list --query "[?tags.\"cohesity-tag\" != null && contains(tags.\"cohesity-tag\", \":$job_id:\") && timeCreated != ''].{id:id, creationTime:timeCreated}" -o tsv)
else
    log_info "Fetching all snapshots with 'cohesity-tag'"
    snapshots=$(az snapshot list --query "[?tags.\"cohesity-tag\" != null && timeCreated != ''].{id:id, creationTime:timeCreated}" -o tsv)
fi

# Initialize an array to store IDs of snapshots to delete
snapshots_to_delete=()

# Loop through each snapshot
while IFS=$'\t' read -r id creation_time; do
    # Convert creation time to seconds since epoch
    creation_date=$(date -d "${creation_time//\"}" +%s)  # Remove quotes from the timestamp

    # Check if the creation time is valid and not 'None'
    if [ -n "$creation_date" ]; then
        # Check if the creation time is older than the threshold
        if [ "$creation_date" -lt "$threshold_date" ]; then
            log_info "Cohesity Snapshot $id was created on $(date -d "${creation_time//\"}")"
            # Add the snapshot ID to the array for deletion
            snapshots_to_delete+=("$id")
        fi
    else
        log_error "Failed to parse creation time: $creation_time"
    fi
done <<< "$snapshots"

# Check if there are snapshots to delete
if [ "${#snapshots_to_delete[@]}" -gt 0 ]; then
    log_info "Found ${#snapshots_to_delete[@]} snapshots to delete"
    # Prompt for confirmation
    read -p "Do you want to delete the listed snapshots? Type YES to confirm: " confirmation
    if [ "$confirmation" == "YES" ]; then
        log_info "Deleting Snapshots:"
        for snapshot_id in "${snapshots_to_delete[@]}"; do
            log_info "$snapshot_id"
        done
        # Delete the snapshots one by one so a single failure does not abort the cleanup
        deleted=0
        failed=0
        for snapshot_id in "${snapshots_to_delete[@]}"; do
            if az snapshot delete --ids "$snapshot_id"; then
                log_info "Deleted snapshot $snapshot_id"
                deleted=$((deleted + 1))
            else
                log_error "Failed to delete $snapshot_id"
                failed=$((failed + 1))
            fi
        done
        log_info "Deleted $deleted snapshots, $failed failed."
    else
        log_info "Deletion cancelled. No snapshots were deleted."
    fi
else
    log_info "No snapshots to delete."
fi
