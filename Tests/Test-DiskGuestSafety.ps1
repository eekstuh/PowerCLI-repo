#requires -Version 5.1
# Offline tests: extract function definitions only; never run a workflow or load PowerCLI.
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Utility
Import-Module Microsoft.PowerShell.Security
$PSModuleAutoLoadingPreference = 'None'
$root = Split-Path -Parent $PSScriptRoot
$credential = [pscredential]::new('test', (ConvertTo-SecureString 'test-only' -AsPlainText -Force))
$server = [pscustomobject]@{Name='test-vcenter'}
$vm = [pscustomobject]@{Id='vm-1';Name='test-vm'}
$script:checks = 0
function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
function Assert-Fails {
    param([scriptblock]$Action,[string]$Pattern)
    try { & $Action } catch {
        Assert-True ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)"
        return
    }
    throw "Expected failure: $Pattern"
}
foreach ($file in @('Expand-VSphereVmDisk-v3.ps1','Expand-MultipleVSphereVmDisks-v1.ps1','Assign-VDI-v1.ps1','ShowSQLDisk.ps1')) {
    & {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$null,[ref]$null)
        foreach ($name in @('Assert-WindowsGuestReadiness','Invoke-GuestScriptWithCredentialRetry','Invoke-WindowsGuestPowerShell','Get-VerifiedExpandedHardDisk')) {
            $definition = $ast.EndBlock.Statements | Where-Object {
                $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
            }
            if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        $script:RejectedGuestCredentials = $null
        $mode = 'Ready'
        $calls = [collections.generic.list[string]]::new()
        function Get-VM {
            param($Id,$Server,$ErrorAction)
            [pscustomobject]@{
                PowerState = if ($mode -eq 'Off') { 'PoweredOff' } else { 'PoweredOn' }
                ExtensionData = [pscustomobject]@{Guest=[pscustomobject]@{
                    ToolsRunningStatus = if ($mode -eq 'NoTools') { 'guestToolsNotRunning' } else { 'guestToolsRunning' }
                }}
            }
        }
        function Invoke-VMScript {
            param($VM,$Server,$GuestCredential,$ScriptType,$ScriptText,$ErrorAction)
            if ($null -eq $Server) { throw 'Missing server scope.' }
            if ($ScriptText -match "^Write-Output '(POWERCLI_READY_[a-f0-9]+)'$") {
                $calls.Add('Probe')
                if ($mode -eq 'Auth') { throw 'InvalidGuestLogin' }
                return [pscustomobject]@{
                    ExitCode = if ($mode -eq 'Nonzero') { 1 } else { 0 }
                    ScriptOutput = if ($mode -eq 'MissingMarker') { 'noise' } else { $Matches[1] }
                }
            }
            $calls.Add('Operation')
            if ($mode -eq 'OperationFailure') { throw 'Unknown transport failure' }
            [pscustomobject]@{ExitCode=0;ScriptOutput="__VMWARE_GUEST_PAYLOAD_BEGIN__`n{}`n__VMWARE_GUEST_PAYLOAD_END__"}
        }
        foreach ($failureMode in @('Off','NoTools','Nonzero','MissingMarker','Auth')) {
            $mode = $failureMode
            $calls.Clear()
            Assert-Fails { Invoke-WindowsGuestPowerShell -VM $vm -Credential $credential -ScriptText 'operation' } 'powered on|not running|readiness check failed|InvalidGuestLogin'
            Assert-True (-not $calls.Contains('Operation')) "$file ran an operation after a failed probe."
        }
        $mode = 'Ready'
        $calls.Clear()
        $null = Invoke-WindowsGuestPowerShell -VM $vm -Credential $credential -ScriptText 'operation'
        Assert-True (($calls -join ',') -eq 'Probe,Operation') "$file did not probe before executing."
        $mode = 'OperationFailure'
        $calls.Clear()
        Assert-Fails { Invoke-WindowsGuestPowerShell -VM $vm -Credential $credential -ScriptText 'operation' } 'Unknown transport failure'
        Assert-True (($calls -join ',') -eq 'Probe,Operation') "$file replayed an unknown failure."
        if ($file -like 'Expand-*') {
            $disk = [pscustomobject]@{Id='disk-1';Filename='[DS] vm/disk.vmdk';CapacityGB=100}
            $actual = [pscustomobject]@{Id='disk-1';Filename=$disk.Filename;CapacityGB=120}
            function Get-HardDisk { param($VM,$Server,$ErrorAction) return $actual }
            $result = Get-VerifiedExpandedHardDisk -VM $vm -Server $server -HardDisk $disk -ExpectedCapacityGB 120
            Assert-True ($result.CapacityGB -eq 120) 'Expected capacity not verified.'
            foreach ($capacity in @(100,119,121)) {
                $actual.CapacityGB = $capacity
                Assert-Fails { Get-VerifiedExpandedHardDisk -VM $vm -Server $server -HardDisk $disk -ExpectedCapacityGB 120 } 'Guest changes were stopped'
            }
            $actual.CapacityGB=120
            $actual.Filename='[DS] different.vmdk'
            Assert-Fails { Get-VerifiedExpandedHardDisk -VM $vm -Server $server -HardDisk $disk -ExpectedCapacityGB 120 } 'uniquely verified'
            $actual=@()
            Assert-Fails { Get-VerifiedExpandedHardDisk -VM $vm -Server $server -HardDisk $disk -ExpectedCapacityGB 120 } 'uniquely verified'
            # Verify the main workflow places the check immediately after resizing.
            $source = Get-Content -LiteralPath (Join-Path $root $file) -Raw
            Assert-True ($source -match 'Set-HardDisk[^\r\n]+\r?\n\s*(?:\$vmdkChanged = \$true\r?\n\s*)?\$(?:disk|verifiedDisk) = Get-VerifiedExpandedHardDisk') "$file lacks the post-resize gate."
        }
        Write-Host "[PASS] $file"
    }
}
Write-Host "$script:checks offline checks passed."
