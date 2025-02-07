<#
.SYNOPSIS
    Synchronizes Azure AD security groups with their corresponding “Delayed” groups for Intune devices based on enrollment time.

.DESCRIPTION
    This script is designed to automate the synchronization between source Azure AD security groups and corresponding “Delayed” groups. For each source group whose display name begins with a specified prefix (for example, "sg-intune-automated-"), the script performs the following operations:

    1. **Authentication:**  
       Authenticates to Microsoft Graph and Azure using a user-assigned managed identity.

    2. **Group Retrieval:**  
       Retrieves all security groups with display names that start with the specified prefix. Groups ending with "-Delayed" are filtered out to avoid processing groups that are already the delayed counterparts.

    3. **Managed Device Retrieval:**  
       Fetches all Intune managed devices using the beta endpoint. Only the fields required for processing—namely, `id`, `azureADDeviceId`, and `enrolledDateTime`—are selected to optimize memory usage. Paging is implemented to ensure that all results are retrieved.

    4. **Lookup Table Construction:**  
       A hashtable is built keyed on each managed device's `azureADDeviceId` to allow quick lookups when processing group members.

    5. **Per-Group Processing:**  
       For each source group:
         - The script retrieves all group members (selecting only the fields `id`, `displayName`, and `deviceId`), with paging support.
         - It then determines which devices have been enrolled for at least 8 hours by comparing the current time to the `enrolledDateTime` of each matching managed device.
         - If a device qualifies, it is synchronized with the corresponding “Delayed” group.
         - The script ensures that a delayed group exists (named by appending "-Delayed" to the source group’s display name); if not, it creates one.
         - It then adds qualifying devices to the delayed group if they are not already members and removes any devices from the delayed group that are no longer in the source group.

    6. **Logging and Reporting:**  
       All actions, changes, and errors are logged to a local file. At the end of the runbook, the log file is uploaded to an Azure Blob Storage container for record-keeping.

.NOTES
    - **Prerequisites:**  
      • Microsoft Graph PowerShell module must be installed and imported.  
      • Az.Storage module must be installed and imported.  
      • A user-assigned managed identity is required for authentication.  
      • The specified Azure Blob Storage container must exist.
      
    - **Authentication:**  
      The script uses the managed identity (via the `-Identity` parameter) for both Graph and Az commands.
      
    - **Optimization:**  
      Only the necessary fields are selected from Graph API responses (using the `$select` query parameter) to minimize network overhead and memory usage. Paging is supported via a helper function.

.EXAMPLE
    .\Sync-DelayedGroups.ps1

    This example runs the script with the default configuration settings. Adjust the parameters (such as the group prefix and storage account details) as needed for your environment.

.AUTHOR
    Maxime Guillemin

.DATE
    07/02/2025
#>

# =====================================================
# 0. Initialize Log File
# =====================================================
$global:LogFilePath = Join-Path ([System.IO.Path]::GetTempPath()) ("RunbookLog_{0}.txt" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
# Create or clear the log file.
New-Item -Path $global:LogFilePath -ItemType File -Force | Out-Null

# -----------------------------------------------------
# Helper Function: Write-Log
# -----------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "$timestamp [$Level] $Message"
    # Write to the console:
    Write-Output $logLine
    # Append the log line to the log file.
    Add-Content -Path $global:LogFilePath -Value $logLine
}

# -----------------------------------------------------
# Helper Function: Upload-LogToBlob
# -----------------------------------------------------
function Upload-LogToBlob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$StorageAccountName,
        [Parameter(Mandatory=$true)]
        [string]$StorageContainerName,
        [Parameter(Mandatory=$true)]
        [string]$LogFilePath
    )
    try {
        $timestampForFile = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $blobName = "LogFile_$timestampForFile.txt"
        # Create a storage context using the provided account name and connected identity.
        $storageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
        # Upload the log file.
        $uploadResult = Set-AzStorageBlobContent -File $LogFilePath -Container $StorageContainerName -Blob $blobName -Context $storageContext

        if ($uploadResult -and $uploadResult.ICloudBlob) {
            Write-Log "Log file successfully uploaded as blob '$blobName' to container '$StorageContainerName'." "INFO"
        }
        else {
            Write-Log "Failed to upload log file to blob storage." "ERROR"
        }
    }
    catch {
        Write-Log "Exception during log upload: $_" "ERROR"
    }
    # (Optional) Clean up the log file after upload:
    # Remove-Item $LogFilePath -Force
}

# -----------------------------------------------------
# Helper Function: Get-AllGraphData
# -----------------------------------------------------
function Get-AllGraphData {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )
    $results = @()
    try {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
        if ($response.value) {
            $results += $response.value
        }
        while ($response.'@odata.nextLink') {
            $Uri = $response.'@odata.nextLink'
            $response = Invoke-MgGraphRequest -Method GET -Uri $Uri
            if ($response.value) {
                $results += $response.value
            }
        }
    }
    catch {
        Write-Log "Error retrieving data from $Uri : $_" "ERROR"
    }
    return $results
}

# =====================================================
# 1. Configuration and Parameters
# =====================================================

# User-assigned managed identity client ID.
$userAssignedClientId = ""

# Set the source group prefix.
$SourceGroupPrefix = ""

# Suffix for the corresponding delayed group.
$DelayedSuffix = ""

# Storage account configuration for log upload.
$StorageAccountName   = ""
$StorageContainerName = ""  # Ensure this container exists

# =====================================================
# 2. Authenticate to Microsoft Graph & AzAccount
# =====================================================

Write-Log "Authenticating to Microsoft Graph..."
try {
    Connect-MgGraph -Identity -ClientId $userAssignedClientId
    Connect-AzAccount -Identity -AccountId $userAssignedClientId
    Write-Log "Successfully authenticated to Microsoft Graph."
}
catch {
    Write-Log "Failed to authenticate to Microsoft Graph: $_" "ERROR"
    return
}

# =====================================================
# 3. Retrieve All Source Groups Matching the Prefix (Paging Enabled)
# =====================================================
Write-Log "Retrieving all security groups with display name starting with '$SourceGroupPrefix'..."
# Use the OData function startswith to filter groups by displayName.
# Only select the id and displayName fields.
$groupsUrl = "https://graph.microsoft.com/v1.0/groups?`$filter=startswith(displayName,'$SourceGroupPrefix')&`$select=id,displayName"
$allGroups = Get-AllGraphData -Uri $groupsUrl

if (-not $allGroups -or $allGroups.Count -eq 0) {
    Write-Log "No source groups found with prefix '$SourceGroupPrefix'. Exiting." "ERROR"
    return
}

# Filter out groups whose display name ends with "-Delayed" so that they are not processed as source groups.
$sourceGroups = $allGroups | Where-Object { $_.displayName -notlike "*$DelayedSuffix" }
Write-Log "Found $($sourceGroups.Count) source group(s) with prefix '$SourceGroupPrefix' (excluding groups ending with '$DelayedSuffix')."

# =====================================================
# 4. Fetch All Managed Devices from Intune (Beta Endpoint, Paging Enabled)
# =====================================================
Write-Log "Fetching all managed devices from Intune..."
# Only select id, azureADDeviceId, and enrolledDateTime.
$managedDevicesUrl = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$select=id,azureADDeviceId,enrolledDateTime"
$managedDevices = Get-AllGraphData -Uri $managedDevicesUrl

if (-not $managedDevices -or $managedDevices.Count -eq 0) {
    Write-Log "No managed devices found from Intune." "ERROR"
    return
}
Write-Log "Fetched $($managedDevices.Count) managed device(s) from Intune."

# =====================================================
# 5. Build a Hashtable for Managed Devices (Keyed on azureADDeviceId)
# =====================================================
Write-Log "Building lookup table for managed devices..."
$deviceLookup = @{}
foreach ($mDevice in $managedDevices) {
    if ($mDevice.azureADDeviceId) {
        $deviceLookup[$mDevice.azureADDeviceId] = $mDevice
    }
}
Write-Log "Lookup table built with $($deviceLookup.Keys.Count) entr(y/ies)."

# =====================================================
# 6. Process Each Source Group
# =====================================================
foreach ($sourceGroup in $sourceGroups) {

    Write-Log "------------------------------------------------------------"
    Write-Log "Processing source group: '$($sourceGroup.displayName)' (ID: $($sourceGroup.id))."

    # -------------------------------------------------
    # Retrieve members of the current source group (with paging).
    # Only select id, displayName, and deviceId.
    $sourceMembersUrl = "https://graph.microsoft.com/v1.0/groups/$($sourceGroup.id)/members?`$select=id,displayName,deviceId"
    $sourceMembers = Get-AllGraphData -Uri $sourceMembersUrl

    if (-not $sourceMembers -or $sourceMembers.Count -eq 0) {
        Write-Log "No members found in group '$($sourceGroup.displayName)'; skipping." "WARNING"
        continue
    }
    Write-Log "Group '$($sourceGroup.displayName)' contains $($sourceMembers.Count) member(s)."

    # -------------------------------------------------
    # Determine qualifying devices (enrolled for >= 8 hours).
    $qualifyingDevices = @()
    foreach ($member in $sourceMembers) {
        # The source group device objects should include a "deviceId" property that corresponds to the managed device's azureADDeviceId.
        if (-not $member.deviceId) {
            Write-Log "Member '$($member.displayName)' in group '$($sourceGroup.displayName)' does not have a 'deviceId' property; skipping." "WARNING"
            continue
        }
        $lookupKey = $member.deviceId
        if ($deviceLookup.ContainsKey($lookupKey)) {
            $managedDevice = $deviceLookup[$lookupKey]
            try {
                $enrollmentTime = [datetime]$managedDevice.enrolledDateTime
                $hoursSinceEnrollment = ([datetime]::UtcNow - $enrollmentTime).TotalHours

                if ($hoursSinceEnrollment -ge 8) {
                    Write-Log "Device '$($member.displayName)' (DeviceId: $lookupKey) in group '$($sourceGroup.displayName)' enrolled $([math]::Round($hoursSinceEnrollment,2)) hours ago qualifies." "CHANGE"
                    $qualifyingDevices += $member
                }
                else {
                    Write-Log "Device '$($member.displayName)' (DeviceId: $lookupKey) in group '$($sourceGroup.displayName)' enrolled $([math]::Round($hoursSinceEnrollment,2)) hours ago; does not qualify." "INFO"
                }
            }
            catch {
                Write-Log "Error processing enrollment time for device '$($member.displayName)' in group '$($sourceGroup.displayName)' (DeviceId: $lookupKey): $_" "ERROR"
            }
        }
        else {
            Write-Log "Managed device details not found for member '$($member.displayName)' in group '$($sourceGroup.displayName)' with DeviceId: $lookupKey." "WARNING"
        }
    }
    Write-Log "Total qualifying devices in group '$($sourceGroup.displayName)' (enrolled >= 8 hours ago): $($qualifyingDevices.Count)."

    # -------------------------------------------------
    # Create/Get the corresponding delayed group.
    $delayedGroupDisplayName = "$($sourceGroup.displayName)$DelayedSuffix"
    Write-Log "Checking for existence of delayed group '$delayedGroupDisplayName' for source group '$($sourceGroup.displayName)'."
    $encodedFilterDelayed = [System.Web.HttpUtility]::UrlEncode("displayName eq '$delayedGroupDisplayName'")
    # Only select id and displayName for the delayed group.
    $delayedGroupUrl = "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilterDelayed&`$select=id,displayName"
    $delayedGroupResponse = Invoke-MgGraphRequest -Method GET -Uri $delayedGroupUrl

    if (-not $delayedGroupResponse.value -or $delayedGroupResponse.value.Count -eq 0) {
        Write-Log "Delayed group '$delayedGroupDisplayName' not found. Creating it..." "INFO"
        $groupPayload = @{
            displayName     = $delayedGroupDisplayName
            description     = "Delayed group for devices enrolled 8+ hours ago from source group '$($sourceGroup.displayName)'"
            mailEnabled     = $false
            mailNickname    = ($delayedGroupDisplayName -replace '\s','')
            securityEnabled = $true
        }
        $groupPayloadJson = $groupPayload | ConvertTo-Json -Depth 10
        try {
            $delayedGroup = Invoke-MgGraphRequest -Method POST -Uri "https://graph.microsoft.com/v1.0/groups" -Body $groupPayloadJson
            Write-Log "Created delayed group: '$($delayedGroup.displayName)' (ID: $($delayedGroup.id)) for source group '$($sourceGroup.displayName)'." "CHANGE"
        }
        catch {
            Write-Log "Error creating delayed group for source group '$($sourceGroup.displayName)': $_" "ERROR"
            continue  # Skip processing this group.
        }
    }
    else {
        $delayedGroup = $delayedGroupResponse.value[0]
        Write-Log "Found delayed group: '$($delayedGroup.displayName)' (ID: $($delayedGroup.id)) for source group '$($sourceGroup.displayName)'."
    }

    # -------------------------------------------------
    # Retrieve members of the delayed group (with paging).
    # Only select id, displayName, and deviceId.
    Write-Log "Retrieving members of delayed group '$($delayedGroup.displayName)' for source group '$($sourceGroup.displayName)'."
    $delayedMembersUrl = "https://graph.microsoft.com/v1.0/groups/$($delayedGroup.id)/members?`$select=id,displayName,deviceId"
    $delayedMembers = Get-AllGraphData -Uri $delayedMembersUrl
    if (-not $delayedMembers) { $delayedMembers = @() }
    Write-Log "Delayed group '$($delayedGroup.displayName)' currently has $($delayedMembers.Count) member(s)."

    # -------------------------------------------------
    # Add qualifying devices to the delayed group.
    Write-Log "Processing addition of qualifying devices to delayed group '$($delayedGroup.displayName)' for source group '$($sourceGroup.displayName)'."
    foreach ($member in $qualifyingDevices) {
        $exists = $delayedMembers | Where-Object { $_.deviceId -eq $member.deviceId }
        if (-not $exists) {
            Write-Log "Adding device '$($member.displayName)' (DeviceId: $($member.deviceId)) from group '$($sourceGroup.displayName)' to delayed group '$($delayedGroup.displayName)'." "CHANGE"
            $addMemberUrl = "https://graph.microsoft.com/v1.0/groups/$($delayedGroup.id)/members/`$ref"
            $body = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($member.id)"
            }
            $bodyJson = $body | ConvertTo-Json -Depth 10
            try {
                Invoke-MgGraphRequest -Method POST -Uri $addMemberUrl -Body $bodyJson
                Write-Log "Successfully added device '$($member.displayName)' to delayed group '$($delayedGroup.displayName)'." "CHANGE"
            }
            catch {
                Write-Log "Error adding device '$($member.displayName)' to delayed group '$($delayedGroup.displayName)': $_" "ERROR"
            }
        }
        else {
            Write-Log "Device '$($member.displayName)' (DeviceId: $($member.deviceId)) is already in delayed group '$($delayedGroup.displayName)'." "INFO"
        }
    }

    # -------------------------------------------------
    # Remove devices from the delayed group that are no longer in the source group.
    Write-Log "Processing removal of devices from delayed group '$($delayedGroup.displayName)' that are no longer in source group '$($sourceGroup.displayName)'."
    $sourceDeviceIds = $sourceMembers | Where-Object { $_.deviceId } | ForEach-Object { $_.deviceId }
    foreach ($delayedMember in $delayedMembers) {
        if ($delayedMember.deviceId) {
            if (-not ($sourceDeviceIds -contains $delayedMember.deviceId)) {
                Write-Log "Removing device with DeviceId '$($delayedMember.deviceId)' from delayed group '$($delayedGroup.displayName)' for source group '$($sourceGroup.displayName)' (no longer in source group)." "CHANGE"
                $removeMemberUrl = "https://graph.microsoft.com/v1.0/groups/$($delayedGroup.id)/members/$($delayedMember.id)/`$ref"
                try {
                    Invoke-MgGraphRequest -Method DELETE -Uri $removeMemberUrl
                    Write-Log "Successfully removed device with DeviceId '$($delayedMember.deviceId)' from delayed group '$($delayedGroup.displayName)'." "CHANGE"
                }
                catch {
                    Write-Log "Error removing device with DeviceId '$($delayedMember.deviceId)' from delayed group '$($delayedGroup.displayName)': $_" "ERROR"
                }
            }
        }
        else {
            Write-Log "Delayed group member with id '$($delayedMember.id)' does not have a 'deviceId' property; skipping removal check." "WARNING"
        }
    }

    Write-Log "Synchronization complete for source group '$($sourceGroup.displayName)'."
}

# =====================================================
# 7. Upload the Log File to Azure Blob Storage
# =====================================================
Write-Log "Uploading log file to Azure Blob Storage..."
Upload-LogToBlob -StorageAccountName $StorageAccountName `
                 -StorageContainerName $StorageContainerName `
                 -LogFilePath $global:LogFilePath

Write-Log "Runbook completed for all groups."
