param($Context)

$output = @()

Write-Host "Input in Orchestration: $($Context.Input)"
$ticketId = $Context.Input

# Invokes exchange portion
try {
    Write-Host "Starting Exchange portion of orchestration..."
    $outputExchange = Invoke-DurableActivity -FunctionName 'Offboard-Exchange-Portion' -Input "$ticketId"
    Write-Host "Exchange portion finished"
    $output += $outputExchange
} 
catch {
    Write-Error -Message "Error during Exchange portion, $_"
    $output += $outputExchange
}

# Invokes graph portion
try {
    Write-Host "Starting Graph portion of orchestration..."
    $outputGraph = Invoke-DurableActivity -FunctionName 'Offboard-Graph-Portion' -Input "$ticketId"
    Write-Host "Graph portion finished"
    $output += $outputGraph
}
catch {
    Write-Error -Message "Error during Graph portion, $_"
    $output += $outputGraph
}

# Invokes api portion
try {
    Write-Host "Starting API portion of orchestration..."
    $outputAPI = Invoke-DurableActivity -FunctionName 'Offboard-API-Portion' -Input "$ticketId"
    Write-Host "API portion finished"
    $output += $outputAPI
}
catch {
    Write-Error -Message "Error during API portion, $_"
    $output += $outputAPI
}

# Invokes email + freshservice ticket portion
try {
    Write-Host "Starting email + freshservice ticket portion of orchestration..."
    $outputMail = Invoke-DurableActivity -FunctionName 'Offboard-Email-Ticket-Portion' -Input "$ticketId"
    Write-Host "Email portion finished"
    $output += $outputMail
}
catch {
    Write-Error -Message "Error during send email + freshservice ticket portion, $_"
    $output += $outputMail
}
