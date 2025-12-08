param($TicketId)

Write-Host "Starting Exchange portion of offboard..."

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
    $exchangeOutput = @{"Exchange" = "Unable to retrieve SAS Token for hsautomation01. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $exchangeOutput.Exchange
    return $exchangeOutput
}

# ======================= Retrieve Offboard Status From Storage Table ======================= #

# Setting up storage context variables for authoratative connection
$storageAccountName = "hsautomation01"
$sasToken = $hsautomationSASToken

# Establishes connection with HSAutomation01 using SAS
try {
    $storageCtx = New-AzStorageContext -StorageAccountName $storageAccountName -SasToken $sasToken
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $exchangeOutput = @{"Exchange" = "Unable to establish storage context with $storageAccountName with SAS. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $exchangeOutput.Exchange
    return $exchangeOutput
}

# Retrieves table using context established earlier
$tableName = "UserOffboardingStatus"
try {
    $table = Get-AzStorageTable -Name $tableName -Context $storageCtx
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $exchangeOutput = @{"Exchange" = "Unable to retrieve $tableName table. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $exchangeOutput.Exchange
    return $exchangeOutput
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
    $exchangeOutput = @{"Exchange" = "Unable to retrieve Row with $rowKey. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $exchangeOutput.Exchange
    return $exchangeOutput
}

# ======================= Check Exchange Flag ======================= #

if ($offboardStatus.ExchangeFlag -eq $false) {
    Write-Host "Exchange Flag set to false, will skip Exchange portion"
    $exchangeOutput = @{"Exchange" = "Exchange Flag False"}
    return $exchangeOutput
} else {
    Write-Host "Exchange Flag set to $($offboardStatus.ExchangeFlag), continuing Exchange portion..."
}

# ======================= Connect to Exchange ======================= #

# Using managed identity - hs-offboard calls the exchangeonlinemanagement API
## It is able to perform actions with the Exchange Administrator role assigned to the service principal (hs-offboard as an enterprise application) in Entra
### hs-offboard is assigned both Exchange.ManageAsApp and Exchange Administrator to both use the API and be authorized to perform actions
try {
    Write-Host "Attempting to connect to ExchangeOnlineManagement with managed identity..."
    Connect-ExchangeOnline -ManagedIdentity -Organization humanscale.onmicrosoft.com
    Write-Host "Connected with ExchangeOnlineManagement via Managed Identities"
} 
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $exchangeOutput = @{"Exchange" = "Unable to connect to ExchangeOnlineManagement. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $exchangeOutput.Exchange
    return $exchangeOutput
}

# ======================= Verify Email  ======================= #

function Test-Mailbox {
    param (
        $identity
    )
    try {
        Get-ExoMailbox -identity $identity -ErrorAction Stop | Out-Null
    } 
    catch {
        throw
    }
}

# ======================= Determine If User Has Mailbox + Convert Shared Mailbox + Forwarding ======================= #

# Verify User Mailbox
try {
    $userMailbox = Get-ExoMailbox -Identity "$($offboardStatus.Mail)" -Properties DisplayName, RecipientType, RecipientTypeDetails -ErrorAction Stop
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $exchangeOutput = @{"Exchange" = "Unable to find $($offboardStatus.Mail) mailbox. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $exchangeOutput.Exchange
    return $exchangeOutput
}

# Set mailbox to shared mailbox
try {
    if ($userMailbox.RecipientType -eq "UserMailbox" -and $userMailbox.RecipientTypeDetails -ne "SharedMailbox") {
        Set-Mailbox -Identity $offboardStatus.Mail -Type Shared -ErrorAction Stop
        Write-Host "$($userMailbox.DisplayName) mail is now set to Shared"
        $offboardStatus.ConvertedToSharedMailbox = $true
    } else {
        Write-Host "$($userMailbox.DisplayName) is not a user mailbox or already set to shared"
        $offboardStatus.ConvertedToSharedMailbox = $true
    }
} catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "Unable to convert user mailbox to shared mailbox. Error: $errorMessage. Line: $lineNumber"
}


#Set forwarding to forwarding field in the ticket
if (($null -ne $offboardStatus.Forward -and $offboardStatus.Forward -ne "") -and ($offboardStatus.ConvertedToSharedMailbox -eq $true)) {
    try {
        Test-Mailbox -identity $offboardStatus.Forward -ErrorAction Stop
        Set-Mailbox -Identity $offboardStatus.Mail -ForwardingAddress $offboardStatus.Forward -ErrorAction Stop
        Write-Host "Forwarding set to $($offboardStatus.Forward)"
        $offboardStatus.ForwardingSet = $true
    } 
    catch {
        $errorMessage = $_.Exception.Message
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        Write-Error -Message "Unable to set forwarding to $($offboardStatus.Forward). Error: $errorMessage. Line: $lineNumber"
    }
} else {
    Write-Host "Forwarding not required"
}

# ======================= Update Storage Table + Return Output ======================= #

try {
    $offboardStatus | Update-AzTableRow -table $cloudTable
    Write-Host "$tableName has been updated"
} 
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $exchangeOutput = @{"Exchange" = "Unable to update $tableName. Error: $errorMessage. Line: $lineNumber"}
    Write-Error $exchangeOutput.Exchange
    return $exchangeOutput
}

$exchangeOutput = @{"Exchange" = "Exchange Portion Completed"}
return $exchangeOutput