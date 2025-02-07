Connect-MgGraph


function Get-Reports {
    param (
        [Parameter(Mandatory = $true)]
        [string]$body
    )

    # The URL to initiate the export job
    $reportsUrl = "https://graph.microsoft.com/beta/deviceManagement/reports/exportJobs"

    try {
        # Attempt to initiate the export job by sending a POST request
        $response = Invoke-MgGraphRequest -Uri $reportsUrl -Method POST -Body $body -ContentType "application/json"
    } catch {
        # If there's an error during the request, display an error message and exit the function
        Write-Error "Failed to initiate report export job: $_"
        return
    }

    # Construct the URL to check the status of the report
    $reportResponseUrl = "$reportsUrl/$($response.id)"
    $sleepDuration = 30  # Duration to wait before checking the status again

    do {
        try {
            # Attempt to get the current status of the report by sending a GET request
            $report = Invoke-MgGraphRequest -Uri $reportResponseUrl -Method GET
        } catch {
            # If there's an error during the request, display an error message and exit the function
            Write-Error "Failed to get report status: $_"
            return
        }

        if ($report.status -eq "completed") {
            # If the report is completed, proceed to download and extract it
            $currentDate = (Get-Date).ToString("ddMMyyyy")
            $localZipPath = ".\reports\$($report.reportName)-$currentDate.zip"

            try {
                # Attempt to download the report as a zip file
                .\azcopy.exe copy $report.url $localZipPath
                
                # Attempt to extract the zip file to the destination folder
                Expand-Archive -Path $localZipPath -DestinationPath ".\reports\$($currentDate)\" -Force

                # Assuming the extracted file has the same name as the report, rename it

                # Clean up by removing the downloaded zip file
                Remove-Item -Path $localZipPath -Force
                Write-Output "File downloaded successfully and saved to $localFilePath"
                return $report
            } catch {
                # If there's an error during the download, extraction, or renaming process, display an error message and exit the function
                Write-Error "Failed to download or extract report: $_"
                return
            }
        } else {
            # If the report is not yet completed, wait for a while before checking again
            Write-Output "Waiting for completed report..."
            Start-Sleep -Seconds $sleepDuration
        }

    } while ($report.status -ne "completed")  # Continue checking until the report is completed
}


$body = @"
        { 
            "reportName": "Devices", 
            "filter":"(OwnerType eq '1') and (ManagementAgents eq 'mdm') and (DeviceType eq 'WindowsRT')", 
            "localizationType": "LocalizedValuesAsAdditionalColumn", 
            "format": "csv",
            "select": [ 
                "DeviceName", 
                "managementAgent", 
                "ownerType", 
                "DeviceType",
                "OS", 
                "OSVersion",
                "SkuFamily",
                "UPN",
                "UserName"
                
            ]
        }
"@

Get-Reports -body $body

Disconnect-MgGraph

