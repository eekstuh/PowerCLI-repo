#requires -Version 5.1
#requires -Modules VMware.VimAutomation.Core

<#
.SYNOPSIS
Looks up the IP addresses of VMs in vCenter and exports them to a CSV file.

.DESCRIPTION
Finds VMs by name and writes one CSV row per VM with its IPv4 addresses as
reported by VMware Tools (IPv6 addresses are ignored), plus power state, Tools status, guest OS,
and ESXi host. Wildcards (* and ?) are allowed in VMName to look up many VMs at
once. Multiple names or patterns can be supplied separated by commas.

IP addresses come from VMware Tools. A powered-off VM or one without running
Tools has no reported address; its row is still written with a Note explaining
why, so the CSV always accounts for every VM that matched.

Connects to vCenter the same way as the other scripts in this repository: the
single active default PowerCLI connection is reused when no VIServer is given;
otherwise the script prompts for the vCenter name and credentials.

.PARAMETER VIServer
Optional vCenter Server name. If omitted and exactly one active default
PowerCLI connection exists, that connection is reused; otherwise the script
prompts for a vCenter Server.

.PARAMETER Credential
Optional credential used only when Connect-VIServer is required.

.PARAMETER VMName
One or more VM names or wildcard patterns (for example 'APP*' or 'SQL0?').
If omitted, the script prompts for a name or pattern.

.PARAMETER CsvPath
Optional output CSV path. If omitted, writes VM-IPs-<yyyyMMdd-HHmmss>.csv to the
current directory.

.EXAMPLE
.\GetVMip.ps1 -VMName APP01

.EXAMPLE
.\GetVMip.ps1 -VIServer vcsa01.contoso.com -VMName 'APP*'

.EXAMPLE
.\GetVMip.ps1 -VMName 'SQL0?','WEB*' -CsvPath C:\Reports\VM-IPs.csv
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$VIServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string[]]$VMName,

    [Parameter()]
    [string]$CsvPath
)

$ErrorActionPreference = 'Stop'

function Get-VCenterConnection {
    # Do not call Get-VIServer here. In some PowerCLI versions it resolves to a
    # legacy alias for Connect-VIServer and prompts for its mandatory Server
    # parameter. PowerCLI stores active default connections in these variables.
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

    if ([string]::IsNullOrWhiteSpace($VIServer)) {
        if ($existingConnections.Count -eq 1) {
            return $existingConnections[0]
        }
    }

    $serverName = $VIServer
    while ([string]::IsNullOrWhiteSpace($serverName)) {
        $serverName = (Read-Host -Prompt "Enter the vCenter Server host name or IP address (enter 'exit' to cancel)").Trim()
        if ($serverName -ieq 'exit') {
            Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
            exit 0
        }

        if ([string]::IsNullOrWhiteSpace($serverName)) {
            Write-Warning 'A vCenter Server host name or IP address is required.'
            Write-Host ''
        }
    }

    $matchingConnection = @($existingConnections | Where-Object { $_.Name -ieq $serverName })
    if ($matchingConnection.Count -gt 0) {
        return $matchingConnection[0]
    }

    try {
        $connectionCredential = $Credential
        if ($null -eq $connectionCredential) {
            $connectionCredential = Get-Credential -Message "Enter credentials for vCenter Server '$serverName'."
            if ($null -eq $connectionCredential) {
                throw 'The vCenter credential prompt was cancelled.'
            }
        }

        return Connect-VIServer -Server $serverName -Credential $connectionCredential -ErrorAction Stop
    }
    catch {
        throw "Could not connect to vCenter Server '$serverName'. $($_.Exception.Message)"
    }
}

function Test-IPv4Address {
    param([string]$Address)
    $parsed = $null
    return ([System.Net.IPAddress]::TryParse($Address, [ref]$parsed) -and
        $parsed.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork)
}

try {
    # Prompt for a name or pattern when none was supplied.
    $patterns = @($VMName | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    while ($patterns.Count -eq 0) {
        $inputValue = (Read-Host -Prompt "Enter VM name or wildcard pattern, separate several with commas (enter 'exit' to cancel)").Trim()
        if ($inputValue -ieq 'exit') {
            Write-Host 'Cancelled. No changes were made.' -ForegroundColor Yellow
            exit 0
        }
        $patterns = @($inputValue -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($patterns.Count -eq 0) {
            Write-Warning 'At least one VM name or pattern is required.'
        }
    }

    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        $CsvPath = Join-Path -Path (Get-Location).Path -ChildPath ("VM-IPs-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    $server = Get-VCenterConnection
    Write-Host ''
    Write-Host "Connected to vCenter Server: $($server.Name)" -ForegroundColor Green
    Write-Host ''

    # Look up each pattern; a VM matched by several patterns is reported once.
    $vmsById = [ordered]@{}
    foreach ($pattern in $patterns) {
        $found = @(Get-VM -Name $pattern -Server $server -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Write-Warning "No VMs matched '$pattern'."
            continue
        }
        foreach ($vm in $found) {
            $vmsById[[string]$vm.Id] = $vm
        }
    }

    if ($vmsById.Count -eq 0) {
        Write-Host 'No matching VMs were found. No CSV file was written.' -ForegroundColor Yellow
        return
    }

    $results = foreach ($vm in ($vmsById.Values | Sort-Object Name)) {
        $ipv4 = @($vm.Guest.IPAddress | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-IPv4Address $_) })

        $note = ''
        if ($ipv4.Count -eq 0) {
            if ($vm.PowerState -ne 'PoweredOn') {
                $note = "VM is $($vm.PowerState); no IPv4 address is reported."
            }
            elseif ([string]$vm.ExtensionData.Guest.ToolsRunningStatus -ne 'guestToolsRunning') {
                $note = 'VMware Tools is not running; no IPv4 address is reported.'
            }
            else {
                $note = 'VMware Tools reported no IPv4 address.'
            }
        }

        [pscustomobject]@{
            VMName      = $vm.Name
            PowerState  = [string]$vm.PowerState
            IPv4Address = ($ipv4 -join '; ')
            GuestOS     = $(if ($vm.Guest.OSFullName) { $vm.Guest.OSFullName } else { [string]$vm.ExtensionData.Config.GuestFullName })
            ToolsStatus = [string]$vm.ExtensionData.Guest.ToolsRunningStatus
            VMHost      = $(if ($vm.VMHost) { $vm.VMHost.Name } else { '' })
            VCenter     = $server.Name
            Note        = $note
        }
    }

    $results = @($results)

    $csvDirectory = Split-Path -Path $CsvPath -Parent
    if (-not [string]::IsNullOrWhiteSpace($csvDirectory) -and -not (Test-Path -LiteralPath $csvDirectory)) {
        New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
    }
    $results | Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8

    $results | Format-Table VMName, PowerState, IPv4Address, Note -AutoSize | Out-Host
    $withIp = @($results | Where-Object { $_.IPv4Address }).Count
    Write-Host "Found $($results.Count) VM(s); $withIp with a reported IPv4 address." -ForegroundColor Cyan
    Write-Host "CSV saved to: $((Resolve-Path -LiteralPath $CsvPath).Path)" -ForegroundColor Green
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
