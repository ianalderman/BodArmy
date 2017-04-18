# PowerBod
Power Bod builds on the great Azure Automation run books which enable you to stop and start machines on a schedule and thus exercise a little more control over your costs.  Why did I write this Runbook?  Customers noted that they had machines for which the existing solutions did not work because the shutdown window was not long enough to cleanly stop services that were running - leading to crash consistent start ups.  

## Features
This runbook supports:

    - Power Management Policies can be stored in Tag Value or can be loaded from Azure Blob storage - enabling support of policies longer than the Azure Tag Value limit of 256 charachters
    - Multiple Schedules within a single policy
    - Multiple Linux & Windows startup scripts in sequence with delays between each script / command
    - Multiple Linux & Windows shut down scripts in sequence with delays between each script / command
    - Check output of commands to ensure they match expected output
    - Start up dependencies - ensure a Virtual Machine is already running before this starts with the option to start if not
    - Parallel processing so that shutdown scripts with long delays do not prevent other machines shutting down

## Requirements

In order to use this runbook you will need:

    - Azure Automation account configured: <https://docs.microsoft.com/en-us/azure/automation/automation-offering-get-started>
    - Hybrid Worker for your automation account see: <https://docs.microsoft.com/en-us/azure/automation/automation-hybrid-runbook-worker>
    - On the Hybrid Worker you will need to install the following modules:
        - AzureRM.Profile
        - AzureRM.Network
        - AzureRM.KeyVault
        - Posh-SSH
    - Azure KeyVault to store credentials for remote commands: <https://docs.microsoft.com/en-us/azure/key-vault/key-vault-get-started>
    - To load your RunAs Certififace on your Hybrid Worker: <https://www.powershellgallery.com/packages/Export-RunAsCertificateToHybridWorker/1.0/Content/Export-RunAsCertificateToHybridWorker.ps1>
    - To support managing Windows Servers you should run the following command on the Hybrid Worker:
    ```set-item wsman:\localhost\client\TrustedHosts -value * -force```

### Why Hybrid Worker?

I chose to use the Hybrid Worker approach because the alternative was to expose the WinRM & SSH ports to the internet for the remote commands to run which did not feel right.  I did map out an approach which would have identified the source IP for the runbook and dynamically create NSG rules & public IPs if not present but this felt overly complex and risky compared to using Hybrid Workers.

## How it works

You can choose to Tag individual VMs or Resource Groups with the **PowerManagementPolicy** Tag.  Where a Resource Group is Tagged each VM within the resource group is processed using the same Power Management Policy - **If VMs require startup / shut down commands they MUST be of the same Operating System type to work**



