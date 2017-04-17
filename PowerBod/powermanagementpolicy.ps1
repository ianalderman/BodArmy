workflow rb-PowerManagement
{
    LogOutput "Run Starting" "Begin" "*/*"
    #!! Node Safe Mode is only safe in as much as it doesn't shutdown a machine - it executes scripts / starts
    $SafeMode = $false
    $Var1 = "WorkflowScopedVariable"
    function LogOutput($Msg, $Level, $VM) {
        Write-Output "$(Get-Date), $($Msg), $($Level), $($VM)"
    }

    function LogOperation($Msg, $Operation, $VM) {
        Write-Output "$(Get-Date), $($Msg), $($Operation), $($VM)"
    }

    function ParseSchedules($Schedules) {
        #For each schedule determine if the current time falls inside it if so stop and return PowerState/running to indicate machine should be running
        #Return PowerState/deallocated to indicate machine should be off.  
        $ScheduleFound = $false
        $now = (Get-Date).ToUniversalTime()

        #Assume we don't have a matching schedule and so the machine should be off
        $TargetPowerState = "PowerState/deallocated"

        foreach ($Schedule in $Schedules) {
            #Does this schedule apply today?
            if([string]$Schedule.DaysOfWeek -Match [string](Get-Date).DayOfWeek) {
                #Does the start and end time for the schedule fall between the current time
                if($now -ge $Schedule.StartTime -and $now -le $Schedule.EndTime -and $ScheduleFound -ne $true) {
                    $TargetPowerState = "PowerState/running"
                    #We have a match so stop processing schedules
                    $ScheduleFound = $true
                    Write-Host "Schedule Found: $($Schedule.DaysofWeek) / $($Schedule.StartTime) - $($Schedule.EndTime)", "Debug", "$($VM.ResourceGroupName)/$($VM.Name)"
                } 
            }   
        }
        Return $TargetPowerState
    }
 
    $connectionName = "AzureRunAsConnection"
    try
    {
        # Get the connection "AzureRunAsConnection "
        $servicePrincipalConnection=Get-AutomationConnection -Name $connectionName         

        "Logging in to Azure..."
        Add-AzureRmAccount `
            -ServicePrincipal `
            -TenantId $servicePrincipalConnection.TenantId `
            -ApplicationId $servicePrincipalConnection.ApplicationId `
            -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint 
    }
    catch {
        if (!$servicePrincipalConnection)
        {
            $ErrorMessage = "Connection $connectionName not found."
            throw $ErrorMessage
        } else{
            Write-Error -Message $_.Exception
            throw $_.Exception
        }
    }

    # Get a list of the Resources which are tagged for us to work with
    $VMs = Find-AzureRmResource -TagName "PowerManagementPolicy" | Where-Object {$_.ResourceType -eq "Microsoft.Compute/VirtualMachines"}
    $ResourceGroups = Find-AzureRmResourceGroup -Tag @{PowerManagementPolicy = $null}

    if ($ResourceGroups) {
        foreach ($RG in $ResourceGroups) {
            $RGVMs = (Get-AzureRmVM -ResourceGroupName $RG.Name)
            $RGVMs = $RGVMs | Where {$_.Name -notin $VMs.Name}
            if ($RGVMs) {
                $VMs = $VMs + $RGVMs
            }
        }
    }

    #Process VMs first so that if a VM has policy that overrides the Resource group we can capture it#
    foreach -Parallel ($VM in $VMs) {
        sequence {
            $PowerMgmtPolicy = $null
            $TargetPowerState = $null
            #You can't use "break" in Workflows(!) so below variable will be used to skip executions if we have encountered a break condition..
            $bAborted = $false
            try {
                LogOutput "Retrieving Power Management Policy for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Info" "$($VM.ResourceGroupName)/$($VM.Name)"
                $PowerMgmtPolicy = (Get-AzureRmVM -Name $VM.Name -ResourceGroupName $VM.ResourceGroupName).Tags.PowerManagementPolicy

                if (!$PowerMgmtPolicy) {
                    LogOutput "No Power Management Policy Tag found on VM:  $($VM.ResourceGroupName)/$($VM.Name) checking Resource Group" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                    $PowerMgmtPolicy = (Get-AzureRmResourceGroup -ResourceGroupName $VM.ResourceGroupName).Tags.PowerManagementPolicy
                }

                if (!$PowerMgmtPolicy) {
                    $bAborted = $true
                    LogOutput "No Power Management Policy Tag found on VM or Resource Group for:  $($VM.ResourceGroupName)/$($VM.Name) checking Resource Group" "Error" "$($VM.ResourceGroupName)/$($VM.Name)" 
                    Throw "No Power management policy found"
                }
                LogOutput "Power Management Policy Tag Value for VM: $($VM.ResourceGroupName)/$($VM.Name): $($PowerMgmtPolicy)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                
                $PowerMgmtPolicy = InlineScript {
                    $Policy = $Using:PowerMgmtPolicy
                    if ($Policy.ToLower().StartsWith("h")) {
                        LogOutput "Downloading Power Management Policy for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) from $($Policy)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                            $Policy = (New-Object System.Net.WebClient).DownloadString($Policy) | ConvertFrom-JSON -ErrorAction Stop
                    } else {
                        LogOutput "Reading Power Management Policy from Tag for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) from $($Policy)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                        $Policy = $Policy | ConvertFrom-JSON -ErrorAction Stop
                    }
                    $Policy
                }

                LogOutput "Loaded Power Management Policy for VM: $($VM.ResourceGroupName)/$($VM.Name): $($PowerMgmtPolicy)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                
            } catch {
                #Failed to get the Power Management Policy...
                LogOutput "Failed to get power management policy for VM:$($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                $bAborted = $true
            }

            if (!$bAborted) {
                try {
                    LogOutput "Checking Schedule for Target Power Status of VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                    $TargetPowerState = ParseSchedules($PowerMgmtPolicy.Schedules) -ErrorAction Stop
                    LogOutput "Target Power Status of VM: $($VM.ResourceGroupName)/$($VM.Name) is $($TargetPowerState)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                } catch {
                    #Failed to get the schedule...
                    LogOutput "Failed to get schedule for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                    $bAborted = $true
                }
            }

            if (!$bAborted) {
                #What is the state of the VM - PowerState/deallocated or PowerState/running (there are others but these are our two target states)
                LogOutput "Checking Current Power Status of VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                $PowerStatus = (Get-AzureRmVM -ResourceGroupName $VM.ResourceGroupName -Name $VM.Name -status).Statuses[1].Code
                LogOutput "Current Power Status of VM: $($VM.ResourceGroupName)/$($VM.Name) is: $($PowerStatus)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                #Is the target power state the same as the current one? If not we better do something...
                if ([string]$TargetPowerState -ne [string]$PowerStatus) {
                    LogOutput "Current Power State: $($PowerStatus) for VM: $($VM.ResourceGroupName)/$($VM.Name) does not match Target Power State: $($TargetPowerState)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                    if ($TargetPowerState -eq "PowerState/deallocated" -and $PowerMgmtPolicy.Actions.Shutdown -eq "true") {
                        LogOutput "Checking for Shutdown scripts for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                        #Check to see if we need to run any shutdown scripts
                        if ($PowerMgmtPolicy.ShutdownScripts) {
                            try {
                                #Need to load the credentials from KeyVault
                                LogOutput "Shutdown scripts found for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                $Username = $PowerMgmtPolicy.Credentials.Username
                                $Password = Get-AzureKeyVaultSecret -VaultName $PowerMgmtPolicy.Credentials.KeyVaultName -Name $PowerMgmtPolicy.Credentials.PasswordSecret -ErrorAction Stop
                                $psCred = New-Object System.Management.Automation.PSCredential $Username, $Password.SecretValue
                            } catch {
                                $bAborted = $true
                                LogOutput "Aborting Shutdown process for  VM: $($VM.ResourceGroupName)/$($VM.Name) - unable to retrieve credentials from Key Vault: $($PowerMgmtPolicy.Credentials.KeyVaultName)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                            }

                            if (!$psCred) {
                                $bAborted = $true
                                LogOutput "PS Credential not configured aborting shutdown for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"                             
                            }

                            try {
                                $IPAddress = (Get-AzureRmNetworkInterface | Where-Object {$_.VirtualMachine.Id -eq $VM.ResourceId -and $_.Primary -eq "True"}).IpConfigurations[0].PrivateIPAddress 
    
                                if (!$IPAddress) {
                                    LogOutput "Unable to identify IP address for running remote scripts aborting on VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                    $bAborted = $true
                                    Throw "No IP Address for VM"
                                }   
                            
                                if (!$bAborted) {
                                    foreach($ShutdownScript in $PowerMgmtPolicy.ShutdownScripts) {
                                        if (!$bAborted) {
                                            LogOutput "Attempting Shutdown Script Command: $($ShutdownScript) on VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                            InlineScript{
                                                    $PowerMgmtPolicy = $Using:PowerMgmtPolicy
                                                    switch ($PowerMgmtPolicy.SystemType.ToLower()) {
                                                    "linux" {
                                                        LogOutput "System Type is Linux for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) @ IP: $($Using:IPAddress)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                        $sshSession = New-SSHSession -ComputerName $Using:IPAddress -Credential $Using:psCred -AcceptKey -ErrorAction Stop
                                                        $cmdOutput = $(Invoke-SSHCommand -SSHSession $sshSession -Command $Using:ShutdownScript.Command -ErrorAction Stop).Output 
                                                        LogOutput "SSH Command Output on VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) for command: $($Using:ShutdownScript.Command): $($cmdOutput)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                        Remove-SSHSession -SSHSession $sshSession -ErrorAction Stop
                                                        if ($Using:ShutdownScript.ExpectedOutput) {
                                                            if ([string]$cmdOutput -ne [string]$Using:ShutdownScript.ExpectedOutput) {
                                                                LogOutput "Aborting scripts for VM: $($VM.ResourceGroupName)/$($VM.Name), Command output: $($cmdOutput) did not match expected output: $($Using:ShutdownScript.ExpectedOutput)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                                $bAborted = $true
                                                            }
                                                        }
                                                    }
                                                    "windows" {
                                                        LogOutput "System Type is Windows for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) @ IP: $($Using:IPAddress)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"

                                                        LogOutput "Checking Remote IP is in Trusted Hosts for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) to enable remote PS Execution" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                        $TrustedHosts = [string](get-item wsman:\localhost\Client\TrustedHosts).value
                                                        
                                                        if ($TrustedHosts -ne "*") {
                                                                LogOutput "Trusted Hosts is not set to * on Hybrid Server, run command: set-item wsman:\localhost\client\TrustedHosts -value * -force" "Error" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                                $bAborted = $true
                                                        } 

                                                        if (!$bAborted) {

                                                            $ScriptBlock = [scriptblock]::Create($Using:ShutdownScript.Command)
                                                            $cmdOutput = [string](Invoke-Command -ComputerName $Using:IPAddress -Credential $Using:psCred -ScriptBlock $ScriptBlock)
                                                            LogOutput "PS Command Output on VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) for command: $($Using:ShutdownScript.Command): $($cmdOutput)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"

                                                            if ($Using:ShutdownScript.ExpectedOutput) {
                                                                if ([string]$cmdOutput -ne [string]$Using:ShutdownScript.ExpectedOutput) {
                                                                    LogOutput "Aborting scripts for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name), Command output: $($cmdOutput) did not match expected output: $($Using:ShutdownScript.ExpectedOutput)" "Error" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                                    $bAborted = $true
                                                                }
                                                            }
                                                        }
                                                    }

                                                    default {
                                                        LogOutput "Unrecognised SystemType for VM: $($VM.ResourceGroupName)/$($VM.Name) valid types are 'Linux' and 'Windows')" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                        $bAborted = $true
                                                        throw "Unrecongised SystemType"
                                                    }
                                                } 
                                            }
                                            #Sleep until the specified delay has expired
                                            if (!$bAborted) {
                                                LogOutput "Entering Delay of: $($ShutdownScript.Delay) for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                Start-Sleep $ShutdownScript.Delay
                                            }
                                        }
                                    }
                                }
                                } catch {
                                    LogOutput "Error encountered running shutdown scripts aborting for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                    $bAborted = $true
                                }
                            } else {
                                LogOutput "No Shutdown Scripts detected for VM:$($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                            }
                        #Shutdown the VM...
                        if (!$bAborted) {
                            LogOutput "Shutting Down VM: $($VM.ResourceGroupName)/$($VM.Name)" "Info" "$($VM.ResourceGroupName)/$($VM.Name)"
                            try {
                                if (!$SafeMode) {
                                    Stop-AzureRmVM -Id VM.ResourceId -Name $VM.Name -Force -ErrorAction Stop 
                                    LogOperation "Stop VM" "Stop" "$($VM.ResourceGroupName)/$($VM.Name)"
                                } else {
                                    LogOutput "Would have run the Shutdown command!" "Info" "$($VM.ResourceGroupName)/$($VM.Name)"
                                }
                            } catch {
                                LogOutput "Error trying to shutdown VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                            }
                        }
                    } else { #if ($TargetPowerState -eq "PowerState/deallocated")
                        if ($PowerMgmtPolicy.Actions.Startup -eq "true") {
                            if ($PowerMgmtPolicy.DependsOnVMs) {
                                LogOutput "Start up Dependencies found for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                foreach ($RequiredVM in $PowerMgmtPolicy.DependsOnVMs) {
                                    if (!$bAborted) {
                                        try {
                                            $RequiredVMPowerStatus = (Get-AzureRmVM -ResourceGroupName $RequiredVM.ResourceGroupName -Name $RequiredVM.Name -status).Statuses[1].Code
                                            $RequiredVMObj = Get-AzureRmVM -ResourceGroupName $RequiredVM.ResourceGroupName -Name $RequiredVM.Name
                                            $RetryCount = 0
                                            $SleepTime = 60
                                            if ($RequiredVMPowerStatus -ne "PowerState/running") {
                                                LogOutput "VM: $($VM.ResourceGroupName)/$($VM.Name) depends on VM: $($RequiredVM.ResourceGroupName)/$($RequiredVM.Name) which is not running - Current Power State is: $($RequireVMPowerStatus)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                Do {
                                                    if ($RequiredVM.Action -eq "Start" -and $RequiredVMPowerStatus -ne "PowerState/starting") {
                                                        Start-AzureRmVM -Id $RequiredVMObj.Id -Name $RequiredVMObj.Name -ErrorAction Stop
                                                        LogOutput "Dependency Action for VM: $($VM.ResourceGroupName)/$($VM.Name) is set to Start - attempting to start VM" "Info" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                        LogOperation "Start Dependency VM: $($RequiredVM.ResourceGroupName)/$($RequiredVM.Name)" "Start" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                    }
                                                    LogOutput "VM: $($VM.ResourceGroupName)/$($VM.Name) is waiting on dependency: $($VM.ResourceGroupName)/$($RequiredVM.Name) Retries attempted:$($RetryCount), Sleeping for: $($SleepTime)" "Info" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                    Start-Sleep $SleepTime
                                                    $RequiredVMPowerStatus = (Get-AzureRmVM -ResourceGroupName $RequiredVM.ResourceGroupName -Name $RequiredVM.Name -status).Statuses[1].Code
                                                    $RetryCount++
                                                    $SleepTime = ($SleepTime * 2)
                                                } While ($RequiredVMPowerStatus -ne "PowerState/running" -or $RetryCount -gt 5)
                                            } else {
                                                LogOutput "VM: $($VM.ResourceGroupName)/$($VM.Name) dependency on VM: $($RequiredVM.ResourceGroupName)/$($RequiredVM.Name) is satisfied - Current Power State is: $($RequiredVMPowerStatus)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                            }

                                            if ($RetryCount -gt 5) {
                                                LogOutput "VM: $($VM.ResourceGroupName)/$($VM.Name) Retries attempted: $($RetryCount)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                $bAborted = $true
                                            }
                                        } catch {
                                            $bAborted = $true
                                            LogOutput "Error handling VM Dependencies for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                        }   
                                    }
                                }
                                
                            }

                        #Startup the VM...
                        if (!$bAborted) {
                            LogOutput "Starting VM: $($VM.ResourceGroupName)/$($VM.Name)" "Info" "$($VM.ResourceGroupName)/$($VM.Name)"
                            try {
                                    Start-AzureRmVM -Id $VM.ResourceId -Name $VM.Name -ErrorAction Stop 
                                    LogOperation "Start VM" "Start" "$($VM.ResourceGroupName)/$($VM.Name)"
                            } catch {
                                LogOutput "Error trying to Startup VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                            }
                        }
                        if ($PowerMgmtPolicy.StartupScripts) {
                            #Need to give the machine a few minutes to start-up before we run any scripts on it...
                            $StartWaitTime = 300
                            LogOutput "Waiting $($StartWaitTime) for VM: $($VM.ResourceGroupName)/$($VM.Name) to start before running Startup scripts" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                            Start-Sleep $StartWaitTime
                            try {
                                #Need to load the credentials from KeyVault
                                LogOutput "Startup scripts found for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                $Username = $PowerMgmtPolicy.Credentials.Username
                                $Password = Get-AzureKeyVaultSecret -VaultName $PowerMgmtPolicy.Credentials.KeyVaultName -Name $PowerMgmtPolicy.Credentials.PasswordSecret -ErrorAction Stop
                                $psCred = New-Object System.Management.Automation.PSCredential $Username, $Password.SecretValue
                            } catch {
                                $bAborted = $true
                                LogOutput "Aborting Startup process for  VM: $($VM.ResourceGroupName)/$($VM.Name) - unable to retrieve credentials from Key Vault: $($PowerMgmtPolicy.Credentials.KeyVaultName)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                            }

                            if (!$psCred) {
                                $bAborted = $true
                                LogOutput "PS Credential not configured aborting Startup for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"                             
                            }

                            try {
                                $IPAddress = (Get-AzureRmNetworkInterface | Where-Object {$_.VirtualMachine.Id -eq $VM.ResourceId -and $_.Primary -eq "True"}).IpConfigurations[0].PrivateIPAddress 
    
                                if (!$IPAddress) {
                                    LogOutput "Unable to identify IP address for running remote scripts aborting on VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                    $bAborted = $true
                                    Throw "No IP Address for VM"
                                }   
                            
                                if (!$bAborted) {
                                    foreach($StartupScript in $PowerMgmtPolicy.StartupScripts) {
                                        if (!$bAborted) {
                                            LogOutput "Attempting Startup Script Command: $($StartupScript) on VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                            InlineScript{
                                                    $PowerMgmtPolicy = $Using:PowerMgmtPolicy
                                                    switch ($PowerMgmtPolicy.SystemType.ToLower()) {
                                                    "linux" {
                                                        LogOutput "System Type is Linux for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) @ IP: $($Using:IPAddress)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                        $sshSession = New-SSHSession -ComputerName $Using:IPAddress -Credential $Using:psCred -AcceptKey -ErrorAction Stop
                                                        $cmdOutput = $(Invoke-SSHCommand -SSHSession $sshSession -Command $Using:StartupScript.Command -ErrorAction Stop).Output 
                                                        LogOutput "SSH Command Output on VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) for command: $($Using:StartupScript.Command): $($cmdOutput)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                        Remove-SSHSession -SSHSession $sshSession -ErrorAction Stop
                                                        if ($Using:StartupScript.ExpectedOutput) {
                                                            if ([string]$cmdOutput -ne [string]$Using:StartupScript.ExpectedOutput) {
                                                                LogOutput "Aborting scripts for VM: $($VM.ResourceGroupName)/$($VM.Name), Command output: $($cmdOutput) did not match expected output: $($Using:StartupScript.ExpectedOutput)" "Error" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                                $bAborted = $true
                                                            }
                                                        }
                                                    }
                                                    "windows" {
                                                        LogOutput "System Type is Windows for VM: $($VM.ResourceGroupName)/$($VM.Name) @ IP: $($Using:IPAddress)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"

                                                        LogOutput "Checking Remote IP is in Trusted Hosts for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) to enable remote PS Execution" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                        $TrustedHosts = [string](get-item wsman:\localhost\Client\TrustedHosts).value
                                                        
                                                        if ($TrustedHosts -ne "*") {
                                                                LogOutput "Trusted Hosts is not set to * on Hybrid Server, run command: set-item wsman:\localhost\client\TrustedHosts -value * -force" "Error" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                                $bAborted = $true
                                                        } 

                                                        if (!$bAborted) {

                                                            $ScriptBlock = [scriptblock]::Create($Using:StartupScript.Command)
                                                            $cmdOutput = [string](Invoke-Command -ComputerName $Using:IPAddress -Credential $Using:psCred -ScriptBlock $ScriptBlock)
                                                            LogOutput "PS Command Output on VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name) for command: $($Using:StartupScript.Command): $($cmdOutput)" "Debug" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"

                                                            if ($Using:StartupScript.ExpectedOutput) {
                                                                if ([string]$cmdOutput -ne [string]$Using:StartupScript.ExpectedOutput) {
                                                                    LogOutput "Aborting scripts for VM: $($Using:VM.ResourceGroupName)/$($Using:VM.Name), Command output: $($cmdOutput) did not match expected output: $($Using:StartupScript.ExpectedOutput)" "Error" "$($Using:VM.ResourceGroupName)/$($Using:VM.Name)"
                                                                    $bAborted = $true
                                                                }
                                                            }
                                                        }
                                                    }

                                                    default {
                                                        LogOutput "Unrecognised SystemType for VM: $($VM.ResourceGroupName)/$($VM.Name) valid types are 'Linux' and 'Windows')" "Error" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                        $bAborted = $true
                                                        throw "Unrecongised SystemType"
                                                    }
                                                } 
                                            }
                                            #Sleep until the specified delay has expired
                                            if (!$bAborted) {
                                                LogOutput "Entering Delay of: $($StartupScript.Delay) for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                                                Start-Sleep $StartupScript.Delay 
                                            }
                                        }
                                    }
                                }
                                } catch {
                                    LogOutput "Error encountered running Startup scripts aborting for VM: $($VM.ResourceGroupName)/$($VM.Name)" "Error"
                                    $bAborted = $true
                                }
                            } else {
                                LogOutput "No Startup Scripts detected for VM:$($VM.ResourceGroupName)/$($VM.Name)" "Debug" "$($VM.ResourceGroupName)/$($VM.Name)"
                            }
                        }
                    }
                }
            } 
        }
    }
    LogOutput "Run Complete" "End" "*/*"
}

