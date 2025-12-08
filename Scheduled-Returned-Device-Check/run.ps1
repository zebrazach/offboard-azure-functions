# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' porperty is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

# ======================= Connect to Graph ======================= #

# Uses managed identity - hs-offboard calls Graph API
## Allowed scopes can be viewed in enterprise apps
try {
    Write-Host "Attempting to connect to Microsoft Graph with managed identity..."
    Connect-MgGraph -Identity -NoWelcome
    Write-Host "Connected with Graph via Managed Identities"
} 
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $graphOutput = @{"Graph" = "Unable to connect to Microsoft Graph with managed identity. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $graphOutput.Graph
    return $graphOutput
}

# ======================= Retrieve SAS Token From Keeper ======================= #

$keyVaultName = "hsautomationvault"

try {
    Write-Host "Retrieving hsautomation01 SAS token..."
    $hsautomationSecretName = "hsautomation-SAS-Offboard"
    $hsautomationSASToken = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $hsautomationSecretName -AsPlainText
    Write-Host "SAS token for hsautomation01 retrieved"
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "Unable to retrieve SAS Token for hsautomation01. Error: $errorMessage. Line: $lineNumber"
    return
}

# ======================= Retrieve Offboard Status From Storage Table ======================= #

# Setting up storage context variables for authoritative connection
$storageAccountName = "hsautomation01"
$sasToken = $hsautomationSASToken

# Establishes connection with HSAutomation01 using SAS
try {
    $storageCtx = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $sasToken
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error "Unable to establish storage context with $storageAccountName with SAS. Error: $errorMessage. Line: $lineNumber"
    return
}

# Retrieves table using context established earlier
$tableName = "UserOffboardingStatus"
try {
    $table = Get-AzStorageTable -Name $tableName -Context $storageCtx
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "Unable to retrieve $tableName table. Error: $errorMessage. Line: $lineNumber"
    return
}

# Have to use .CloudTable due to .Net shenanigans
$cloudTable = $table.CloudTable
# Write-Host "cloudTable type is $($cloudTable.GetType())"
$partitionKey = "offboard"

# ============ Validate if Devices Were Wiped / Repurposed ============ #
function Update-OffboardTable {
    param($Table, $PartionKey, $RowKey)

    try {
        $updateRow = Get-AzTableRow -table $cloudTable -PartitionKey $partitionKey -RowKey $RowKey
        $updateRow.Wiped = $true
        $updateRow | Update-AzTableRow -table $cloudTable | Out-Null
    }
    catch {
        Write-Error "Unable to update AzTableRow, $_"
    }
}

$allRows = Get-AzTableRow -table $cloudTable -partitionKey $partitionKey | Where-Object -Property "Wiped" -eq $false

foreach ($row in $allRows) {
    if ($row.RegisteredIntuneDevicesName -ne "N/A") {
        if ($row.RegisteredIntuneDevicesName -notmatch ",") {
            $devices = @($row.RegisteredIntuneDevicesName.Trim())
        } else {
            $devices = ($row.RegisteredIntuneDevicesName).split(",") | ForEach-Object { $_.Trim() }
        }
        $devicesLength = $devices.Length
        $wipedCount = 0

        foreach($device in $devices) {
            try {
                $registeredDeviceEndpoint = "/v1.0/deviceManagement/managedDevices?`$filter=deviceName eq '$device'"
                $registeredDevices = Invoke-MgGraphRequest -Method GET -Uri $registeredDeviceEndpoint
                $registeredDevice = $registeredDevices.value
                Write-Host "$($row.FullName)'s device $device has been found on Intune"
                # $registeredDevice | Out-GridView
                
                if ($registeredDevice.UserPrincipalName -ne $row.UserPrincipalName) {
                    $wipedCount += 1
                }
            }
            catch {
                Write-Error -Message "Http error, unable to find $device for $($row.FullName). $_"
                $wipedCount += 1
            }
        }
        
        if ($devicesLength -eq $wipedCount) {
            Write-Host "All devices wiped/retired for $($row.FullName)"
            Update-OffboardTable -Table $cloudTable -PartionKey $partitionKey -RowKey $row.RowKey
        } else {
            Write-Host "Not all devices registered with $($row.FullName) has been wiped / retired"
        }

    } else {
        Write-Host "No devices registered for $($row.FullName)"
        Update-OffboardTable -Table $cloudTable -PartionKey $partitionKey -RowKey $row.RowKey
    }
}
