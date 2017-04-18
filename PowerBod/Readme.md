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
    - Azure KeyVault to store credentials for remote commands: <https://docs.microsoft.com/en-us/azure/key-vault/key-vault-get-started> & read access for Automation Account to it
    - To load your RunAs Certififace on your Hybrid Worker: <https://www.powershellgallery.com/packages/Export-RunAsCertificateToHybridWorker/1.0/Content/Export-RunAsCertificateToHybridWorker.ps1>
    - To support managing Windows Servers you should run the following command on the Hybrid Worker:
    `set-item wsman:\localhost\client\TrustedHosts -value * -force`

### Why Hybrid Worker?

I chose to use the Hybrid Worker approach because the alternative was to expose the WinRM & SSH ports to the internet for the remote commands to run which did not feel right.  I did map out an approach which would have identified the source IP for the runbook and dynamically create NSG rules & public IPs if not present but this felt overly complex and risky compared to using Hybrid Workers.

## How it works

You can choose to Tag individual VMs or Resource Groups with the **PowerManagementPolicy** Tag.  Where a Resource Group is Tagged each VM within the resource group is processed using the same Power Management Policy - **If VMs require startup / shut down commands they MUST be of the same Operating System type to work**

### Policy Definition

System Type is required where any start up or shut down scripts are required as it instructs the runbook whether to attempt SSH or WinRM, acceptable values are ***Linux*** or ***Windows***.  The sample below specifies a Linux Virtual Machine

```json
    "SystemType":"Linux"
```

Actions define if this policy is enabled for Starting or Stopping VMs - acceptable values are ***true*** or ***false***.  The sample below enables both Start up and Shut down actions.

```json
"Actions": {
        "Startup" : "true",
        "Shutdown" : "true"
    }
```

Schedules define when the inspected machine should be **on**, in the case of overlapping schedules the first matching schedule will win (processing is aborted when it hits a match).  Schedules have 3 components - ***DaysOfWeek*** acceptable values are any days of the week (full name no abbreviations - Monday not Mon or M), ***StartTime*** and ***EndTime*** acceptable values are valid times in 24hr clock notation. The sample below has two schedules - the first specifies the VM should be **on** each week day between 09:00 and 11:00, the second specifies the VM should be **on** all day at the weekend.

**N.B. Times are in UTC**

```json
"Schedules": [
        {
            "DaysOfWeek": "Monday, Tuesday, Wednesday, Thursday, Friday",
            "StartTime": "09:00",
            "EndTime": "11:00"
        },
        {
            "DaysOfWeek": "Saturday, Sunday",
            "StartTime": "00:00",
            "EndTime": "23:39"
        }
    ]
```

Credentials enable you to specifcy the username and password used for logging on to the VM to perform any required scripts - if there are no scripts defined you can leave this blank.  At this time Certfificates for SSH are not supported.  The password needs to be stored in a KeyVault which the script must have access to in order to read.  Credentials has 3 components - ***KeyVaultName*** this is the name of the KeyVault to use, ***Username*** this is the username to login with , ***PasswordSecret*** this is the name of the secret in the KeyVault which contains the password.  In the sample below the policy defines a KeyVault of *PowerMgmtPolicyVault* a username of *iana* and the secret to read as *PowerMgmtPassword*

**N.B. for Windows it is neccessary to include a domain, for non domain machines prefix the username with a ".\" e.g., ".\iana"**

```json
"Credentials": {
        "KeyVaultName": "PowerMgmtPolicyVault",
        "Username": "iana",
        "PasswordSecret": "PowerMgmtPassword"
    }
```

Shutdown scripts are only required if you would like scripts to be run as part of the shutdown process.  Scripts are stored as an array, processed in sequence.  There are 3 components for each ShutdownScripts entry - ***Command*** the name of the command you wish to run on the remote system - this is required, ***Delay*** the amount of time you wish the system to pause after running the command (in **seconds**) - this is required.  ***ExpectedOutput*** this is optional, if you wish the runbook to check that the output of the command specify it here - if the output does not match the shutdown will be aborted.  In the sample below there are two Shutdown scripts - *pwd* with a delay of *20 seconds* with an expected output of *C:\Users\iana\Documents* (Note the escaping), a second command is then run of *whoami* with a delay of *20 seconds*

**N.B. Each command runs in its own session - so for example a CD in Command 1 would not have any effect in Command 2.  You can chain multiple commands together, e.g. in Linux use the && operator or alternatively have a script on the system which is called by the command**

```json
"ShutdownScripts": [
        {
            "Command": "pwd",
            "Delay": "20",
            "ExpectedOutput": "C:\\Users\\iana\\Documents"
        },
        {
            "Command": "whoami",
            "Delay": "20"
        }
    ]
```

Startup scripts are only required if you would like to run scripts on starting up of a VM, e.g., Warm up scripts for web servers.  Scripts are stored as an array, processed in sequence.  There are 3 components for each ShutdownScripts entry - ***Command*** the name of the command you wish to run on the remote system - this is required, ***Delay*** the amount of time you wish the system to pause after running the command (in **seconds**) - this is required.  ***ExpectedOutput*** this is optional, if you wish the runbook to check that the output of the command specify it here - if the output does not match the start up will be error and furter scripts aborted (the VM will still be running).  In the sample below the command *echo hello* is run with a delay of *15 seconds* afterwards.

**N.B. Each command runs in its own session - so for example a CD in Command 1 would not have any effect in Command 2.  You can chain multiple commands together, e.g. in Linux use the && operator or alternatively have a script on the system which is called by the command**

```json
"StartupScripts": [
        {
            "Command": "echo hello",
            "Delay": "15"
        }
    ]
```

DependsOnVms are only required if you would like to ensure that one or more VMs are running before starting up the inspected VM.  The VMs are stored in an array enabling multiple VMs to be required.  There are 3 components - ***ResourceGroupName*** the Resource Group for the required VM, ***Name*** the name of the required VM and ***Action*** which has two acceptable values - *Start* and *Wait*.  If *Start* is specified any dependent VM will be started by this process else the runbook will wait for the VM until the timeout.  The total timeout is 31 minutes this is based on an initial wait of 60 seconds before checking if the required VM is running again, each retry doubles the wait period and there are a max. of 5 retries.  The sample below would start the VM *vmauditpol* in the resource group *rgPolicyDemo* if it is not running.

```json
"DependsOnVMs": [
        {
            "ResourceGroupName": "rgPolicyDemo",
            "Name": "vmauditpol",
            "Action": "Start"
        }
    ]
```
