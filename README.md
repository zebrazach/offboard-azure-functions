# sd-offboard-azure-functions

> Second part offboarding automation that handles user offboarding in Azure Functions.

## Table of Contents
- [sd-offboard-azure-functions](#sd-offboard-azure-functions)
  - [Table of Contents](#table-of-contents)
  - [About](#about)
    - [Debugging](#debugging)
  - [Prerequisites](#prerequisites)
  - [Features](#features)
  - [Configuration](#configuration)
  - [TODO](#todo)

## About

- Located in automation-prod-rg named hs-offboard.
- Project updated locally using VSCode by using Azure Tools extension.
  - To read how to update the project read this: [Develop Azure Functions by using VSCode](https://learn.microsoft.com/en-us/azure/azure-functions/functions-develop-vs-code?tabs=node-v4%2Cpython-v2%2Cisolated-process%2Cquick-create&pivots=programming-language-powershell)

- The app itself is durable functions chained together to run one after the other determined by the Offboard Orchestrator.
  - To read about durable functions: [Durable Functions Overview](https://learn.microsoft.com/en-us/azure/azure-functions/durable/durable-functions-overview?tabs=in-process%2Cnodejs-v3%2Cv1-model&pivots=powershell)
- At the moment, instead of using requirements.psd1 the modules are manually uploaded due to a bug with Exchange Online Management and AzureTables modules.
- Authentication with Graph / Exchange / Azure with this app is done through managed identity.
  - To read about managed identities: [Managed identities](https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity?tabs=portal%2Chttp)
  - To read about assigning Graph permissions with managed identity: [Tutorial - .NET Web app accesses Microsoft Graph as the app](https://learn.microsoft.com/en-us/azure/app-service/scenario-secure-app-access-microsoft-graph-as-app?tabs=azure-powershell)
  - To read about Exchange Online Management with managed identity: [Use Azure managed identities to connect to Exchange Online Powershell](https://learn.microsoft.com/en-us/powershell/exchange/connect-exo-powershell-managed-identity?view=exchange-ps)
  - Managed Identity is primarily designed to utilized RBAC to access Azure resources.
  - It can also be used to assign permissions (Graph / Exchange) in Entra as an enterprise application.

- To get a better understanding of what is happening, first read the Offboard-Orchestrator to see which functions get invoked first. 
    - You can view the code in the portal or by viewing the repository in Github.
- Ensure that you have the proper roles to view these resources and to make any modifications.
- Instead of uploading the entire Graph module (it's massive), we are doing calls directly with the API instead of the Powershell SDK.
- The status of the offboard is directly tied to the row (row key is the FS ticket id) in the table UserOffboardingStatus, which is a NoSQL service.
    - To read about Azure Table Storage: [Azure storage tables overview](https://learn.microsoft.com/en-us/azure/storage/tables/table-storage-overview)

- To check the current cost of running the automation go to the resource group > cost management > cost analysis
- Offboard audit currently uses a scheduled job in hs-offboard (Scheduled-Returned-Device-Check) which runs every 24 hours to see if a device is returned.

### Debugging

- In Application Insight you can go to Investigate > Failures > Exceptions to view error messages, and you can change the time range. You can also go to Logs and input this query and run:
- 
``` 
traces
| where message contains "INFORMATION:"
| where cloud_RoleInstance == "Find cloud_RoleInstance"
| order by timestamp desc
```

- To find a cloud_RoleInstance first do use this query and find the instance that is related to the incident by using this query first. Then find the related instance and copy / paste that in the above code.

```
traces
| where message contains "INFORMATION:"
| order by timestamp desc
```

## Prerequisites
- Necessary Azure roles to view / modify automation-prod-rg

## Features

- Removes licenses + 365 groups + retrieves owned devices for audit
- Set mailbox to Shared and set forwarding
- In `Offboard-API-Portion` it currently creates a ticket to Data Management for EmailMeForm and Quote Tool depending on their department.
- Sends offboarding email to various parties
- Logs to `hsautomation01` for offboard audit

## Configuration

- `USDELDC02` does an API call to the Azure Function via function key stored in Azure Key Vault.

## TODO

- Migrate away from Zach's FS API key