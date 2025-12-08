param($TicketId)

Write-Host "Starting Graph portion of offboard..."

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
    $graphOutput = @{"Graph" = "Unable to retrieve SAS Token for hsautomation01. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $graphOutput.Graph
    return $graphOutput
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
    $graphOutput = @{"Graph" = "Unable to establish storage context with $storageAccountName with SAS. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $graphOutput.Graph
    return $graphOutput
}

# Retrieves table using context established earlier
$tableName = "UserOffboardingStatus"
try {
    $table = Get-AzStorageTable -Name $tableName -Context $storageCtx
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $graphOutput = @{"Graph" = "Unable to retrieve $tableName table. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $graphOutput.Graph
    return $graphOutput
}

# Have to use .CloudTable due to .Net shenanigans
$cloudTable = $table.CloudTable
# Write-Host "cloudTable type is $($cloudTable.GetType())"
$partitionKey = "offboard"
$rowKey = $TicketId

try {
    $offboardStatus = Get-AzTableRow -Table $cloudTable -PartitionKey $partitionKey -RowKey $rowKey
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $graphOutput = @{"Graph" = "Unable to retrieve Row with $rowKey. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $graphOutput.Graph
    return $graphOutput
}

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

# ======================= Find User in Entra ======================= #

try {
    Write-Host "Getting $($offboardStatus.UserPrincipalName) in Entra..."
    $userEndpoint = "/v1.0/users/$($offboardStatus.UserPrincipalName)"
    $userResponse = Invoke-MgGraphRequest -Method GET -Uri $userEndpoint
} catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $graphOutput = @{"Graph" = "Unable to find $($offboardStatus.UserPrincipalName) in Entra. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $graphOutput.Graph
    return $graphOutput
}

# ======================= Remove Assigned Licenses ======================= #

try {
    # Retrieves licenses
    Write-Host "Retrieving information of $($offboardStatus.FullName)'s assigned licenses..."
    $licenseEndpoint = "/v1.0/users/$($userResponse.Id)/licenseDetails"
    $licenseResponse = Invoke-MgGraphRequest -Method GET -Uri $licenseEndpoint

    $skuIdArray = @()
    # Removing assigned licenses by group will cause an error
    ## There might be a simplier solution
    ### When assigning a license via group make sure to include the SkuID in this array
    $licensesAssignedByGroup = @("1c27243e-fb4d-42b1-ae8c-fe25c9616588") #
    if ($licenseResponse.value.Count -gt 0) {
        # Finds the license skuId and assembles that in an array
        foreach ($license in $licenseResponse.value) {
            if ($license.skuId -notin $licensesAssignedByGroup) {
                $skuIdArray += $license.skuId
            }
        }

        $setLicenseBody = @{
            addLicenses = @()
            removeLicenses = $skuIdArray
        } | ConvertTo-Json

        # Removes licenses
        Invoke-MgGraphRequest -Method POST -Uri "/v1.0/users/$($userResponse.Id)/assignLicense" -Body $setLicenseBody -ContentType "application/json" | Out-Null
        Write-Host "$($skuIdArray.Count) licenses removed"
        $offboardStatus.LicensesRemoved = $true
    } else {
        Write-Host "No licenses to be removed"
        $offboardStatus.LicensesRemoved = $true
    }
} 
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "HTTP error while trying to remove licenses, Error: $errorMessage. Line: $lineNumber"
}

# ======================= Remove Assigned 365 Groups ======================= #

try {
    $groupEndpoint = "/v1.0//users/$($userResponse.Id)/memberOf"
    $groupResponse = Invoke-MgGraphRequest -Method GET -Uri $groupEndpoint
    
    # Dynamically assigned groups cannot be removed manually - would have to see the dynamic rules of that group
    foreach ($group in $groupResponse.value) {
        # Make sure to include $ref or it will delete the user entirely
        $groupDeleteEndpoint = "/v1.0/groups/$($group.Id)/members/$($userResponse.Id)/`$ref" 
        try {
            Invoke-MgGraphRequest -Method DELETE -Uri $groupDeleteEndpoint -ErrorAction SilentlyContinue
        }
        catch {
            Write-Host "$($group.Id) is dynamically assigned or can't be removed"
        }
    }
    $offboardStatus.EntraGroupsRemoved = $true
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "HTTP error while trying to find $($userResponse.DisplayName)'s group, Error: $errorMessage. Line: $lineNumber"
}

# ======================= Get Owned Devices in Intune ======================= #

$registeredDevicesName = @()
$registeredDevicesModel = @()
$registeredEntraDevices = @{}

try {
    try {
        # Uses the relationship between Entra and Intune to find registered devices on Intune only
        ## Lists devices that are registered in Entra
        ### If the user doesn't have any devices, will throw error
        Write-Host "Finding registered Entra devices..."
        $entraRegisteredDeviceEndpoint = "/v1.0/users/$($userResponse.Id)/managedDevices"
        $registeredEntraDevices = Invoke-MgGraphRequest -Method GET -Uri $entraRegisteredDeviceEndpoint -ErrorAction SilentlyContinue
    } catch {
        Write-Warning "No devices found in Entra"
    }

    if ($registeredEntraDevices.value.Count -gt 0) {
        Write-Host "Finding registered Intune devices..."
        foreach ($device in $registeredEntraDevices.value) {
            # Looks for the device in Intune
            $intuneManagedDeviceEndpoint = "/v1.0/deviceManagement/managedDevices/$($device.Id)"
            try {
                $registeredIntuneDevices = Invoke-MgGraphRequest -Method GET -Uri $intuneManagedDeviceEndpoint -ErrorAction SilentlyContinue
                $registeredDevicesModel += $registeredIntuneDevices.model
                $registeredDevicesName += $registeredIntuneDevices.deviceName
            }
            catch {
                $errorMessage = $_.Exception.Message
                $lineNumber = $_.InvocationInfo.ScriptLineNumber
                Write-Error -Message "HTTP error while trying to discover $($device.deviceName) in Intune, Error: $errorMessage. Line: $lineNumber"
            }
        }

        if ($registeredEntraDevices.value.Count -gt 1) {
            $intuneDeviceNameList = $registeredDevicesName -join ", "
            $intuneDeviceModelList = $registeredDevicesModel -join ", "
            $offboardStatus.RegisteredIntuneDevicesName = $intuneDeviceNameList
            $offboardStatus.RegisteredIntuneDevicesModel = $intuneDeviceModelList
            Write-Host "Devices in Intune: $($offboardStatus.RegisteredIntuneDevicesModel)"
        } else {
            $offboardStatus.RegisteredIntuneDevicesName = "$registeredDevicesName"
            $offboardStatus.RegisteredIntuneDevicesModel = "$registeredDevicesModel"
            Write-Host "Devices in Intune: $($offboardStatus.RegisteredIntuneDevicesModel)"
        }
    } else {
        Write-Host "No devices associated with $($userResponse.displayName)"
        $offboardStatus.RegisteredIntuneDevicesName = "N/A"
        $offboardStatus.RegisteredIntuneDevicesModel = "N/A"
    }
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "HTTP error while trying to discover managed devices, Error: $errorMessage. Line: $lineNumber"
}

# ======================= Update Storage Table + Return Output ======================= #

try {
    $offboardStatus | Update-AzTableRow -table $cloudTable
    Write-Host "$tableName has been updated"
} 
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $graphOutput = @{"Graph" = "Unable to update $tableName. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $graphOutput.Graph
    return $graphOutput
}

$graphOutput = @{"Graph" = "Graph Portion Completed"}
return $graphOutput