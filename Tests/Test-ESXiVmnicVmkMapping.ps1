#requires -Version 5.1
# Offline test of VMkernel-to-uplink mapping. Does not connect to vCenter.
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Utility
$root = Split-Path -Parent $PSScriptRoot
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Get-ESXiVmnicSwitchPorts-v1.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-PropertyText', 'Get-DistributedPortgroupLabels', 'Test-PnicReference', 'Get-VMKernelAdaptersForVmnic')) {
    $definition = $ast.EndBlock.Statements | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq $name
    }
    if ($null -eq $definition) { throw "Function '$name' was not found." }
    . ([scriptblock]::Create($definition.Extent.Text))
}
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$script:DistributedPortgroupLabels = @{}
$server = [pscustomobject]@{ Name = 'test-vcenter' }
function Get-VDPortgroup {
    param(
        [object]$Server,
        [object]$ErrorAction
    )

    return @(
        [pscustomobject]@{
            Name          = 'DVS-vMotion'
            ExtensionData = [pscustomobject]@{ Key = 'dvportgroup-100' }
        }
    )
}

$networkInfo = [pscustomobject]@{
    Vswitch = @(
        [pscustomobject]@{ Name='vSwitch0'; Pnic=@([pscustomobject]@{PnicDevice='vmnic0'}, [pscustomobject]@{PnicDevice='vmnic1'}) }
    )
    ProxySwitch = @(
        [pscustomobject]@{ DvsName='DSwitch01'; DvsUuid='dvs-uuid-1'; Pnic=@([pscustomobject]@{PnicDevice='vmnic2'}, [pscustomobject]@{PnicDevice='vmnic3'}) }
    )
    Portgroup = @(
        [pscustomobject]@{ Spec=[pscustomobject]@{Name='Management Network';VswitchName='vSwitch0'} }
    )
    Vnic = @(
        [pscustomobject]@{ Device='vmk0'; Spec=[pscustomobject]@{Portgroup='Management Network';Mac='00:50:56:00:00:10'} }
        [pscustomobject]@{ Device='vmk1'; Spec=[pscustomobject]@{DistributedVirtualPort=[pscustomobject]@{SwitchUuid='dvs-uuid-1';PortgroupKey='dvportgroup-100'};Mac='00:50:56:00:00:11'} }
        [pscustomobject]@{ Device='vmk2'; Spec=[pscustomobject]@{Portgroup='Unattached Network';Mac='00:50:56:00:00:12'} }
    )
}

$standard = @(Get-VMKernelAdaptersForVmnic -NetworkInfo $networkInfo -Vmnic 'vmnic0' -Server $server)
Assert-True ($standard.Count -eq 1 -and $standard[0].Name -eq 'vmk0' -and $standard[0].Mac -eq '00:50:56:00:00:10' -and $standard[0].NetworkLabel -eq 'Management Network') 'Standard-vSwitch VMkernel mapping failed.'
$teamedStandard = @(Get-VMKernelAdaptersForVmnic -NetworkInfo $networkInfo -Vmnic 'vmnic1' -Server $server)
Assert-True ($teamedStandard.Count -eq 1 -and $teamedStandard[0].Name -eq 'vmk0') 'Teamed standard uplink mapping failed.'
$distributed = @(Get-VMKernelAdaptersForVmnic -NetworkInfo $networkInfo -Vmnic 'vmnic2' -Server $server)
Assert-True ($distributed.Count -eq 1 -and $distributed[0].Name -eq 'vmk1' -and $distributed[0].Mac -eq '00:50:56:00:00:11' -and $distributed[0].NetworkLabel -eq 'DVS-vMotion') 'Distributed-switch VMkernel mapping failed.'
$teamedDistributed = @(Get-VMKernelAdaptersForVmnic -NetworkInfo $networkInfo -Vmnic 'vmnic3' -Server $server)
Assert-True ($teamedDistributed.Count -eq 1 -and $teamedDistributed[0].Name -eq 'vmk1') 'Teamed distributed uplink mapping failed.'
$none = @(Get-VMKernelAdaptersForVmnic -NetworkInfo $networkInfo -Vmnic 'vmnic4' -Server $server)
Assert-True ($none.Count -eq 0) 'Unattached vmnic returned VMkernel adapters.'
Assert-True ((Get-PropertyText -InputObject ([pscustomobject]@{Empty=''}) -Name 'Empty') -eq $null) 'Empty values must be normalized to null.'
Assert-True ((Get-PropertyText -InputObject ([pscustomobject]@{Name='value'}) -Name 'Name') -eq 'value') 'Property text retrieval failed.'
Write-Host 'ESXi vmnic VMkernel mapping checks passed.'
