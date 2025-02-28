# Script to assign Citrix VDI machines to users based on a CSV file
# For CVAD 2203 LTSR CU5

# Function to get CSV file path using file explorer dialog
function Get-CsvFilePath {
    [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
    
    $OpenFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $OpenFileDialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $OpenFileDialog.Filter = "CSV Files (*.csv)|*.csv|All Files (*.*)|*.*"
    $OpenFileDialog.Title = "Select CSV File with VDI Machine Assignments"
    
    if ($OpenFileDialog.ShowDialog() -eq "OK") {
        return $OpenFileDialog.FileName
    }
    else {
        Write-Host "No file selected. Exiting script." -ForegroundColor Red
        exit
    }
}

# Import Citrix PowerShell modules
Write-Host "Loading Citrix PowerShell modules..." -ForegroundColor Cyan
Add-PSSnapin Citrix* -ErrorAction SilentlyContinue

# Check if modules are loaded properly
if (-not (Get-Command Get-BrokerMachine -ErrorAction SilentlyContinue)) {
    Write-Host "Citrix PowerShell modules not loaded correctly. Please ensure you have the CVAD Remote PowerShell SDK installed." -ForegroundColor Red
    exit 1
}

# Get Broker server name
$brokerServer = Read-Host "Enter the Broker server name (e.g. Citrix01)"

# Connect to the Broker using AdminAddress
Write-Host "Connecting to Citrix Broker on $brokerServer..." -ForegroundColor Cyan
try {
    Set-BrokerSite -AdminAddress $brokerServer -ErrorAction Stop
    Write-Host "Successfully connected to Citrix Broker on $brokerServer" -ForegroundColor Green
} 
catch {
    Write-Host "Failed to connect to Citrix Broker on $brokerServer. Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Get CSV file path
Write-Host "Please select the CSV file with machine assignments..."
$csvFilePath = Get-CsvFilePath

# Start transcript for logging
$logPath = Join-Path $env:TEMP "CitrixAssignment_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logPath

Write-Host "Starting Citrix VDI assignment process" -ForegroundColor Cyan
Write-Host "Using CSV file: $csvFilePath"

# Check if CSV file exists
if (-not (Test-Path $csvFilePath)) {
    Write-Host "CSV file not found at path: $csvFilePath" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# Import CSV file
try {
    $assignments = Import-Csv -Path $csvFilePath
    Write-Host "Successfully imported CSV with $($assignments.Count) records." -ForegroundColor Green
    
    # Check if CSV has required columns
    $requiredColumns = @("MachineName", "UserName", "DeliveryGroupName")
    $csvHeaders = $assignments[0].PSObject.Properties.Name
    $missingColumns = $requiredColumns | Where-Object { $_ -notin $csvHeaders }
    
    if ($missingColumns) {
        Write-Host "CSV file is missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
        Write-Host "Please ensure your CSV has these columns: $($requiredColumns -join ', ')" -ForegroundColor Yellow
        Stop-Transcript
        exit 1
    }
} 
catch {
    Write-Host "Failed to import CSV file: $($_.Exception.Message)" -ForegroundColor Red
    Stop-Transcript
    exit 1
}

# Create a log array to track results
$results = @()

# Process each assignment
foreach ($assignment in $assignments) {
    $machineName = $assignment.MachineName
    $userName = $assignment.UserName
    $deliveryGroupName = $assignment.DeliveryGroupName
    
    Write-Host "`nProcessing: Machine=$machineName, User=$userName, DeliveryGroup=$deliveryGroupName" -ForegroundColor Cyan
    
    # Skip if machine name, username, or delivery group is empty
    if ([string]::IsNullOrWhiteSpace($machineName) -or 
        [string]::IsNullOrWhiteSpace($userName) -or 
        [string]::IsNullOrWhiteSpace($deliveryGroupName)) {
        
        $results += [PSCustomObject]@{
            MachineName = $machineName
            UserName = $userName
            DeliveryGroupName = $deliveryGroupName
            Status = "Skipped - Missing required information"
        }
        
        Write-Host "  Skipped - Missing required information" -ForegroundColor Yellow
        continue
    }
    
    try {
        # Get the machine object
        Write-Host "  Looking up machine: $machineName"
        $machine = Get-BrokerMachine -MachineName $machineName -AdminAddress $brokerServer -ErrorAction Stop
        
        if (-not $machine) {
            $results += [PSCustomObject]@{
                MachineName = $machineName
                UserName = $userName
                DeliveryGroupName = $deliveryGroupName
                Status = "Failed - Machine not found"
            }
            
            Write-Host "  Failed - Machine not found" -ForegroundColor Red
            continue
        }
        
        # Check if machine is in the correct delivery group
        Write-Host "  Checking if machine is in delivery group: $deliveryGroupName"
        if ($machine.DesktopGroupName -ne $deliveryGroupName) {
            $results += [PSCustomObject]@{
                MachineName = $machineName
                UserName = $userName
                DeliveryGroupName = $deliveryGroupName
                Status = "Failed - Machine not in delivery group '$deliveryGroupName'"
            }
            
            Write-Host "  Failed - Machine is in '$($machine.DesktopGroupName)' not in '$deliveryGroupName'" -ForegroundColor Red
            continue
        }
        
        # Assign the user to the machine
        # Format the username to domain\username if it's not already in that format
        if ($userName -notmatch '\\') {
            $domainName = $machine.MachineName.Split('\')[0]
            $formattedUserName = "$domainName\$userName"
        } else {
            $formattedUserName = $userName
        }
        
        Write-Host "  Assigning user: $formattedUserName"
        
        # Check if user exists
        try {
            $user = Get-BrokerUser -Name $formattedUserName -AdminAddress $brokerServer -ErrorAction Stop
            
            # Check if user is already assigned to the machine
            $existingAssignment = Get-BrokerUser -MachineUid $machine.Uid -AdminAddress $brokerServer | 
                                Where-Object { $_.Name -eq $formattedUserName }
            
            if ($existingAssignment) {
                $results += [PSCustomObject]@{
                    MachineName = $machineName
                    UserName = $formattedUserName
                    DeliveryGroupName = $deliveryGroupName
                    Status = "Skipped - User already assigned to machine"
                }
                
                Write-Host "  Skipped - User already assigned to machine" -ForegroundColor Yellow
            }
            else {
                # Add user to machine
                Add-BrokerUser -Name $formattedUserName -Machine $machine.Uid -AdminAddress $brokerServer
                
                $results += [PSCustomObject]@{
                    MachineName = $machineName
                    UserName = $formattedUserName
                    DeliveryGroupName = $deliveryGroupName
                    Status = "Success - User assigned to machine"
                }
                
                Write-Host "  Success - User assigned to machine" -ForegroundColor Green
            }
            
        } catch {
            $results += [PSCustomObject]@{
                MachineName = $machineName
                UserName = $formattedUserName
                DeliveryGroupName = $deliveryGroupName
                Status = "Failed - User not found"
            }
            
            Write-Host "  Failed - User not found" -ForegroundColor Red
        }
        
    } catch {
        $errorMessage = $_.Exception.Message
        $results += [PSCustomObject]@{
            MachineName = $machineName
            UserName = $userName
            DeliveryGroupName = $deliveryGroupName
            Status = "Failed - Error: $errorMessage"
        }
        
        Write-Host "  Failed - Error: $errorMessage" -ForegroundColor Red
    }
}

# Export results to CSV
$resultsPath = Join-Path -Path (Split-Path -Parent $csvFilePath) -ChildPath "AssignmentResults_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$results | Export-Csv -Path $resultsPath -NoTypeInformation

# Display summary
Write-Host "`n------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Assignment process completed. Results saved to: $resultsPath" -ForegroundColor Cyan
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
Write-Host "Summary:"
Write-Host "  Total assignments: $($results.Count)"
$successCount = ($results | Where-Object { $_.Status -like 'Success*' }).Count
$failedCount = ($results | Where-Object { $_.Status -like 'Failed*' }).Count
$skippedCount = ($results | Where-Object { $_.Status -like 'Skipped*' }).Count
Write-Host "  Successful: $successCount" -ForegroundColor Green
Write-Host "  Failed: $failedCount" -ForegroundColor Red
Write-Host "  Skipped: $skippedCount" -ForegroundColor Yellow
Write-Host "------------------------------------------------------------" -ForegroundColor Cyan

# Stop transcript
Stop-Transcript

Write-Host "Detailed log saved to: $logPath" -ForegroundColor Cyan