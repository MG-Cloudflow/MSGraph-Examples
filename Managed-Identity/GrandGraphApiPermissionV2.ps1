<#
.SYNOPSIS
    This script assigns Microsoft Graph API permissions to a managed identity in Azure AD.

.DESCRIPTION
    The script authenticates to Azure AD using a specified tenant ID and assigns a set of permissions to a managed identity service principal for Microsoft Graph API. It performs the following actions:
    - Connects to Azure AD using the provided tenant ID.
    - Retrieves the service principal ID for the managed identity.
    - Assigns the specified permissions to the managed identity by updating the service principal.

.PARAMETER principalId
    The service principal ID of the managed identity for the web app.

.PARAMETER permissions
    An array of Microsoft Graph API permissions to assign to the managed identity. Default permissions are:
    - "APIConnectors.ReadWrite.All"
    - "DeviceManagementConfiguration.ReadWrite.All"
    - "DeviceManagementManagedDevices.Read.All"
    - "User.Read.All"

.NOTES
    Version:        V 2.0
    Author:         Maxime Guillemin
    Creation Date:  08/06/2024
    Purpose/Change: Demo Version
#>

# Install the Microsoft Graph PowerShell module if not already installed.
# Install-Module Microsoft.Graph -force -Scope CurrentUser
#Import-Module Microsoft.Graph

# Define your parameters.

    $principalId = "e9ec857f-acd7-4b2a-9827-e9f40df212d7"
    $permissions = @(
        "GroupMember.ReadWrite.All", 
        "Directory.ReadWrite.All",
        "DeviceManagementManagedDevices.Read.All"
  )


# Connect to Microsoft Graph.
Connect-MgGraph -Scopes "Application.ReadWrite.All", "Directory.ReadWrite.All", "RoleManagement.ReadWrite.Directory, AppRoleAssignment.ReadWrite.All"

# Get the service principal for Microsoft Graph.
$GraphServicePrincipal = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

# Assign permissions to the managed identity service principal.
foreach ($p in $permissions) {
    $AppRole = $GraphServicePrincipal.AppRoles | Where-Object { $_.Value -eq $p -and $_.AllowedMemberTypes -contains "Application" }
    
    if ($AppRole) {
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId -PrincipalId $principalId -ResourceId $GraphServicePrincipal.Id -AppRoleId $AppRole.Id
    } else {
        Write-Host "Permission $p not found."
    }
}

# Disconnect from Microsoft Graph.
Disconnect-MgGraph