##############################################################################################
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
#
# Install-CustomScript.ps1
<#
.SYNOPSIS

.PARAMETER
	-AzureSecretsFile, the path of Azure secrets file
	-VmName, the name of the VM to install the CustomScript extension, if no VmName is provided, it will be installed on all VMs
	-ResourceGroupName, the resource group name of the VMs to install the CustomScript extension, if no ResourceGroupName is provided, it will be installed on all VMs in the subscription
	-FileUris, comma separated Uris of the custom scripts
	-CommandToRun, the command to run on the VM
	-StorageAccountName, the name of the storage account that contains the custom scripts
	-StorageAccountKey, the key of the storage account that contains the custom scripts
	-OSType, the type of the OS, Linux or Windows, valid only if neither VmName nor ResourceGroupName is provided

.NOTES
	Creation Date:
	Purpose/Change:

.EXAMPLE
	.\Utilities\Install-CustomScript.ps1 -AzureSecretsFile <PathToSecretFile> -VmName <VmName> -ResourceGroupName <RgName> `
		-FileUris "https://teststorageaccout.blob.core.windows.net/script/install.sh" -CommandToRun "bash install.sh" `
		-StorageAccountName <StorageAccoutName> -StorageAccountKey <StorageAccountKey> -OSType Linux
#>
###############################################################################################

param
(
	[Parameter(Mandatory=$true)]
	[String] $AzureSecretsFile,
	[String] $VmName = "",
	[String] $ResourceGroupName = "",
	[Parameter(Mandatory=$true)]
	[String] $FileUris,
	[Parameter(Mandatory=$true)]
	[String] $CommandToRun,
	[String] $StorageAccountName = "",
	[String] $StorageAccountKey = "",
	[ValidateSet('Linux','Windows', IgnoreCase = $false)]
	[String] $OSType = "Linux"
)

Function Initialize-Environment($AzureSecretsFile, $LogFileName) {
	Get-ChildItem .\Libraries -Recurse | Where-Object { $_.FullName.EndsWith(".psm1") } | ForEach-Object { Import-Module $_.FullName -Force -Global -DisableNameChecking }
	if (!$global:LogFileName){
		Set-Variable -Name LogFileName -Value $LogFileName -Scope Global -Force
	}

	#Read secrets file and terminate if not present.
	if ($AzureSecretsFile)
	{
		$secretsFile = $AzureSecretsFile
	}
	elseif ($env:Azure_Secrets_File)
	{
		$secretsFile = $env:Azure_Secrets_File
	}
	else
	{
		Write-LogInfo "-AzureSecretsFile and env:Azure_Secrets_File are empty. Exiting."
		exit 1
	}
	if ( -not (Test-Path $secretsFile))
	{
		Write-LogInfo "Secrets file not found. Exiting."
		exit 1
	}
	Write-LogInfo "Secrets file found."
	.\Utilities\AddAzureRmAccountFromSecretsFile.ps1 -customSecretsFilePath $secretsFile
}

Function Install-CustomScript($AzureSecretsFile, $FileUris, $CommandToRun, $StorageAccountName, $StorageAccountKey, $VmName, $ResourceGroupName, $OSType){
	Initialize-Environment -AzureSecretsFile $AzureSecretsFile -logFileName "Install-CustomScriptOnAllVMs.log"

	$uriArray = $FileUris -split ","
	$settings =  @{"fileUris" = $uriArray; "commandToExecute" = $CommandToRun}
	$protectedSettings = @{}
	if ($StorageAccountKey -and $StorageAccountName) {
		$protectedSettings = @{"storageAccountName" = $StorageAccountName; "storageAccountKey" = $StorageAccountKey}
	}

	$vms = @()
	if ($ResourceGroupName -and $VmName) {
		$vms += Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VmName
	} elseif ($ResourceGroupName) {
		$vms = Get-AzureRmVM -ResourceGroupName $ResourceGroupName | Where-Object {$_.StorageProfile.OsDisk.OsType -eq $OSType}
	} else {
		$vms = Get-AzureRmVM | Where-Object {$_.StorageProfile.OsDisk.OsType -eq $OSType}
	}
	foreach ($vm in $VMs) {
		$vmStatus = Get-AzureRmVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Status
		# Only install the extenstion on VMs running and has waagent installed
		if ($vmStatus.Statuses[1].Code -imatch "running" -and $vmStatus.VMAgent.VmAgentVersion -notmatch "Unknown") {
			$extension = Get-AzureRmVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -Name CustomScript -ErrorAction SilentlyContinue
			if ($extension -and $extension.PublicSettings -imatch $FileUris -and $extension.PublicSettings -imatch $CommandToRun) {
				# CustomScript extension is already installed
				Write-LogInfo "Custom script is already installed on VM $($vm.Name) in $($vm.ResourceGroupName)."
				continue
			}
			try {
				Write-LogInfo "Start to install CustomScript extension on VM $($vm.Name) in resource group $($vm.ResourceGroupName)"
				Set-AzureRmVMExtension -ResourceGroupName $vm.ResourceGroupName -VMName $vm.Name -Location $vm.Location -Name CustomScript -Publisher "Microsoft.Azure.Extensions" `
					-Type "CustomScript" -TypeHandlerVersion 2.0 -Settings $settings -ProtectedSettings $protectedSettings
			} catch {
				Write-LogErr "Exception occurred in when installing CustomScript extension on VM $($vm.Name)."
				Write-LogErr $_.Exception
			}
		}
	}
}

Install-CustomScript -AzureSecretsFile $AzureSecretsFile -FileUris $FileUris -CommandToRun $CommandToRun -StorageAccountName $StorageAccountName `
	-StorageAccountKey $StorageAccountKey -VmName $VmName -ResourceGroupName $ResourceGroupName -OSType $OSType