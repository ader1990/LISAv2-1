# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

function Main {
    # Create test result 
    $result = ""
    $currentTestResult = CreateTestResultObject
    $resultArr = @()

    try {
        $noClient = $true
        $noServer = $true
        foreach ($vmData in $allVMData) {
            if ($vmData.RoleName -imatch "client") {
                $clientVMData = $vmData
                $noClient = $false
            }
            elseif ($vmData.RoleName -imatch "server") {
                $noServer = $fase
                $serverVMData = $vmData
            }
        }
        if ($noClient) {
            Throw "No any master VM defined. Be sure that, Client VM role name matches with the pattern `"*master*`". Aborting Test."
        }
        if ($noServer) {
            Throw "No any slave VM defined. Be sure that, Server machine role names matches with pattern `"*slave*`" Aborting Test."
        }
        #region CONFIGURE VM FOR TERASORT TEST
        LogMsg "CLIENT VM details :"
        LogMsg "  RoleName  : $($clientVMData.RoleName)"
        LogMsg "  Public IP : $($clientVMData.PublicIP)"
        LogMsg "  SSH Port  : $($clientVMData.SSHPort)"
        LogMsg "  Location  : $($clientVMData.Location)"
        LogMsg "SERVER VM details :"
        LogMsg "  RoleName  : $($serverVMData.RoleName)"
        LogMsg "  Public IP : $($serverVMData.PublicIP)"
        LogMsg "  SSH Port  : $($serverVMData.SSHPort)"
        LogMsg "  Location  : $($serverVMData.Location)"

        # PROVISION VMS FOR LISA WILL ENABLE ROOT USER AND WILL MAKE ENABLE PASSWORDLESS AUTHENTICATION ACROSS ALL VMS IN SAME HOSTED SERVICE.  
        ProvisionVMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        #endregion

        if ($EnableAcceleratedNetworking -or $currentTestData.AdditionalHWConfig.Networking -imatch "SRIOV") {
            $DataPath = "SRIOV"
        } else {
            $DataPath = "Synthetic"
        }
        LogMsg "Getting $DataPath NIC Name."
        $getNicCmd = ". ./utils.sh &> /dev/null && get_active_nic_name"
        $clientNicName = (RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command $getNicCmd).Trim()
        $serverNicName = (RunLinuxCmd -ip $clientVMData.PublicIP -port $serverVMData.SSHPort -username "root" -password $password -command $getNicCmd).Trim()
        LogMsg "CLIENT $DataPath NIC: $clientNicName"
        LogMsg "SERVER $DataPath NIC: $serverNicName"
        if ( $serverNicName -eq $clientNicName) {
            $nicName = $clientNicName
        } else {
            Throw "Server and client SRIOV NICs are not same."
        }

        LogMsg "Generating constansts.sh ..."
        $constantsFile = "$LogDir\constants.sh"

        #region Check if VMs share same Public IP
        Set-Content -Value "#Generated by Azure Automation." -Path $constantsFile
        if ($clientVMData.PublicIP -eq $serverVMData.PublicIP) {
            Add-Content -Value "server=$($serverVMData.InternalIP)" -Path $constantsFile    
            Add-Content -Value "client=$($clientVMData.InternalIP)" -Path $constantsFile
        } else {
            Add-Content -Value "server=$($serverVMData.PublicIP)" -Path $constantsFile  
            Add-Content -Value "client=$($clientVMData.PublicIP)" -Path $constantsFile
        }
        #endregion

        foreach ($param in $currentTestData.TestParameters.param) {
            Add-Content -Value "$param" -Path $constantsFile
            if ($param -imatch "bufferLengths=") {
                $testBuffers= $param.Replace("bufferLengths=(","").Replace(")","").Split(" ")
            }
            if ($param -imatch "connections=" ) {
                $testConnections = $param.Replace("connections=(","").Replace(")","").Split(" ")
            }
            if ( $param -imatch "IPversion" ) {
                if ( $param -imatch "IPversion=6" ) {
                    $IPVersion = "IPv6"
                    Add-Content -Value "serverIpv6=$($serverVMData.PublicIPv6)" -Path $constantsFile    
                    Add-Content -Value "clientIpv6=$($clientVMData.PublicIPv6)" -Path $constantsFile
                } else {
                    $IPVersion = "IPv4"
                }
            }
        }
        LogMsg "constanst.sh created successfully..."
        LogMsg (Get-Content -Path $constantsFile)
        #endregion
 
        #region EXECUTE TEST
        $myString = @"
cd /root/
./perf_iperf3.sh &> iperf3tcpConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        Set-Content "$LogDir\Startiperf3tcpTest.sh" $myString
        RemoteCopy -uploadTo $clientVMData.PublicIP -port $clientVMData.SSHPort -files ".\$constantsFile,.\$LogDir\Startiperf3tcpTest.sh" -username "root" -password $password -upload
        $out = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "chmod +x *.sh"
        $testJob = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "/root/Startiperf3tcpTest.sh" -RunInBackground
        #endregion
        
        #region MONITOR TEST
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "tail -1 iperf3tcpConsoleLogs.txt"
            LogMsg "Current Test Staus : $currentStatus"
            WaitFor -seconds 20
        }
        
        $finalStatus = RunLinuxCmd -ip $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -command "cat /root/state.txt"
        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "/root/iperf3tcpConsoleLogs.txt"
        $iperf3LogDir = "$LogDir\iperf3Data"
        New-Item -itemtype directory -path $iperf3LogDir -Force -ErrorAction SilentlyContinue | Out-Null 
        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $iperf3LogDir -files "iperf-client-tcp*"
        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $iperf3LogDir -files "iperf-server-tcp*"
        RemoteCopy -downloadFrom $clientVMData.PublicIP -port $clientVMData.SSHPort -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
        $testSummary = $null
        foreach ($BufferSize_Bytes in $testBuffers) {
            $serverJson = ConvertFrom-Json -InputObject ([string](Get-Content .\$iperf3LogDir\iperf-server-tcp-IPv4-buffer-$BufferSize_Bytes-conn-1-instance-1.txt))
            $clientJson = ConvertFrom-Json -InputObject ([string](Get-Content .\$iperf3LogDir\iperf-client-tcp-IPv4-buffer-$BufferSize_Bytes-conn-1-instance-1.txt))
            $RxThroughput_Gbps = [math]::Round($serverJson.end.sum_received.bits_per_second/1000000000,2)
            $TxThroughput_Gbps = [math]::Round($clientJson.end.sum_received.bits_per_second/1000000000,2)
            $RetransmittedSegments = $clientJson.end.streams.sender.retransmits
            $CongestionWindowSize_KB_Total = 0
            foreach ($interval in $clientJson.intervals) {
                $CongestionWindowSize_KB_Total += $interval.streams.snd_cwnd
            }
            $CongestionWindowSize_KB = [math]::Round($CongestionWindowSize_KB_Total / $clientJson.intervals.Count / 1024 )
            $connResult="ClientTxGbps=$TxThroughput_Gbps"
            $metaData = "Buffer=$BufferSize_Bytes Bytes Connections=1"
            $resultSummary +=  CreateResultSummary -testResult $connResult -metaData $metaData -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        }

        if ($finalStatus -imatch "TestFailed") {
            LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        }
        elseif ($finalStatus -imatch "TestAborted") {
            LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        }
        elseif ($finalStatus -imatch "TestCompleted") {
            LogMsg "Test Completed."
            $testResult = "PASS"
        }
        elseif ($finalStatus -imatch "TestRunning") {
            LogMsg "Powershell backgroud job for test is completed but VM is reporting that test is still running. Please check $LogDir\zkConsoleLogs.txt"
            LogMsg "Contests of summary.log : $testSummary"
            $testResult = "PASS"
        }
        LogMsg "Test result : $testResult"
        LogMsg "Test Completed"
        
        LogMsg "Analysing the test results.."   
        $dataSource = $xmlConfig.config.$TestPlatform.database.server
        $user = $xmlConfig.config.$TestPlatform.database.user
        $password = $xmlConfig.config.$TestPlatform.database.password
        $database = $xmlConfig.config.$TestPlatform.database.dbname
        $dataTableName = $xmlConfig.config.$TestPlatform.database.dbtable
        $TestCaseName = $xmlConfig.config.$TestPlatform.database.testTag
        $TestDate = "$(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')"
        $GuestDistro    = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
        $HostType   = $Platform
        $HostBy = $TestLocation
        $HostOS = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
        $GuestOSType    = "Linux"
        $GuestDistro    = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
        $GuestSize = $clientVMData.InstanceSize
        $KernelVersion  = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}
        if ($KernelVersion.Length -ge 28) {
            $KernelVersion = $KernelVersion.Trim().Substring(0,28)
        }
        $ProtocolType = "TCP"

        $connectionString = "Server=$dataSource;uid=$user; pwd=$password;Database=$database;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"
        $SQLQuery = "INSERT INTO $dataTableName (TestCaseName,DataPath,TestDate,HostBy,HostOS,HostType,GuestSize,GuestOSType,GuestDistro,KernelVersion,IPVersion,ProtocolType,BufferSize_Bytes,RxThroughput_Gbps,TxThroughput_Gbps,RetransmittedSegments,CongestionWindowSize_KB) VALUES"
        foreach ($BufferSize_Bytes in $testBuffers) {
            $serverJson = ConvertFrom-Json -InputObject ([string](Get-Content .\$iperf3LogDir\iperf-server-tcp-IPv4-buffer-$BufferSize_Bytes-conn-1-instance-1.txt))
            $clientJson = ConvertFrom-Json -InputObject ([string](Get-Content .\$iperf3LogDir\iperf-client-tcp-IPv4-buffer-$BufferSize_Bytes-conn-1-instance-1.txt))
            $RxThroughput_Gbps = [math]::Round($serverJson.end.sum_received.bits_per_second/1000000000,2)
            $TxThroughput_Gbps = [math]::Round($clientJson.end.sum_received.bits_per_second/1000000000,2)
            $RetransmittedSegments = $clientJson.end.streams.sender.retransmits
            $CongestionWindowSize_KB_Total = 0
            foreach ($interval in $clientJson.intervals) {
                $CongestionWindowSize_KB_Total += $interval.streams.snd_cwnd
            }
            $CongestionWindowSize_KB = [math]::Round($CongestionWindowSize_KB_Total / $clientJson.intervals.Count / 1024 )
            $SQLQuery += "('$TestCaseName','$DataPath','$TestDate','$HostBy','$HostOS','$HostType','$GuestSize','$GuestOSType','$GuestDistro','$KernelVersion','IPv4','TCP','$BufferSize_Bytes','$RxThroughput_Gbps','$TxThroughput_Gbps','$RetransmittedSegments','$CongestionWindowSize_KB'),"
            $currentTestResult.TestSummary += CreateResultSummary -testResult $RxThroughput_Gbps -metaData "Buffer : $BufferSize_Bytes Bytes, Rx ThroughputGbps" -checkValues "PASS,FAIL,ABORTED" -testName $currentTestData.testName
        }
        if ($dataSource -And $user -And $password -And $database -And $dataTableName) {
            LogMsg "Uploading the test results.."       
            $SQLQuery = $SQLQuery.TrimEnd(',')
            LogMsg $SQLQuery
            $connection = New-Object System.Data.SqlClient.SqlConnection
            $connection.ConnectionString = $connectionString
            $connection.Open()

            $command = $connection.CreateCommand()
            $command.CommandText = $SQLQuery
            $result = $command.executenonquery()
            $connection.Close()
            LogMsg "Uploading the test results done!!"
        } else {
            LogMsg "Invalid database details. Failed to upload result to database!"
        }
    } catch {
        $line = $_.InvocationInfo.ScriptLineNumber
        $script_name = ($_.InvocationInfo.ScriptName).Replace($PWD,".")
        $ErrorMessage =  $_.Exception.Message
        LogMsg "EXCEPTION : $ErrorMessage"
        LogMsg "Source : Line $line in script $script_name." 
    } finally {
        $metaData = "iperf3tcp RESULT"
        if (!$testResult) {
            $testResult = "Aborted"
        }
        $resultArr += $testResult
    }

    $currentTestResult.TestResult = GetFinalResultHeader -resultarr $resultArr
    return $currentTestResult.TestResult  
}

Main
