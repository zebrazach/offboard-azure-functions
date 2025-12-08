using namespace System.Net

param($Request, $TriggerMetadata)

# Extract the function name and inputString from the query parameters
$FunctionName = $Request.Params.FunctionName
$inputString = $Request.Query.inputString  # Gets "inputString" from the query parameters

if (-not $inputString) {
    throw "Error: Query parameter 'inputString' is required."
}
Write-Host "Input String: $inputString"

# Start the durable orchestration with the specified function name and input
$InstanceId = Start-DurableOrchestration -FunctionName $FunctionName -Input $inputString

Write-Host "Started orchestration with ID = '$InstanceId' and input = '$inputString'"

# Return a response with the status URLs
$Response = New-DurableOrchestrationCheckStatusResponse -Request $Request -InstanceId $InstanceId
Push-OutputBinding -Name Response -Value $Response