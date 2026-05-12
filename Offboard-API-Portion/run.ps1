param($TicketId)

# ======================= Retrieve API Secrets In Keeper ======================= #

# Uses managed identity and RBAC to access secrets in the hsautomationvault
## SCIM key is on Monday.com admin if you need to regenerate and update versions in KeyVault
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
    $APIOutput = @{"API" = "Unable to retrieve SAS Token for hsautomation01. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $APIOutput.API
    return $APIOutput
}

try {
    Write-Host "Retrieving Monday SCIM API token..."
    $mondaySecretName = "Monday-SCIM-Offboard"
    $mondayAPIToken = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $mondaySecretName -AsPlainText
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $APIOutput = @{"API" = "Unable to retrieve API Token for SCIM Monday.com. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $APIOutput.API
    return $APIOutput
}

try {
    Write-Host "Retrieving FreshService API key..."
    $freshServiceSecretName = "FreshService-API-Zcoronacion"
    $freshServiceApiKey = Get-AzKeyVaultSecret -VaultName $keyVaultName -Name $freshServiceSecretName -AsPlainText
    $encodedFreshServiceApiKey = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$freshServiceApiKey"))
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $APIOutput = @{"API" = "Unable to retrieve API Token for FreshService. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $APIOutput.API
    return $APIOutput
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
    $APIOutput = @{"API" = "Unable to establish storage context with $storageAccountName with SAS. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $APIOutput.API
    return $APIOutput
}

# Retrieves table using context established earlier
$tableName = "UserOffboardingStatus"
try {
    $table = Get-AzStorageTable -Name $tableName -Context $storageCtx
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $APIOutput = @{"API" = "Unable to retrieve $tableName table. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $APIOutput.API
    return $APIOutput
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
    $APIOutput = @{"API" = "Unable to retrieve Row with $rowKey. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $APIOutput.API
    return $APIOutput
}

# ======================= Monday SCIM API ======================= #

# SCIM only works with users provisoned through SCIM (ex. via Entra)
## Didn't know this before setting this up but atleast it tells you if they are active and the type of user
### Couldn't figure out the query to filter users with custom header - so I pray we don't have more than 500 monday users or we have to do loops
$count = 500
$startIndex = 1
$scimURL = "https://humanscaleit.monday.com/scim/v2/Users?scim_provisioned_only=false&count=$count&startIndex=$startIndex"

$paramMonday = @{
    Uri = $scimURL
    Method = "Get"
    Headers = @{
        "Authorization" = "Bearer $mondayAPIToken"
        "Accept" = "application/json"
    }
}

try {
    $mondayResponseAllUsers = Invoke-WebRequest @paramMonday
    Write-Host "Monday Status Code: $($mondayResponseAllUsers.StatusCode)"
    Write-Host "Monday Status Description: $($mondayResponseAllUsers.StatusDescription)"
    $mondayAllUsersData = $mondayResponseAllUsers.Content | ConvertFrom-Json
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "HTTP error for SCIM API request, Error: $errorMessage. Line: $lineNumber"
}

# Everyone with a Monday license should have an email - hopefully
if ($offboardStatus.ExchangeFlag -ne $false) {
    if ($mondayResponseAllUsers.StatusCode -eq 200) {
    
        $mondayUsername = $offboardStatus.Mail
    
        if ($mondayAllUsersData.Resources.userName -contains $mondayUsername) {

            Write-Host "$mondayUsername is in Monday.com"
            $matchedUser = $mondayAllUsersData.Resources | Where-Object { $_.userName -eq $mondayUsername }

            Write-Host "Active: $($matchedUser.Active)"
            Write-Host "User Type: $($matchedUser.userType)"

            $offboardStatus.MondayUser = $true
            $offboardStatus.MondayActive = $matchedUser.Active
            $offboardStatus.MondayUserType = $matchedUser.userType
        } else {
            Write-Host "$($offboardStatus.FullName) is not in Monday"
        }
    }
} else {
    Write-Host "$($offboardStatus.FullName) is not in Monday"
}

# ======================= FreshService API ======================= # 

# Not 100% if a user can have a FreshService account without having an email - need to double check
if ($offboardStatus.ExchangeFlag -eq $false) {
    $freshServiceEmail = $offboardStatus.UserPrincipalName
} else {
    $freshServiceEmail = $offboardStatus.Mail
}

# Finds requestor in FreshService
try {
    $urlFindRequester = "https://humanscale.freshservice.com/api/v2/requesters?email=$freshServiceEmail"

    $paramFindRequester = @{
        Uri = $urlFindRequester
        Method = "Get"
        Headers = @{
            "Content-Type" = "application/json"
            "Authorization" = "Basic $encodedFreshServiceApiKey"
        }
    }

    $responseFindRequester = Invoke-WebRequest @paramFindRequester
    $contentFindRequester = $responseFindRequester.Content | ConvertFrom-Json
    if ($contentFindRequester.requesters.count -gt 0) {
        Write-Host "$freshServiceEmail is in FreshService"
        $offboardStatus.FreshServiceUser = $true
    } else {
        Write-Host "$freshServiceEmail is not in FreshService"
    }
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "HTTP error while trying to find $freshServiceEmail in FreshService. Error: $errorMessage. Line: $lineNumber"
}

if (($contentFindRequester.requesters.active -eq $true) -and ($contentFindRequester.requesters.count -gt 0)) {
    Write-Host "$freshServiceEmail is active in FreshService"
    try {
        $urlDeactivateRequester = "https://humanscale.freshservice.com/api/v2/requesters/$($contentFindRequester.requesters.Id)"
    
        $paramDeactivateRequester = @{
            Uri = $urlDeactivateRequester
            Method = "Delete"
            Headers = @{
                "Content-Type" = "application/json"
                "Authorization" = "Basic $encodedFreshServiceApiKey"
            }
        }
    
        $responseDeactivateRequester = Invoke-WebRequest @paramDeactivateRequester
        Write-Host "Status Code: $($responseDeactivateRequester.StatusCode), $freshServiceEmail deactivated in FreshService"
        $offboardStatus.FreshServiceDeactivated = $true
    }
    catch {
        $errorMessage = $_.Exception.Message
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        Write-Error -Message "HTTP error while trying to deactivate $freshServiceEmail in FreshService. Error: $errorMessage. Line: $lineNumber"
    }
}

# EmailMeForm Ticket Post for Data Management
## Requested to be commented out due to Sabrina checking AD flags now

$urlPostTicketEmailMeForm = "https://humanscale.freshservice.com/api/v2/tickets"

$bodyPostTicketEmailMeForm = @{
    description    = "
    <b>This ticket is to remind you to remove the offboarded user's access & license for EmailMeForm.</b>
    <hr>
    <p>The Original Ticket # - $($offboardStatus.RowKey)</p>
    <br>
    <p>User - $($offboardStatus.FullName)</p>
    <br>
    <p>Username - $($offboardStatus.UserPrincipalName)</p>
    <br>
    <p>Department - $($offboardStatus.Department)</p>
    "
    subject        = "EmailMeForm Access | Ticket# $($offboardStatus.RowKey)-$($offboardStatus.TicketSubject)"
    email          = "sliriano@humanscale.com"
    priority       = 1
    status         = 3
    group_id       = 20000342969
    responder_id   = 20000792810
    category       = "Access Rights"
    sub_category   = "EmailMeForm"
    item_category  = "Access and License"
    source         = 2
    cc_emails      = @("aparham@humanscale.com", "tfreivald@humanscale.com") # Data management members responsible for EmailMeForm
    workspace_id   = 2
}

$jsonBodyPostTicketEmailMeForm = $bodyPostTicketEmailMeForm | ConvertTo-Json -Depth 10 -Compress

$paramPostTicketEmailMeForm = @{
    Uri     = $urlPostTicketEmailMeForm
    Method  = "POST"
    Headers = @{
        "Content-Type" = "application/json"
        "Authorization" = "Basic $encodedFreshServiceApiKey"
    }
    Body    = $jsonBodyPostTicketEmailMeForm
}

try {
    if (($offboardStatus.Department -like "*Customer Care*") -or ($offboardStatus.Department -like "*Finance*") -or ($offboardStatus.Department -like "*Accounting*")) {
        Write-Host "EmailMeForm ticket created, $($offboardStatus.FullName) is in $($offboardStatus.Department)"
        Invoke-WebRequest @paramPostTicketEmailMeForm | Out-Null
    }
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "HTTP error while trying to post EmailMeForm ticket. Error: $errorMessage. Line: $lineNumber"
}

# Quote Tool Ticket Post for Data Management

# $urlPostTicketQuoteTool = "https://humanscale.freshservice.com/api/v2/tickets"

# $bodyPostTicketQuoteTool = @{
#     description    = "
#     <b>This ticket is to remind you to remove the offboarded user's access for Quote Tool.</b>
#     <hr>
#     <p>The Original Ticket # - $($offboardStatus.RowKey)</p>
#     <br>
#     <p>User - $($offboardStatus.FullName)</p>
#     <br>
#     <p>Username - $($offboardStatus.UserPrincipalName)</p>
#     <br>
#     <p>Department - $($offboardStatus.Department)</p>
#     "
#     subject        = "Quote Tool Access | Ticket# $($offboardStatus.RowKey)-$($offboardStatus.TicketSubject)"
#     email          = "sliriano@humanscale.com"
#     priority       = 1
#     status         = 3
#     group_id       = 20000342969
#     responder_id   = 20000792810
#     category       = "Access Rights"
#     sub_category   = "Quote Tool"
#     item_category  = "Quote Tool"
#     source         = 2
#     cc_emails      = @("aparham@humanscale.com", "tfreivald@humanscale.com") # Data management members responsible for EmailMeForm
#     workspace_id   = 2
# }

# $jsonBodyPostTicketQuoteTool = $bodyPostTicketQuoteTool | ConvertTo-Json -Depth 10 -Compress

# $paramPostTicketQuoteTool = @{
#     Uri     = $urlPostTicketQuoteTool
#     Method  = "POST"
#     Headers = @{
#         "Content-Type" = "application/json"
#         "Authorization" = "Basic $encodedFreshServiceApiKey"
#     }
#     Body    = $jsonBodyPostTicketQuoteTool
# }

# try {
#     if (($offboardStatus.Department -like "*Customer Care*") -or ($offboardStatus.Department -like "*Finance*") -or ($offboardStatus.Department -like "*Sale*")) {
#         Write-Host "Quote Tool ticket created, $($offboardStatus.FullName) is in $($offboardStatus.Department)"
#         Invoke-WebRequest @paramPostTicketQuoteTool | Out-Null
#     }
# }
# catch {
#     $errorMessage = $_.Exception.Message
#     $lineNumber = $_.InvocationInfo.ScriptLineNumber
#     Write-Error -Message "HTTP error while trying to post Quote Tool ticket. Error: $errorMessage. Line: $lineNumber"
# }

# ======================= Update Storage Table + Return Output ======================= #

try {
    $offboardStatus | Update-AzTableRow -table $cloudTable
    Write-Host "$tableName has been updated"
} 
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $APIOutput = @{"API" = "Unable to update $tableName. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $APIOutput.API
    return $APIOutput
}

$APIOutput = @{"API" = "API Portion Completed"}
return $APIOutput