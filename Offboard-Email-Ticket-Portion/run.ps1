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
    $emailOutput = @{"EmailTicket" = "Unable to retrieve SAS Token for hsautomation01. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
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
    $emailOutput = @{"EmailTicket" = "Unable to retrieve API Token for FreshService. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
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
    $emailOutput = @{"EmailTicket" = "Unable to establish storage context with $storageAccountName with SAS. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
}

# Retrieves table using context established earlier
$tableName = "UserOffboardingStatus"
try {
    $table = Get-AzStorageTable -Name $tableName -Context $storageCtx
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $emailOutput = @{"EmailTicket" = "Unable to retrieve $tableName table. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
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
    $emailOutput = @{"EmailTicket" = "Unable to retrieve Row with $rowKey. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
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
    $emailOutput = @{"EmailTicket" = "Unable to connect to ExchangeOnlineManagement. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
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
    $emailOutput = @{"EmailTicket" = "Unable to connect to Microsoft Graph with managed identity. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
}

# ======================= Verify Requestor, Manager, and CC ======================= #

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

function Get-DisplayName {
    param (
        $identity
    )
    try {
        Write-Host "Getting $identity in Entra..."
        $userEndpoint = "/v1.0/users/$identity"
        $userResponse = Invoke-MgGraphRequest -Method GET -Uri $userEndpoint
        return "$($userResponse.displayName)"
    } catch {
        throw
    }
}

# Confirm manager email address
try {
    Test-Mailbox -identity $offboardStatus.Manager
    Write-Host "Manager: $($offboardStatus.Manager) is an email address"

    try {
        $managerDisplayName = Get-DisplayName -identity $offboardStatus.Manager
        Write-Host "$($offboardStatus.Manager) display name is $managerDisplayName"
    }
    catch {
        $errorMessage = $_.Exception.Message
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        Write-Error -Message "Unable to use Graph API to find $identity's display name. Error: $errorMessage. Line: $lineNumber"
    }
}
catch {
    Write-Host "Unable to find $($offboardStatus.Manager), will check in Entra"
    $findManagerEndpoint = "/v1.0/users/$($offboardStatus.UserPrincipalName)/manager" 
    try {
        $manager = Invoke-MgGraphRequest -Method GET -Uri $findManagerEndpoint
        if ($null -ne $manager.Mail -and $manager.Mail -ne "") {
            Write-Host "Setting manager email to $($manager.Mail)"
            $offboardStatus.Manager = $manager.Mail
            $managerDisplayName = "$($manager.displayName)"
        } else {
            Write-Host "Can't confirm manager's email: $($offboardStatus.Manager)"
            $managerDisplayName = $offboardStatus.Manager
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        Write-Error -Message "$($offboardStatus.FullName) manager property not set or unable to find manager. Error: $errorMessage. Line: $lineNumber"
        $managerDisplayName = $offboardStatus.Manager
    }
}

# Confirm requestor email address
try {
    Test-Mailbox -identity $offboardStatus.Requestor
    Write-Host "Requestor: $($offboardStatus.Requestor) is an email address"
}
catch {
    Write-Host "Unable to find $($offboardStatus.Requestor), will check in Entra"
    try {
        $requestorName = $requestorUsername.Substring(0, $requestorUsername.IndexOf("@"))
        $findRequestorEndpoint = "https://graph.microsoft.com/v1.0/users?filter=startswith(userPrincipalName, '$($requestorName)')"
        $requestorEmail = Invoke-MgGraphRequest -Method GET -Uri $findRequestorEndpoint
        if ($null -ne $requestorEmail.value.Mail -and $requestorEmail.value.Mail -ne "") {
            $offboardStatus.Requestor = $requestorEmail.value.Mail
        } else {
            $emailOutput = @{"EmailTicket" = "Unable to find requestor email: $($offboardStatus.Requestor). No Error"}
            Write-Host "$($emailOutput.EmailTicket) unable to be found"
            return $emailOutput
        }
    }
    catch {
        # Requestor has to be found 
        $errorMessage = $_.Exception.Message
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        $emailOutput = @{"EmailTicket" = "Unable to find requestor email: $($offboardStatus.Requestor). Error: $errorMessage. Line: $lineNumber"}
        Write-Error -Message $emailOutput.EmailTicket
        return $emailOutput
    }
}
# ======================= Send Email To Requestor + Manager + CC Recipients  ======================= #

# HTML body
$htmlBodyOffboard = "
<h2>Offboarding Completed - $($offboardStatus.FullName)</h2>
<hr>
<p><b>Hello Everyone,</b></p>
<p>$($offboardStatus.FullName) ($($offboardStatus.UserPrincipalName)) has been successfully offboarded.</p>
<p>The following actions were taken: </p>
<ul>
    <li>Termed on Host</li>
    <li>Password reset and disabled in AD</li>
    <li>Emails forwarded to <strong>$($offboardStatus.Forward)</strong></li>
    <li>Removed from Group Memberships</li>
    <li>Removed from Global Address Lists</li>
    <li>Termed in Oracle</li>
    <li>Microsoft 365 and other software licenses removed</li>
</ul>
<hr>
<h3>Equipment to be Returned</h3>
<p>Devices - $($offboardStatus.RegisteredIntuneDevicesModel)</p>
<p><b>$managerDisplayName</b>, please coordinate with HR for a shipping label if indicated, then return their IT-issued equipment to:</p>
<br>
<h3><u>North America</u></h3>
<p>IT Returns </p>
<p>220 Circle Drive North</p>
<p>Piscataway, NJ
<h3><u>EMEA</u></h3>
<p>Humanscale c/o Eduardo Garcia </p>
<p>IDA Industrial Estate,</p>
<p>Poppintree Finglas, Dublin D11 XY42</p>
<h3><u>Nogales</u></h3>
<p>Please hand to an IT specialist - Javier Tapia or Sergio Beltran.</p>
<hr>
<p>Thank you very much!</p>
<p>Sincerely,</p>
<p>IT Operations</p>
<p>Ticket URL: <a href='$($offboardStatus.TicketURL)'>$($offboardStatus.TicketSubject)</a></p>
"

$offboardHTMLMsg = "<html><body>" + $htmlBodyOffboard + "</body></html>"
$msgFrom  = "itticket@humanscale.com"

# JSON payload for the draft message
$payloadOffboard = @{
    subject = "Offboard Completed - $($offboardStatus.FullName)"
    body = @{
        contentType = "html"
        content = $offboardHTMLMsg
    }
    toRecipients = @(
        @{
            emailAddress = @{
                address = "$($offboardStatus.Requestor)"
            }
        }
    )
    ccRecipients = @(
        @{
            emailAddress = @{
                address = "$($offboardStatus.Manager)"
            }
        }
    )
}

$emailString = $offboardStatus.CC
$emailArray = $emailString -split ","
foreach ($email in $emailArray) {
    $emailCC = @{
        emailAddress = @{
            address = "$($email)"
        }
    }
    $payloadOffboard.ccRecipients += $emailCC
}

$payloadOffboardJson = $payloadOffboard | ConvertTo-Json -Depth 5

try {
    $newMessageParam = @{
        Uri = "https://graph.microsoft.com/v1.0/users/$msgFrom/messages"
        Body = $payloadOffboardJson
        ContentType = "application/json"
        Method = "POST"
    }
    # Create the draft message
    $newMessage = Invoke-MgGraphRequest @newMessageParam
    
    # Extract the draft message ID
    $messageId = $newMessage.id
    
    # Send the draft message
    $sendEmailParam = @{
        Uri = "https://graph.microsoft.com/v1.0/users/$msgFrom/messages/$messageId/send"
        Method = "POST"
    }
    
    Invoke-MgGraphRequest @sendEmailParam
    Write-Host "Offboarding email sent"
    $offboardStatus.OffboardingEmailSent = $true
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "Unable to send offboarding email. Error: $errorMessage. Line: $lineNumber"
}

# ======================= Send Email To InfraTech  ======================= #

if ($offboardStatus.TimeZone -ne "EST") {
    $estConversionHTML = "<p>Converted to EST: $($offboardStatus.ESTConversion) EST</p>"
} else {$estConversionHTML = ""}

$htmlBodyInfra = 
    "<h2>Offboarding Completed - $($offboardStatus.FullName)</h2>
    <br>
    <p>Offboarded scheduled at $($offboardStatus.TerminationDate) $($offboardStatus.TimeZone)</p>
    $estConversionHTML
    <p>Ticket ID: $($TicketId)</p>
    <p>Ticket URL: <a href='$($offboardStatus.TicketURL)'>$($offboardStatus.TicketSubject)</a></p>
    <br>
    <p><b>Script Status</b></p>
    <p>Does User Have Mailbox: $($offboardStatus.ExchangeFlag)</p>
    <p>Mailbox Converted To Shared: $($offboardStatus.ConvertedToSharedMailbox)</p>
    <p>Was Forwarding Set: $($offboardStatus.ForwardingSet)</p>
    <p>Licenses Removed: $($offboardStatus.LicensesRemoved)</p>
    <p>365 Groups Removed: $($offboardStatus.EntraGroupsRemoved)</p>
    <p>Active Devices In Intune: $($offboardStatus.RegisteredIntuneDevicesName)</p>
    <p>Account Disabled: $($offboardStatus.ADAccountDisabled)</p>
    <p>AD Groups Removed: $($offboardStatus.ADGroupsRemoved)</p>
    <p>In Disabled OU: $($offboardStatus.InDisabledOU)</p>
    <p>Attributes Reset: $($offboardStatus.ResetAttributes)</p>
    <p>Term Date Description: $($offboardStatus.TermDateDescription)</p>
    <p>Offboarding Email Sent: $($offboardStatus.OffboardingEmailSent)</p>
    "

$scheduledHTMLMsg = "<html><body>" + $htmlBodyInfra + "</body></html>"
$msgFrom  = "donotreply@humanscale.com"

$payloadInfra = @{
    subject = "Offboard Completed - $($offboardStatus.FullName)"
    body = @{
        contentType = "html"
        content = $scheduledHTMLMsg
    }
    toRecipients = @(
        @{
            emailAddress = @{
                address = "infratech@humanscale.com"
            }
        }
    )
} | ConvertTo-Json -Depth 5

try {
    $newMessageParam = @{
        Uri = "https://graph.microsoft.com/v1.0/users/$msgFrom/messages"
        Body = $payloadInfra
        ContentType = "application/json"
        Method = "POST"
    }

    # Create the draft message
    $newMessage = Invoke-MgGraphRequest @newMessageParam
    
    # Extract the draft message ID
    $messageId = $newMessage.id
    
    # Send the draft message
    $sendEmailParam = @{
        Uri = "https://graph.microsoft.com/v1.0/users/$msgFrom/messages/$messageId/send"
        Method = "POST"
    }
    
    Invoke-MgGraphRequest @sendEmailParam | Out-Null
    Write-Host "Infratech email sent"
    $offboardStatus.InfraTechEmailSent = $true
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "Unable to send Infratech email. Error: $errorMessage. Line: $lineNumber"
}

# ======================= Sent Private Note to Ticket  ======================= #

$newTicketId = $ticketId -replace "^SR-", ""
$urlFindTicket = "https://humanscale.freshservice.com/api/v2/tickets/$newTicketId"

$paramFindTicket = @{
    Uri = $urlFindTicket
    Method = "GET"
    Headers = @{
        "Content-Type" = "application/json"
        "Authorization" = "Basic $encodedFreshServiceApiKey"
    }
}

# Make the API call with the correct Authorization header
try {
    $responseFindTicket = Invoke-WebRequest @paramFindTicket
    $contentFindTicket = $responseFindTicket.Content | ConvertFrom-Json
    Write-Host "Found ticket $($contentFindTicket.ticket.id) in FreshService"
    $offboardStatus.TicketFound = $true
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    Write-Error -Message "HTTP error while trying to find ticket. Error: $errorMessage. Line: $lineNumber"
}

if ($responseFindTicket.StatusCode -eq 200) {
    try {
        $urlCreateNote = "https://humanscale.freshservice.com/api/v2/tickets/$($contentFindTicket.ticket.id)/notes"
    
        $bodyContent = @{
            body = $scheduledHTMLMsg
        }
    
        $bodyJson = $bodyContent | ConvertTo-Json
    
        $paramCreateNote = @{
            Uri = $urlCreateNote
            Method = "POST"
            Headers = @{
                "Content-Type" = "application/json"
                "Authorization" = "Basic $encodedFreshServiceApiKey"
            }
            Body = $bodyJson
        }
        $responsePrivateNote = Invoke-WebRequest @paramCreateNote
        $contentPrivateNote = $responsePrivateNote.Content | ConvertFrom-Json
        if ($contentPrivateNote.Conversation.body_text -ne "") {
            Write-Host "Created note at $($contentFindTicket.ticket.id) in FreshService"
            $offboardStatus.PrivateNoteCreated = $true
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $lineNumber = $_.InvocationInfo.ScriptLineNumber
        Write-Error -Message "HTTP error while trying to post note on ticket. Error: $errorMessage. Line: $lineNumber"
    }
}

# ======================= Update Storage Table + Return Output ======================= #

try {
    $offboardStatus | Update-AzTableRow -table $cloudTable
    Write-Host "$tableName has been updated"
}
catch {
    $errorMessage = $_.Exception.Message
    $lineNumber = $_.InvocationInfo.ScriptLineNumber
    $emailOutput = @{"EmailTicket" = "Unable to update $tableName. Error: $errorMessage. Line: $lineNumber"}
    Write-Error -Message $emailOutput.EmailTicket
    return $emailOutput
}

$emailOutput = @{"EmailTicket" = "Email Portion Completed"}
return $emailOutput