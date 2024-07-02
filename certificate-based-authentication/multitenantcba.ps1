<#
.SYNOPSIS
This PowerShell script is designed to manage and synchronize user authorization information between two Azure Active Directory (Azure AD) tenants, Tenant A (using Managed Identity) and Tenant B (using App Registration).

.DESCRIPTION
The script performs the following key functions:
1. Initializes a log file to record activities and errors.
2. Retrieves OAuth2 access token for Tenant A using Managed Identity and for Tenant B using client credentials.
3. Retrieves members of specific Azure AD groups from each tenant.
4. Updates the authorization information for users in Tenant B based on the details from Tenant A.
5. Uploads the log file to Azure Blob Storage.

The workflow includes:
1. Log File Initialization: The script checks for an existing log file, removes it, and creates a new log file.
2. Access Token Generation: The script retrieves access tokens for Tenant A (Managed Identity) and Tenant B (App Registration).
3. Group Members Retrieval: The script retrieves group members from both tenants.
4. User Comparison and Logging: It compares user memberships between the two tenants, logging matched users, users only in Tenant A, and users only in Tenant B.
5. Updating User Authorization in Tenant B: For matched users, it updates the user authorization information in Tenant B.
6. Upload Log File: The script uploads the log file to Azure Blob Storage with a structured path.

.NOTES
This is a DEMO script intended for demonstration purposes only and is not ready for production use. Several aspects may need to be reviewed and adjusted for security, error handling, scalability, and efficiency before deploying in a production environment.

CLIENT SECRETS: The placeholders for client secrets need to be filled with actual values.
ERROR HANDLING: The script includes basic error handling, but it should be enhanced for production to handle various edge cases and exceptions more robustly.
SECURITY: Ensure secure handling of sensitive information such as client secrets and access tokens.
PERMISSIONS: Proper permissions must be configured in Azure AD for the script to access and modify user information.

This script serves as a starting point for managing user synchronization between Azure AD tenants but requires thorough testing and refinement before being used in a live environment.
#>

# Tenant A details (Managed Identity)
$TenantAId = "<TenantAId>"
$GroupIdA = "<GroupIdA>"
$miAppId = "<ManagedIdentityAppId>"

# Tenant B details (App Registration)
$TenantBId = "<TenantBId>"
$TenantBClientId = "<TenantBClientId>"
$TenantBClientSecret = "<TenantBClientSecret>"
$GroupIdB = "<GroupIdB>"

# Azure Blob Storage details
$StorageAccountName = "<StorageAccountName>"
$ContainerName = "cert-auth"
$BlobEndpoint = "https://$($StorageAccountName).blob.core.windows.net/"

# Log file path
$LogFilePath = ".\Cert_Auth.log"

# Function to log messages to console and log file
function Log-Message {
    param (
        [string]$Message
    )
    Write-Host $Message
    Add-Content -Path $LogFilePath -Value $Message
}

# Function to get an access token for Microsoft Graph API using managed identity
function Get-GraphAPIAccessTokenPost {
    param (
        [string]$miAppId
    )
    $url = $env:IDENTITY_ENDPOINT
    $headers = @{
        'Metadata' = 'True'
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
    }
    $body = @{
        'resource' = 'https://graph.microsoft.com'
        'client_id' = $miAppId
    }
    # Send POST request to get access token
    $accessToken = Invoke-RestMethod $url -Method 'POST' -Headers $headers -ContentType 'application/x-www-form-urlencoded' -Body $body
    return $accessToken.access_token
}

# Function to get access token for App Registration
function Get-AccessToken-AppRegistration {
    param (
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    $body = @{
        grant_type    = "client_credentials"
        scope         = "https://graph.microsoft.com/.default"
        client_id     = $ClientId
        client_secret = $ClientSecret
    }

    $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -ContentType "application/x-www-form-urlencoded" -Body $body
    return $response.access_token
}

# Function to get group members with paging
function Get-GroupMembers {
    param (
        [string]$AccessToken,
        [string]$GroupId
    )
    $headers = @{
        "Authorization" = "Bearer $AccessToken"
    }
    $members = @()
    $url = "https://graph.microsoft.com/beta/groups/$GroupId/members?$expand=*"

    try {
        do {
            $response = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
            $members += $response.value
            $url = $response.'@odata.nextLink'
        } while ($url -ne $null)
        return $members
    } catch {
        Log-Message "Failed to get members for Group ID $GroupId. Error: $_"
        return $null
    }
}

# Function to update user authorization info in Tenant B
function Update-UserAuthorizationInfo {
    param (
        [string]$AccessToken,
        [string]$UserId,
        [string]$UserPrincipalName
    )
    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
    }

    $body = @{
        "authorizationInfo" = @{
            "certificateUserIds" = @("X509:<PN>CN=$UserPrincipalName")
        }
    } | ConvertTo-Json

    $url = "https://graph.microsoft.com/v1.0/users/$UserId"
    try {
        Invoke-RestMethod -Method Patch -Uri $url -Headers $headers -Body $body
        Log-Message "Successfully updated authorization info for user $UserPrincipalName"
    } catch {
        Log-Message "Failed to update authorization info for user $UserPrincipalName. Error: $_"
    }
}

# Function to upload log file to Azure Blob Storage using az storage
function Upload-LogFileToBlob {
    param (
        [string]$LogFilePath,
        [string]$StorageAccountName,
        [string]$ContainerName,
        [string]$BlobEndpoint,
        [string]$ManagedIdentityClientId  # Add this parameter if using user-assigned managed identity
    )
    
    $currentDate = Get-Date -Format "yyyy/MM/dd"
    $blobPath = "cert-auth/$currentDate/log_$(Get-Date -Format 'yyyyMMddHHmmss').log"
    
    try {
        az login --identity --username $ManagedIdentityClientId --allow-no-subscriptions
        az storage blob upload --account-name $StorageAccountName --container-name $ContainerName --name $blobPath --file $LogFilePath --auth-mode login --output none
        Log-Message "Successfully uploaded log file to $BlobEndpoint$ContainerName/$blobPath"
        Write-Output "Successfully uploaded log file to $BlobEndpoint$ContainerName/$blobPath"
    } catch {
        Log-Message "Failed to upload log file to Azure Blob Storage. Error: $_"
        Write-Output "Failed to upload log file to Azure Blob Storage. Error: $_"
    }
}

# Initialize log file
if (Test-Path $LogFilePath) {
    Remove-Item $LogFilePath
}
New-Item -Path $LogFilePath -ItemType File

# Connect to Azure using Managed Identity
Connect-AzAccount -Identity -AccountId $miAppId | Out-Null

# Get access tokens for both tenants
$AccessTokenA = Get-GraphAPIAccessTokenPost -miAppId $miAppId
$AccessTokenB = Get-AccessToken-AppRegistration -TenantId $TenantBId -ClientId $TenantBClientId -ClientSecret $TenantBClientSecret

# Get group members from both tenants
$MembersA = Get-GroupMembers -AccessToken $AccessTokenA -GroupId $GroupIdA
$MembersB = Get-GroupMembers -AccessToken $AccessTokenB -GroupId $GroupIdB

if ($MembersA -and $MembersB) {
    # Convert to arrays of usernames (stripping domain) and user IDs for comparison and updates
    $UsersA = @{}
    $MembersA | ForEach-Object { $UsersA[$_.userPrincipalName.Split('@')[0]] = $_.id }

    $UsersB = @{}
    $MembersB | ForEach-Object { $UsersB[$_.userPrincipalName.Split('@')[0]] = $_.id }

    # Find matches, only in A, and only in B
    $Matches = $UsersA.Keys | Where-Object { $UsersB.Keys -contains $_ }
    $OnlyInA = $UsersA.Keys | Where-Object { $UsersB.Keys -notcontains $_ }
    $OnlyInB = $UsersB.Keys | Where-Object { $UsersA.Keys -notcontains $_ }

    # Log results
    Log-Message "Matched Users:"
    $Matches | ForEach-Object { Log-Message $_ }

    Log-Message "`nUsers only in Tenant A:"
    $OnlyInA | ForEach-Object { Log-Message $_ }

    Log-Message "`nUsers only in Tenant B:"
    $OnlyInB | ForEach-Object { Log-Message $_ }

    # Update authorization info in Tenant B for matched users
    foreach ($username in $Matches) {
        $UserIdB = $UsersB[$username]
        Update-UserAuthorizationInfo -AccessToken $AccessTokenB -UserId $UserIdB -UserPrincipalName $username
    }
} else {
    Log-Message "Failed to retrieve group members from one or both tenants."
}

# Upload log file to Azure Blob Storage
Upload-LogFileToBlob -LogFilePath $LogFilePath -StorageAccountName $StorageAccountName -ContainerName $ContainerName -BlobEndpoint $BlobEndpoint -ManagedIdentityClientId $miAppId
