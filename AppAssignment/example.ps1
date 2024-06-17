# Install the Microsoft Graph PowerShell module if it's not already installed
if (-not (Get-InstalledModule -Name Microsoft.Graph.Beta -ErrorAction SilentlyContinue)) {
    Install-Module -Name Microsoft.Graph.Beta -Scope CurrentUser -Force
}

# Import the Microsoft Graph module
Import-Module Microsoft.Graph

# Authenticate with Microsoft Graph interactively
Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All"

# Prompt user for the app ID
$appId = Read-Host "Please enter the app ID"

# Function to get current assignments for the app
function Get-AppAssignments {
    param (
        [string]$AppId
    )
    $assignmentsUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($AppId)/assignments"
    $currentAssignments = Invoke-MgGraphRequest -Method GET -Uri $assignmentsUri
    return $currentAssignments
}

# Function to update assignments for the app
function Update-AppAssignments {
    param (
        [string]$AppId,
        [array]$Assignments
    )
    $assignmentsJson = $Assignments | ConvertTo-Json -Depth 10
    $updateUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$($AppId)/assign"
    Invoke-MgGraphRequest -Method POST -Uri $updateUri -Body $assignmentsJson
    Write-Output "App assignments updated successfully."
}

# Retrieve current assignments
$currentAssignments = Get-AppAssignments -AppId $appId
Write-Output "Current Assignments:"
Write-Output $currentAssignments

# Define the new assignments
$newAssignments = @(
    @{
        "target" = @{
            "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
            "groupId" = "your-group-id-here"  # Replace with the group ID you want to assign
        }
        "intent" = "available"  # Can be "available", "required", or "uninstall"
    }
)

# Update the app assignments
Update-AppAssignments -AppId $appId -Assignments $newAssignments
