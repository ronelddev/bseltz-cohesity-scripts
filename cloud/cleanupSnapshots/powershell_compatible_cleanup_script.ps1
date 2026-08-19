# Copyright 2024 Cohesity Inc.
#
# Author: Kanak Agarwal
#
# Script to cleanup azure snapshots using powershell.
#

[CmdletBinding()]
param (
    [string]$ApplicationId,
    [securestring]$ServicePrincipalKey,
    [string]$TenantId,
    [int]$Days,
    [string]$JobId,
    [switch]$Force
)

# Logging functions for INFO and ERROR messages
function log_info {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] INFO: $message" -ForegroundColor Blue
}

function log_error {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] ERROR: $message" -ForegroundColor Red
}

# Ensure required Az modules are available
foreach ($module in @('Az.Compute', 'Az.Resources')) {
    if (-not (Get-Module -Name $module -ListAvailable)) {
        log_error "Required module '$module' is not installed. Install it with: Install-Module -Name $module"
        exit 1
    }
    Import-Module -Name $module
}

# Collect required inputs, prompting when they are not supplied as parameters
if ([string]::IsNullOrEmpty($ApplicationId)) { $ApplicationId = Read-Host -Prompt "Enter Application ID" }
if ($null -eq $ServicePrincipalKey) { $ServicePrincipalKey = Read-Host -Prompt "Enter Service Principal Key" -AsSecureString }
if ([string]::IsNullOrEmpty($TenantId)) { $TenantId = Read-Host -Prompt "Enter Tenant ID" }
if ($Days -le 0) {
    $inputDays = Read-Host -Prompt "Enter the number of days for snapshots to be older than"
    if (-not [int]::TryParse($inputDays, [ref]$Days) -or $Days -le 0) {
        log_error "Number of days must be a positive integer, got: '$inputDays'"
        exit 1
    }
}
if ([string]::IsNullOrEmpty($JobId)) { $JobId = Read-Host -Prompt "Enter Job ID (optional)" }

# Log the login action
log_info "Logging in with service principal"

# Create credential object
$cred = New-Object System.Management.Automation.PSCredential ($ApplicationId, $ServicePrincipalKey)

# Login with service principal
try {
    Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $cred -ErrorAction Stop
    log_info "Azure login successful"
}
catch {
    log_error "Azure login failed: $($_.Exception.Message)"
    exit 1
}

# Get the current date in seconds since epoch
$currentDate = [DateTimeOffset]::Now.ToUnixTimeSeconds()

# Calculate the threshold date in seconds since epoch
$thresholdDate = $currentDate - ($Days * 86400)  # 86400 seconds in a day

log_info "Threshold date calculated as $([DateTimeOffset]::FromUnixTimeSeconds($thresholdDate))"

# Get the list of snapshots based on the presence of the Job ID
try {
    if (-not [string]::IsNullOrEmpty($JobId)) {
        log_info "Fetching snapshots with 'cohesity-tag' and Job ID: $JobId"
        $snapshots = Get-AzSnapshot -ErrorAction Stop | Where-Object {
            $null -ne $_.Tags['cohesity-tag'] -and $null -ne $_.TimeCreated -and $_.Tags['cohesity-tag'] -like "*:${JobId}:*"
        }
    } else {
        log_info "Fetching all snapshots with 'cohesity-tag'"
        $snapshots = Get-AzSnapshot -ErrorAction Stop | Where-Object {
            $null -ne $_.Tags['cohesity-tag'] -and $null -ne $_.TimeCreated
        }
    }
}
catch {
    log_error "Failed to list snapshots: $($_.Exception.Message)"
    Disconnect-AzAccount -ErrorAction SilentlyContinue
    exit 1
}

# Initialize an array to store IDs of snapshots to delete
$snapshotsToDelete = @()

# Loop through each snapshot
foreach ($snapshot in $snapshots) {
    # Convert creation time to seconds since epoch (TimeCreated is a DateTime)
    $creationDate = $snapshot.TimeCreated.ToUniversalTime().ToUnixTimeSeconds()

    # Check if the creation time is older than the threshold
    if ($creationDate -lt $thresholdDate) {
        log_info "Snapshot $($snapshot.Id) was created on $($snapshot.TimeCreated)"
        # Add the snapshot ID to the array for deletion
        $snapshotsToDelete += $snapshot.Id
    }
}

# Check if there are snapshots to delete
if ($snapshotsToDelete.Count -gt 0) {
    log_info "Found $($snapshotsToDelete.Count) snapshots to delete"
    # Prompt for confirmation unless -Force is used
    if (-not $Force) {
        $confirmation = Read-Host -Prompt "Do you want to delete the listed snapshots? Type YES to confirm"
        if ($confirmation -ne "YES") {
            log_info "Deletion cancelled. No snapshots were deleted."
            Disconnect-AzAccount -ErrorAction SilentlyContinue
            exit 0
        }
    }
    log_info "Deleting Snapshots:"
    foreach ($snapshotId in $snapshotsToDelete) {
        log_info "$snapshotId"
    }
    # Delete the snapshots
    $deleted = 0
    $failed = 0
    foreach ($snapshotId in $snapshotsToDelete) {
        try {
            Remove-AzResource -ResourceId $snapshotId -Force -ErrorAction Stop
            log_info "Deleted snapshot $snapshotId"
            $deleted++
        }
        catch {
            log_error "Failed to delete $snapshotId : $($_.Exception.Message)"
            $failed++
        }
    }
    log_info "Deleted $deleted snapshots, $failed failed."
} else {
    log_info "No snapshots to delete."
}

Disconnect-AzAccount -ErrorAction SilentlyContinue
