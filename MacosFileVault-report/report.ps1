function Get-GraphData {
    param (
        [Parameter(Mandatory=$true)]
        [string] $url
    )
    $results = @()
    do {
        $response = Invoke-MgGraphRequest -Uri $url -Method GET
        if ($response.'@odata.nextLink' -ne $null) {
            $url = $response.'@odata.nextLink'
            $results += $response.value
        } else {
            $results += $response.value
            return $results
        }
    } while ($response.'@odata.nextLink')
}

function Generate-DeviceFileVaultKeyMarkdown {
    param (
        [Parameter(Mandatory=$true)]
        [array]$devices,

        [Parameter(Mandatory=$true)]
        [string]$outputPath
    )

    try {
        $tenant = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/organization" -Method GET
        $tenantinfo = "Tenant: $($tenant.value[0].displayName)"
        $dateString = Get-Date -Format "dddd, MMMM dd, yyyy HH:mm:ss"
        $markdownContent = ""
        
        $markdownContent += "# Device FileVault Key Information`n`n"
        $markdownContent += "$tenantinfo `n"
        $markdownContent += "Documentation Date: $dateString`n`n"

        # Devices with Key
        $devicesWithKey = $devices | Where-Object { $_.FileVaultKey -eq "Key is present in Intune" }
        $markdownContent += "## Devices with Key`n`n"
        $markdownContent += "Devices Count $($devicesWithKey.count)/$($devices.count)`n`n"
        $markdownContent += "| deviceName | isEncrypted | FileVaultKey | deviceEnrollmentType | id | managedDeviceName | managedDeviceOwnerType | osVersion | userDisplayName | userPrincipalName |`n"
        $markdownContent += "|------------|-------------|--------------|----------------------|----|-------------------|------------------------|-----------|-----------------|-------------------|`n"

        foreach ($device in $devicesWithKey) {
            $markdownContent += "| $($device.deviceName) | $($device.isEncrypted) | $($device.FileVaultKey) | $($device.deviceEnrollmentType) | $($device.id) | $($device.managedDeviceName) | $($device.managedDeviceOwnerType) | $($device.osVersion) | $($device.userDisplayName) | $($device.userPrincipalName) |`n"
        }

        # Devices with No Key
        $devicesWithNoKey = $devices | Where-Object { $_.FileVaultKey -eq "Key not present in Intune" }
        $markdownContent += "## Devices with No Key`n`n"
        $markdownContent += "Devices Count $($devicesWithNoKey.count)/$($devices.count)`n`n"
        $markdownContent += "| deviceName | isEncrypted | FileVaultKey | deviceEnrollmentType | id | managedDeviceName | managedDeviceOwnerType | osVersion | userDisplayName | userPrincipalName |`n"
        $markdownContent += "|------------|-------------|--------------|----------------------|----|-------------------|------------------------|-----------|-----------------|-------------------|`n"

        foreach ($device in $devicesWithNoKey) {
            $markdownContent += "| $($device.deviceName) | $($device.isEncrypted) | $($device.FileVaultKey) | $($device.deviceEnrollmentType) | $($device.id) | $($device.managedDeviceName) | $($device.managedDeviceOwnerType) | $($device.osVersion) | $($device.userDisplayName) | $($device.userPrincipalName) |`n"
        }

        # Non Encrypted Devices
        $nonEncryptedDevices = $devices | Where-Object { $_.isEncrypted -eq $false }
        $markdownContent += "## Non Encrypted Devices`n`n"
        $markdownContent += "Devices Count $($nonEncryptedDevices.count)/$($devices.count)`n`n"
        $markdownContent += "| deviceName | isEncrypted | FileVaultKey | deviceEnrollmentType | id | managedDeviceName | managedDeviceOwnerType | osVersion | userDisplayName | userPrincipalName |`n"
        $markdownContent += "|------------|-------------|--------------|----------------------|----|-------------------|------------------------|-----------|-----------------|-------------------|`n"

        foreach ($device in $nonEncryptedDevices) {
            $markdownContent += "| $($device.deviceName) | $($device.isEncrypted) | $($device.FileVaultKey) | $($device.deviceEnrollmentType) | $($device.id) | $($device.managedDeviceName) | $($device.managedDeviceOwnerType) | $($device.osVersion) | $($device.userDisplayName) | $($device.userPrincipalName) |`n"
        }

        # Personal Devices
        $ErrorDevices = $devices | Where-Object { $_.FileVaultKey -eq "Personal Device Key not present in Intune" }
        $markdownContent += "## Personal Devices`n`n"
        $markdownContent += "Devices Count $($ErrorDevices.count)/$($devices.count)`n`n"
        $markdownContent += "| deviceName | isEncrypted | FileVaultKey | deviceEnrollmentType | id | managedDeviceName | managedDeviceOwnerType | osVersion | userDisplayName | userPrincipalName |`n"
        $markdownContent += "|------------|-------------|--------------|----------------------|----|-------------------|------------------------|-----------|-----------------|-------------------|`n"

        foreach ($device in $ErrorDevices) {
            $markdownContent += "| $($device.deviceName) | $($device.isEncrypted) | $($device.FileVaultKey) | $($device.deviceEnrollmentType) | $($device.id) | $($device.managedDeviceName) | $($device.managedDeviceOwnerType) | $($device.osVersion) | $($device.userDisplayName) | $($device.userPrincipalName) |`n"
        }

        # Write the markdown content to the output file
        $markdownContent | Out-File -FilePath $outputPath -Encoding utf8

        Write-Host "Markdown file generated successfully at $outputPath"
    }
    catch {
        Write-Error "An error occurred: $_"
    }
}

# Connect to Microsoft Graph
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.PrivilegedOperations.All, DeviceManagementManagedDevices.Read.All"

# Define the URL to get macOS devices
$urlmacosdevices = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=operatingSystem eq 'macOS'&`$select=id,deviceName,isEncrypted,userPrincipalName,userDisplayName,osVersion,deviceEnrollmentType,managedDeviceName,managedDeviceOwnerType"

# Get macOS devices
$macosdevices = Get-GraphData -url $urlmacosdevices

# Process devices to determine FileVault key status
$vaultinformation = $macosdevices | ForEach-Object {
    $device = $_
    if ($device.isEncrypted -eq $true) {
        $urlfilevaultkey = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$($device.id)')/getFileVaultKey"
        try {
            $response = Invoke-MgGraphRequest -Uri $urlfilevaultkey -Method GET
            $device.FileVaultKey = "Key is present in Intune"
        }
        catch {
            if ($_.Exception.Response.StatusCode -eq 404) {
                $device.FileVaultKey = "Key not present in Intune"
            } else {
                $device.FileVaultKey = "Personal Device Key not present in Intune"
            }
        }
    } else {
        $device.FileVaultKey = "Disk Not Encrypted"
    }
    # Output the device object with or without the FileVaultKey
    $device
}

# Generate the markdown file
Generate-DeviceFileVaultKeyMarkdown -devices $vaultinformation -outputPath "DeviceFileVaultKeyInformation.md"
$vaultinformation | Export-Csv -Path "DeviceFileVaultKeyInformation.csv"
#Disconnect-MgGraph