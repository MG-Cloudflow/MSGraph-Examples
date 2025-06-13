Below is the full-featured README file in Markdown format:

# Post-Autopilot-Configuration-Assignment

## Overview

**Delayed-Security-Groups.ps1** is a PowerShell runbook script designed to synchronize Azure Active Directory (Azure AD) security groups with their corresponding "Delayed" groups for Intune-managed devices. For each source group whose display name starts with a specified prefix (for example, `sg-intune-automated-`), the script determines which devices have been enrolled for at least 8 hours and ensures that these devices are present in a matching "Delayed" group. This process helps in delaying or staging subsequent processing of devices based on their enrollment duration.

## Features

- **Managed Identity Authentication:**  
  Uses a user-assigned managed identity to authenticate with Microsoft Graph and Azure (Az) services.

- **Optimized Data Retrieval:**  
  Retrieves only the necessary fields from Graph API responses using the `$select` query parameter (e.g., `id`, `displayName`, `deviceId`, `azureADDeviceId`, and `enrolledDateTime`), minimizing network and memory overhead.

- **Paging Support:**  
  Implements automatic paging via a helper function (`Get-AllGraphData`) to retrieve all available data from Graph API endpoints.

- **Group Synchronization:**  
  - Retrieves all Azure AD security groups with a specified prefix while excluding groups whose names already end with the delayed suffix (e.g., `-Delayed`).
  - For each source group, retrieves its members and identifies devices enrolled for 8 or more hours.
  - Checks if a corresponding "Delayed" group exists (named by appending `-Delayed` to the source group's display name); if not, it creates the group.
  - Synchronizes the "Delayed" group by adding qualifying devices that are missing and removing devices that are no longer in the source group.

- **Robust Logging and Reporting:**  
  Logs all actions, errors, and changes to a local log file. Upon completion, the log file is uploaded to an Azure Blob Storage container for auditing and record-keeping.

## Prerequisites

- **PowerShell Modules:**
  - [Microsoft Graph PowerShell SDK](https://docs.microsoft.com/en-us/powershell/microsoftgraph/overview)
  - [Az.Storage Module](https://docs.microsoft.com/en-us/powershell/azure/storage/overview)

- **Authentication:**  
  A user-assigned managed identity is required. The script leverages this identity for authentication using the `-Identity` parameter with both Microsoft Graph and Az cmdlets.

- **Azure Resources:**  
  An Azure Blob Storage account and container (e.g., `delayedsecuritygroups`) must exist. The log file will be uploaded to this container.

## Installation and Configuration

1. **Clone or Download the Repository:**

   ```bash
   git clone https://github.com/your-repo/Sync-DelayedGroups.git
   ```

2. **Configure the Script:**

   Open `Delayed-Security-Groups.ps1` in your preferred text editor and update the following parameters as necessary:

   - **Managed Identity Client ID:**
     ```powershell
     $userAssignedClientId = "FILL IN YOUR MANAGED IDENTITY ID"
     ```
   - **Source Group Prefix and Delayed Suffix:**
     ```powershell
     $SourceGroupPrefix = "FILL IN YOUR GROUP PREFIX"
     $DelayedSuffix = "FILL IN YOUR SUFFIX FOR YOUR DELAYED GROUPS"
     ```
   - **Storage Account Settings:**
     ```powershell
     $StorageAccountName   = "STORAGE ACCOUNT NAME"
     $StorageContainerName = "CONTAINER NAME FOR LOG FILES"
     ```

3. **Install Required Modules:**

   If the required modules are not installed, you can install them using:
   
   ```powershell
   Install-Module -Name Microsoft.Graph -Force
   Install-Module -Name Az.Storage -Force
   ```

## Usage

1. **Run the Script Locally:**

   Open a PowerShell prompt and execute:
   
   ```powershell
   .\Delayed-Security-Groups.ps1
   ```

2. **Run as an Azure Automation Runbook:**

   - Import the script into an Azure Automation account.
   - Ensure that the required modules are imported into the Automation account.
   - Configure the runbook to use the user-assigned managed identity.
   - Schedule or trigger the runbook as needed.

## How It Works

1. **Authentication:**  
   The script authenticates to Microsoft Graph and Azure using a user-assigned managed identity.

2. **Data Retrieval:**  
   - Retrieves all security groups starting with the specified prefix (excluding groups ending with `-Delayed`) using paging and `$select` to limit fields.
   - Fetches all Intune managed devices (selecting only `id`, `azureADDeviceId`, and `enrolledDateTime`) and builds a lookup table keyed on `azureADDeviceId`.
   - Retrieves group members (selecting only `id`, `displayName`, and `deviceId`) for each source group with paging.

3. **Synchronization Process:**  
   For each source group, the script:
   - Identifies devices enrolled for 8 or more hours.
   - Checks for or creates a corresponding "Delayed" group.
   - Synchronizes the "Delayed" group by adding qualifying devices that are missing and removing devices that are no longer in the source group.
   - **Edge Case:** If a device is present in the "Delayed" group but has not yet been enrolled for 8 hours, the script will remove that device from the "Delayed" group, even if it is still a member of the source group. This ensures that only devices meeting the minimum enrollment duration remain in the "Delayed" group.

4. **Logging and Reporting:**  
   All actions, changes, and errors are logged to a local log file, which is then uploaded to an Azure Blob Storage container upon completion.

## Troubleshooting

- **Authentication Issues:**  
  Ensure that your user-assigned managed identity has the necessary permissions in both Azure AD and the target Azure Storage account.

- **Module Errors:**  
  Verify that the Microsoft Graph and Az.Storage modules are installed and imported correctly.

- **API Throttling:**  
  For large numbers of groups or devices, consider reviewing throttling limits in the [Microsoft Graph documentation](https://docs.microsoft.com/en-us/graph/throttling).

## Contribution

Contributions, bug reports, and feature requests are welcome. Please fork the repository and submit a pull request with your changes.

## License

This project is licensed under the [MIT License](LICENSE).

## Contact

For questions or support, please contact [Maxime Guillemin](mailto:mg@cloudflow.be).
```
