#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Displays ESXi vmnic connections to physical switch ports.

.DESCRIPTION
Queries vSphere network hints for link-up physical NICs named vmnic<number> on
the selected ESXi hosts. USB network adapters such as vusb0 are excluded. The
report shows the ESXi cluster, local vSphere switch, physical switch name,
physical switch port, discovery protocol, and link speed.

Physical switch details come from CDP or LLDP advertisements received by the
ESXi host. If neither protocol supplies neighbor data, the script reports that
the connection was not advertised instead of attempting to infer it.

When VMHostName and ClusterName are both omitted, all ESXi hosts visible
through the selected vCenter connection are included.

.PARAMETER VIServer
Optional vCenter Server name. If omitted and exactly one active default
PowerCLI connection exists, that connection is reused.

.PARAMETER Credential
Optional credential used only when Connect-VIServer is required.

.PARAMETER VMHostName
Optional exact ESXi host name. Wildcards are not allowed. If omitted, the
report includes the hosts selected by ClusterName, or all hosts when no cluster
is specified.

.PARAMETER ClusterName
Optional exact cluster name. Wildcards are not allowed. When specified without
VMHostName, only ESXi hosts in this cluster are included.

.PARAMETER CsvPath
Optional path to which the report is exported as a CSV file.

.EXAMPLE
.\Get-ESXiVmnicSwitchPorts-v1.ps1

.EXAMPLE
.\Get-ESXiVmnicSwitchPorts-v1.ps1 -VMHostName esx01.example.com

.EXAMPLE
.\Get-ESXiVmnicSwitchPorts-v1.ps1 -ClusterName 'Production Cluster'

.EXAMPLE
.\Get-ESXiVmnicSwitchPorts-v1.ps1 -CsvPath C:\Reports\ESXi-vmnic-switch-ports.csv
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$VIServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'VMHostName cannot be blank.'
            }
            if ($_.IndexOfAny([char[]]'*?[]') -ge 0) {
                throw 'VMHostName cannot contain wildcard characters (*, ?, [, or ]).'
            }
            $true
    })]
    [string]$VMHostName,

    [Parameter()]
    [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'ClusterName cannot be blank.'
            }
            if ($_.IndexOfAny([char[]]'*?[]') -ge 0) {
                throw 'ClusterName cannot contain wildcard characters (*, ?, [, or ]).'
            }
            $true
        })]
    [string]$ClusterName,

    [Parameter()]
    [ValidateScript({
            if ([string]::IsNullOrWhiteSpace($_)) {
                throw 'CsvPath cannot be blank.'
            }
            $true
        })]
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'
$script:ExitRequested = $false

if (-not [string]::IsNullOrWhiteSpace($VMHostName) -and -not [string]::IsNullOrWhiteSpace($ClusterName)) {
    throw 'VMHostName and ClusterName cannot be used together. Specify one host, one cluster, or neither for all hosts.'
}

function Read-ExitAwareInput {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $value = Read-Host -Prompt "$Prompt (enter 'exit' to cancel)"
    if ($null -eq $value) {
        return $null
    }

    $value = $value.Trim()
    if ($value -ieq 'exit') {
        $script:ExitRequested = $true
        return $null
    }

    return $value
}

function Stop-IfExitRequested {
    if ($script:ExitRequested) {
        Write-Host 'Stopped. No changes were made.' -ForegroundColor Yellow
        exit 0
    }
}

function Get-VCenterConnection {
    $existingConnections = @()
    foreach ($connection in (@($global:DefaultVIServer) + @($global:DefaultVIServers))) {
        if ($null -eq $connection) {
            continue
        }
        if ($connection.PSObject.Properties.Name -contains 'IsConnected' -and -not $connection.IsConnected) {
            continue
        }
        if (@($existingConnections | Where-Object { $_.Name -ieq $connection.Name }).Count -eq 0) {
            $existingConnections += $connection
        }
    }

    if ([string]::IsNullOrWhiteSpace($VIServer) -and $existingConnections.Count -eq 1) {
        return $existingConnections[0]
    }

    $serverName = $VIServer
    while ([string]::IsNullOrWhiteSpace($serverName)) {
        if ($existingConnections.Count -gt 1) {
            Write-Host 'More than one active vCenter connection was found:' -ForegroundColor Yellow
            $existingConnections | ForEach-Object { Write-Host "  $($_.Name)" }
        }
        Write-Host ''
        $serverName = Read-ExitAwareInput -Prompt 'Enter the vCenter Server host name or IP address'
        Stop-IfExitRequested
        if ([string]::IsNullOrWhiteSpace($serverName)) {
            Write-Warning 'A vCenter Server host name or IP address is required.'
        }
    }

    $matchingConnection = @($existingConnections | Where-Object { $_.Name -ieq $serverName })
    if ($matchingConnection.Count -gt 0) {
        return $matchingConnection[0]
    }

    $connectionCredential = $Credential
    if ($null -eq $connectionCredential) {
        $connectionCredential = Get-Credential -Message "Enter credentials for vCenter Server '$serverName'."
        if ($null -eq $connectionCredential) {
            throw 'The vCenter credential prompt was cancelled.'
        }
    }

    return Connect-VIServer -Server $serverName -Credential $connectionCredential -ErrorAction Stop
}

function Get-SelectedVMHosts {
    param(
        [Parameter(Mandatory)]
        [object]$Server
    )

    if (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
        $matchingClusters = @(
            Get-Cluster -Server $Server -ErrorAction Stop |
                Where-Object { $_.Name -ieq $ClusterName }
        )
        if ($matchingClusters.Count -eq 0) {
            throw "No cluster named '$ClusterName' was found on '$($Server.Name)'."
        }
        if ($matchingClusters.Count -gt 1) {
            throw "More than one cluster is named '$ClusterName'. The name must identify exactly one cluster."
        }

        $hosts = @(Get-VMHost -Location $matchingClusters[0] -Server $Server -ErrorAction Stop)
    }
    else {
        $hosts = @(Get-VMHost -Server $Server -ErrorAction Stop)
    }

    if (-not [string]::IsNullOrWhiteSpace($VMHostName)) {
        $hosts = @($hosts | Where-Object { $_.Name -ieq $VMHostName })
        if ($hosts.Count -eq 0) {
            throw "No ESXi host named '$VMHostName' was found on '$($Server.Name)'."
        }
        if ($hosts.Count -gt 1) {
            throw "More than one ESXi host is named '$VMHostName'. The name must identify exactly one host."
        }
    }

    if ($hosts.Count -eq 0) {
        if (-not [string]::IsNullOrWhiteSpace($ClusterName)) {
            throw "No ESXi hosts were found in cluster '$ClusterName'."
        }
        throw "No ESXi hosts were found on '$($Server.Name)'."
    }

    return @($hosts | Sort-Object Name)
}

function Get-LldpParameterValue {
    param(
        [Parameter()]
        [object[]]$Parameters,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    $normalizedNames = @($Names | ForEach-Object { $_.ToLowerInvariant() -replace '[^a-z0-9]', '' })
    foreach ($parameter in @($Parameters)) {
        if ($null -eq $parameter -or [string]::IsNullOrWhiteSpace([string]$parameter.Key)) {
            continue
        }
        $normalizedKey = ([string]$parameter.Key).ToLowerInvariant() -replace '[^a-z0-9]', ''
        $isMatchingKey = @($normalizedNames | Where-Object {
                $normalizedKey -eq $_ -or $normalizedKey.StartsWith($_)
            }).Count -gt 0
        if ($isMatchingKey -and $null -ne $parameter.Value) {
            $value = $parameter.Value
            if ($value -is [string]) {
                return $value
            }
            if ($value.PSObject.Properties.Name -contains 'InnerText' -and -not [string]::IsNullOrWhiteSpace([string]$value.InnerText)) {
                return [string]$value.InnerText
            }
            if ($value.PSObject.Properties.Name -contains 'Value' -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) {
                return [string]$value.Value
            }
            return [string]$value
        }
    }

    return $null
}

function Get-VMHostClusterName {
    param(
        [Parameter(Mandatory)]
        [object]$VMHost,

        [Parameter(Mandatory)]
        [object]$Server
    )

    $clusters = @(Get-Cluster -VMHost $VMHost -Server $Server -ErrorAction Stop)
    if ($clusters.Count -eq 0) {
        return '(standalone)'
    }

    return [string]$clusters[0].Name
}

function Test-PnicReference {
    param(
        [Parameter()]
        [object]$Reference,

        [Parameter(Mandatory)]
        [string]$Vmnic
    )

    if ($null -eq $Reference) {
        return $false
    }

    $referenceText = if ($Reference.PSObject.Properties.Name -contains 'PnicDevice') {
        [string]$Reference.PnicDevice
    }
    else {
        [string]$Reference
    }

    return $referenceText -ieq $Vmnic -or $referenceText -match "(?i)(?:^|[-:])$([regex]::Escape($Vmnic))$"
}

function Get-VSphereSwitchNames {
    param(
        [Parameter(Mandatory)]
        [object]$NetworkInfo,

        [Parameter(Mandatory)]
        [string]$Vmnic
    )

    $switchNames = @()
    foreach ($virtualSwitch in @($NetworkInfo.Vswitch)) {
        if (@($virtualSwitch.Pnic | Where-Object { Test-PnicReference -Reference $_ -Vmnic $Vmnic }).Count -gt 0) {
            $switchNames += [string]$virtualSwitch.Name
        }
    }
    foreach ($proxySwitch in @($NetworkInfo.ProxySwitch)) {
        if (@($proxySwitch.Pnic | Where-Object { Test-PnicReference -Reference $_ -Vmnic $Vmnic }).Count -gt 0) {
            $name = if (-not [string]::IsNullOrWhiteSpace([string]$proxySwitch.DvsName)) {
                [string]$proxySwitch.DvsName
            }
            else {
                [string]$proxySwitch.Key
            }
            $switchNames += $name
        }
    }

    $switchNames = @($switchNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($switchNames.Count -eq 0) {
        return '(not assigned)'
    }
    return $switchNames -join ', '
}

function Get-VMHostVmnicReport {
    param(
        [Parameter(Mandatory)]
        [object]$VMHost,

        [Parameter(Mandatory)]
        [object]$Server
    )

    try {
        $clusterName = Get-VMHostClusterName -VMHost $VMHost -Server $Server
        $networkSystemId = $VMHost.ExtensionData.ConfigManager.NetworkSystem
        if ($null -eq $networkSystemId) {
            throw 'The host network-system reference is unavailable.'
        }

        $networkSystem = Get-View -Id $networkSystemId -Server $Server -Property NetworkInfo.Pnic,NetworkInfo.Vswitch,NetworkInfo.ProxySwitch -ErrorAction Stop
        $pnics = @(
            $networkSystem.NetworkInfo.Pnic |
                Where-Object {
                    $null -ne $_.LinkSpeed -and
                    [string]$_.Device -match '^(?i:vmnic\d+)$'
                } |
                Sort-Object Device
        )
        if ($pnics.Count -eq 0) {
            return @()
        }

        $hints = @($networkSystem.QueryNetworkHint(@($pnics.Device)))
        $hintsByDevice = @{}
        foreach ($hint in $hints) {
            $hintsByDevice[[string]$hint.Device] = $hint
        }

        foreach ($pnic in $pnics) {
            $hint = $hintsByDevice[[string]$pnic.Device]
            $protocol = 'None'
            $physicalSwitch = '(not advertised)'
            $switchPort = '(not advertised)'

            if ($null -ne $hint -and $null -ne $hint.LldpInfo) {
                $protocol = 'LLDP'
                $lldp = $hint.LldpInfo
                $systemName = Get-LldpParameterValue -Parameters @($lldp.Parameter) -Names @('System Name', 'SystemName', 'SysName')
                $physicalSwitch = if (-not [string]::IsNullOrWhiteSpace($systemName)) { $systemName } else { [string]$lldp.ChassisId }
                $switchPort = [string]$lldp.PortId
            }
            elseif ($null -ne $hint -and $null -ne $hint.ConnectedSwitchPort) {
                $protocol = 'CDP'
                $cdp = $hint.ConnectedSwitchPort
                $physicalSwitch = if (-not [string]::IsNullOrWhiteSpace([string]$cdp.SystemName)) {
                    [string]$cdp.SystemName
                }
                else {
                    [string]$cdp.DevId
                }
                $switchPort = [string]$cdp.PortId
            }

            if ([string]::IsNullOrWhiteSpace($physicalSwitch)) {
                $physicalSwitch = '(not advertised)'
            }
            if ([string]::IsNullOrWhiteSpace($switchPort)) {
                $switchPort = '(not advertised)'
            }

            [pscustomobject]@{
                Cluster           = $clusterName
                ESXiHost          = $VMHost.Name
                Vmnic             = [string]$pnic.Device
                Link              = 'Up'
                SpeedMbps         = [int]$pnic.LinkSpeed.SpeedMb
                vSphereSwitch     = Get-VSphereSwitchNames -NetworkInfo $networkSystem.NetworkInfo -Vmnic ([string]$pnic.Device)
                PhysicalSwitch    = $physicalSwitch
                SwitchPort        = $switchPort
                Protocol          = $protocol
            }
        }
    }
    catch {
        Write-Warning "Could not query vmnic switch-port information for '$($VMHost.Name)': $($_.Exception.Message)"
        return @()
    }
}

try {
    Write-Host "`nESXi vmnic Physical Switch Port Report" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan

    $server = Get-VCenterConnection
    Write-Host "Using vCenter connection '$($server.Name)'." -ForegroundColor Green

    $hosts = @(Get-SelectedVMHosts -Server $server)
    Write-Host "Querying $($hosts.Count) ESXi host(s)..." -ForegroundColor Cyan

    $report = @(
        foreach ($vmHost in $hosts) {
            Get-VMHostVmnicReport -VMHost $vmHost -Server $server
        }
    )

    Write-Host "`nLink-up vmnic connections:" -ForegroundColor Cyan
    if ($report.Count -eq 0) {
        Write-Warning 'No link-up vmnics were returned from the selected ESXi hosts.'
    }
    else {
        $report |
            Select-Object Cluster, ESXiHost, Vmnic, Link, SpeedMbps, vSphereSwitch, PhysicalSwitch, SwitchPort, Protocol |
            Format-Table -AutoSize -Wrap |
            Out-Host
    }
    Write-Host ''

    if (-not [string]::IsNullOrWhiteSpace($CsvPath)) {
        $resolvedCsvPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CsvPath)
        $csvDirectory = Split-Path -Parent $resolvedCsvPath
        if (-not [string]::IsNullOrWhiteSpace($csvDirectory) -and -not (Test-Path -LiteralPath $csvDirectory -PathType Container)) {
            throw "The CSV destination folder '$csvDirectory' does not exist."
        }
        $report | Export-Csv -LiteralPath $resolvedCsvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Report exported to '$resolvedCsvPath'." -ForegroundColor Green
        Write-Host ''
    }

    $missingNeighborCount = @($report | Where-Object { $_.Protocol -eq 'None' }).Count
    if ($missingNeighborCount -gt 0) {
        Write-Warning "$missingNeighborCount vmnic(s) had no CDP or LLDP neighbor data. Confirm that discovery advertisements are enabled on the physical switch ports."
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
