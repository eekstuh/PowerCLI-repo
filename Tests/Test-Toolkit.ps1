#requires -Version 5.1
<#
.SYNOPSIS
Runs offline toolkit regression tests without PowerCLI or infrastructure access.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Management
Import-Module Microsoft.PowerShell.Utility
Import-Module Microsoft.PowerShell.Security
$PSModuleAutoLoadingPreference = 'None'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Modules\PowerCLI.Toolkit.psm1') -Force
$module = Get-Module PowerCLI.Toolkit
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('PowerCLI-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$script:passed = 0
$savedDefaultServer = Get-Variable DefaultVIServer -Scope Global -ErrorAction SilentlyContinue
$savedDefaultServers = Get-Variable DefaultVIServers -Scope Global -ErrorAction SilentlyContinue
$savedDefaultServerValue = if ($null -ne $savedDefaultServer) { $savedDefaultServer.Value }
$savedDefaultServersValue = if ($null -ne $savedDefaultServers) { $savedDefaultServers.Value }
function Assert-True { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action,[string]$Pattern)
    try { & $Action } catch {
        if ($_.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($_.Exception.Message)" }
        return
    }
    throw "Expected an error matching '$Pattern'."
}
function Test-Case {
    param([string]$Name,[scriptblock]$Body)
    & $Body
    $script:passed++
    Write-Host "[PASS] $Name" -ForegroundColor Green
}
function Get-WorkflowFunctions {
    param([string]$File)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $File),[ref]$null,[ref]$null)
    return ($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] } |
        ForEach-Object { $_.Extent.Text }) -join "`n"
}

function Invoke-TestWorkflowPreview {
    param([string]$File, [hashtable]$Arguments=@{}, [string]$Overrides)
    $path = Join-Path $root $File
    $source = Get-Content -LiteralPath $path -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$null)
    $main = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } | Select-Object -First 1
    $injected = @'
$previewServer = [pscustomobject]@{Name='vc-preview';Version='8.0.3';Build='test'}
$previewVM = [pscustomobject]@{
    Name='VM01';Id='vm-1';PowerState='PoweredOff';NumCpu=8;MemoryGB=16
    ExtensionData=[pscustomobject]@{
        Config=[pscustomobject]@{CpuHotAddEnabled=$false;MemoryHotAddEnabled=$false;InstanceUuid='uuid-1'}
        Guest=[pscustomobject]@{ToolsRunningStatus='guestToolsRunning';GuestFamily='windowsGuest'}
    }
}
$previewDisk = [pscustomobject]@{
    Name='Hard disk 1';Id='disk-1';CapacityGB=100;Filename='[DS01] VM01/disk.vmdk';StorageFormat='Thin'
    ExtensionData=[pscustomobject]@{Backing=[pscustomobject]@{Datastore=[pscustomobject]@{Value='datastore-1'}}}
}
$previewDatastore = [pscustomobject]@{Name='DS01';Id='Datastore-datastore-1';CapacityGB=1000;FreeSpaceGB=500;ExtensionData=[pscustomobject]@{Summary=[pscustomobject]@{Uncommitted=0}}}
function Get-VCenterConnection { return $previewServer }
function Connect-VCenterIfNeeded { return $previewServer }
function Get-VM { param($Server,$Location,$Id,$ErrorAction) return $previewVM }
function Get-Datastore { param($Id,$Server,$ErrorAction) return $previewDatastore }
function Get-Snapshot { param($VM,$Server,$ErrorAction) }
function Read-YesNo { param($Prompt) return $false }
function Set-VM { throw 'Unexpected Set-VM mutation in preview' }
function Set-HardDisk { throw 'Unexpected Set-HardDisk mutation in preview' }
function Expand-ToolkitDisk { throw 'Unexpected resize helper in preview' }
function Add-UniqueVirtualDisk { throw 'Unexpected disk attachment in preview' }
function Add-GuestRemoteDesktopUserWithCorrection { throw 'Unexpected guest membership mutation in preview' }
function Set-ToolkitAssignmentIdentity { throw 'Unexpected identity mutation in preview' }
function New-VM { throw 'Unexpected VM creation in preview' }
function Get-OrCreateVmFolder { throw 'Unexpected folder creation in preview' }
function Write-ToolkitCsvRecord { throw 'Unexpected disk log mutation in preview' }
function Invoke-WindowsGuestPartitionExtension { throw 'Unexpected guest partition workflow in preview' }
'@
    $source = $source.Insert($main.Extent.StartOffset, $injected + "`n" + $Overrides + "`n")
    $source = $source -replace '(?m)^#requires -Modules.*\r?\n',''
    $source = $source -replace "(?m)^Import-Module \(Join-Path .*PowerCLI.Toolkit.psm1.*\r?\n",''
    $source = $source.Replace('$PSScriptRoot', ("'" + $root.Replace("'","''") + "'"))
    $Arguments.WhatIf = $true
    & ([scriptblock]::Create($source)) @Arguments
}

# All PowerCLI calls resolve to these module-local test doubles. Automatic module
# loading is disabled, so no real PowerCLI endpoint can be reached.
& $module {
    $script:MockVM = [pscustomobject]@{Name='VM01';Id='VirtualMachine-vm-1';ExtensionData=[pscustomobject]@{Config=[pscustomobject]@{InstanceUuid='uuid-1'}}}
    $script:MockCapacity = 100
    $script:MockSnapshots = @()
    $script:MockMutations = 0
    $script:MockResizeMode = 'Success'
    function script:Get-VM { param($Id,$Server,$ErrorAction) return $script:MockVM }
    function script:Get-Cluster { param($VM,$Server,$ErrorAction) [pscustomobject]@{Name='Cluster01'} }
    function script:Get-HardDisk {
        param($VM,$Server,$ErrorAction)
        [pscustomobject]@{Id='disk-1';Name='Hard disk 1';CapacityGB=$script:MockCapacity;Filename='[DS01] VM01/disk.vmdk'}
    }
    function script:Get-Snapshot { param($VM,$Server,$ErrorAction) return $script:MockSnapshots }
    function script:Set-HardDisk {
        param($HardDisk,$CapacityGB,$Server,$Confirm,$ErrorAction)
        $script:MockMutations++
        if ($script:MockResizeMode -eq 'Failure') { throw 'simulated resize failure' }
        if ($script:MockResizeMode -eq 'Mismatch') { $script:MockCapacity = $CapacityGB - 1 }
        else { $script:MockCapacity = $CapacityGB }
    }
    $script:MockGuestCalls = 0
    $script:MockGuestMode = 'Success'
    $script:MockReplacement = [pscredential]::new('replacement',(ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force))
    function script:Read-ToolkitGuestCredential { return $script:MockReplacement }
    function script:Invoke-VMScript {
        param($VM,$GuestCredential,$ScriptType,$ScriptText,$Server,$ErrorAction,$Confirm,$WhatIf)
        $script:MockGuestCalls++
        if ($script:MockGuestMode -eq 'Auth' -and $GuestCredential.UserName -ne 'replacement') {
            throw 'Failed to authenticate with the guest operating system'
        }
        if ($script:MockGuestMode -eq 'Unknown') { throw 'transport interrupted after dispatch' }
        if ($script:MockGuestMode -eq 'Vix1') { throw 'A general system error occurred: vix error codes = (1, 0)' }
        if ($ScriptText -match 'POWERCLI_GUEST_READY') { return [pscustomobject]@{ExitCode=0;ScriptOutput='POWERCLI_GUEST_READY'} }
        if ($script:MockGuestMode -eq 'Empty') { return [pscustomobject]@{ExitCode=1;ScriptOutput=''} }
        if ($script:MockGuestMode -eq 'Noise') { return [pscustomobject]@{ExitCode=0;ScriptOutput='Guest output without markers'} }
        $marker = [regex]::Match($ScriptText,'POWERCLI_[0-9a-f]+_BEGIN').Value
        $end = $marker.Replace('_BEGIN','_END')
        [pscustomobject]@{ExitCode=0;ScriptOutput="Guest noise`n$marker`n{""ok"":true}`n$end`nTrailing noise"}
    }
    $script:MockAnnotations = @{}
    function script:Get-Annotation {
        param($Entity,$Server,$CustomAttribute,$ErrorAction)
        $rows = @($script:MockAnnotations[$Entity.Id])
        if ($CustomAttribute) { return @($rows | Where-Object Name -eq $CustomAttribute.Name) }
        return $rows
    }
    function script:Get-CustomAttribute { param($Server,$ErrorAction) }
    function script:New-CustomAttribute { param($Name,$TargetType,$Server,$Confirm,$ErrorAction) [pscustomobject]@{Name=$Name;TargetType=$TargetType} }
    function script:Set-Annotation {
        param($Entity,$CustomAttribute,$Value,$Server,$Confirm,$ErrorAction)
        $script:MockAnnotations[$Entity.Id] = @($script:MockAnnotations[$Entity.Id] | Where-Object Name -ne $CustomAttribute.Name) +
            @([pscustomobject]@{Name=$CustomAttribute.Name;Value=$Value})
    }
}
$server = [pscustomobject]@{Name='vc01';User='operator'}
$vm = & $module { $script:MockVM }
function Reset-DiskMocks {
    & $module { $script:MockCapacity=100; $script:MockMutations=0; $script:MockResizeMode='Success'; $script:MockSnapshots=@() }
}
function Reset-GuestMocks {
    & $module { $script:GuestCredentials=@{}; $script:GuestReady=@{}; $script:MockGuestCalls=0; $script:MockGuestMode='Success' }
}
$credential = [pscredential]::new('tester',(ConvertTo-SecureString 'not-a-real-password' -AsPlainText -Force))
try {
    Test-Case 'Module and embedded guest scripts parse' {
        $files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File) + @(Get-ChildItem -LiteralPath (Join-Path $root 'Modules') -Filter '*.psm1' -File)
        foreach ($file in $files) {
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$null,[ref]$errors)
            Assert-True ($errors.Count -eq 0) "$($file.Name): $errors"
            $strings = $ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $node.StringConstantType -eq 'SingleQuotedHereString'
            },$true)
            foreach ($string in $strings) {
                $guestText = $string.Value.Replace('__REFRESH_STORAGE__','$false')
                if ($guestText -notmatch 'Get-Partition|Get-Volume|Get-LocalGroup|guestResults') { continue }
                $guestErrors = $null
                [void][System.Management.Automation.Language.Parser]::ParseInput($guestText,[ref]$null,[ref]$guestErrors)
                Assert-True ($guestErrors.Count -eq 0) "$($file.Name) guest block: $guestErrors"
            }
        }
    }
    Test-Case 'CSV started/success records share ID and verified capacity' {
        Reset-DiskMocks
        $disk = & $module { Get-HardDisk }
        $path = Join-Path $testRoot 'success.csv'
        $result = Expand-ToolkitDisk -VM $vm -Server $server -Disk $disk -TargetGB 120 -LogPath $path -ScriptName 'test'
        $rows = @(Import-Csv $path)
        Assert-True ($result.CapacityGB -eq 120 -and $rows.Count -eq 2) 'Resize or log row count failed.'
        Assert-True ($rows[0].Result -eq 'Started' -and $rows[1].Result -eq 'Success') 'Incorrect status sequence.'
        Assert-True ($rows[0].OperationId -eq $rows[1].OperationId -and $rows[1].VerifiedCapacityGB -eq 120) 'Incorrect operation identity or verification.'
    }
    Test-Case 'Changed capacity and snapshots stop mutation' {
        Reset-DiskMocks
        $disk = & $module { Get-HardDisk }
        & $module { $script:MockCapacity=110 }
        Assert-Throws { Expand-ToolkitDisk -VM $vm -Server $server -Disk $disk -TargetGB 120 -LogPath (Join-Path $testRoot 'changed.csv') } 'changed after'
        Reset-DiskMocks
        & $module { $script:MockSnapshots=@('snapshot') }
        Assert-Throws { Expand-ToolkitDisk -VM $vm -Server $server -Disk $disk -TargetGB 120 -LogPath (Join-Path $testRoot 'snap.csv') } 'snapshots'
        Assert-True ((& $module { $script:MockMutations }) -eq 0) 'A blocked disk was mutated.'
    }
    Test-Case 'Verification mismatch is Unverified, never Success' {
        Reset-DiskMocks
        & $module { $script:MockResizeMode='Mismatch' }
        $disk = & $module { Get-HardDisk }
        $path = Join-Path $testRoot 'mismatch.csv'
        Assert-Throws { Expand-ToolkitDisk -VM $vm -Server $server -Disk $disk -TargetGB 120 -LogPath $path } 'could not be verified'
        Assert-True ((@(Import-Csv $path)[-1]).Result -eq 'Unverified') 'Unverified disk was marked successful.'
    }
    Test-Case 'Failed resize is recorded without reporting success' {
        Reset-DiskMocks
        & $module { $script:MockResizeMode='Failure' }
        $disk = & $module { Get-HardDisk }
        $path = Join-Path $testRoot 'failed.csv'
        Assert-Throws { Expand-ToolkitDisk -VM $vm -Server $server -Disk $disk -TargetGB 120 -LogPath $path } 'simulated resize failure'
        Assert-True ((@(Import-Csv $path)[-1]).Result -eq 'Failed') 'Failure was not recorded.'
    }
    Test-Case 'Invalid log schema prevents disk mutation' {
        Reset-DiskMocks
        $disk = & $module { Get-HardDisk }
        $path = Join-Path $testRoot 'schema.csv'
        Write-ToolkitCsvRecord -Path $path -Record ([pscustomobject]@{Other='header'})
        Assert-Throws { Expand-ToolkitDisk -VM $vm -Server $server -Disk $disk -TargetGB 120 -LogPath $path } 'schema mismatch'
        Assert-True ((& $module { $script:MockMutations }) -eq 0) 'Mutation occurred despite log failure.'
    }
    Test-Case 'Reports escape formulas and refuse overwrites' {
        $path = Join-Path $testRoot 'report.csv'
        Export-ToolkitReport -Path $path -Rows @([pscustomobject]@{Label='=1+1';Size=10})
        $row = Import-Csv $path
        Assert-True ($row.Label -eq "'=1+1" -and $row.Size -eq '10') 'Unsafe or altered CSV value.'
        Assert-Throws { Export-ToolkitReport -Path $path -Rows @([pscustomobject]@{Label='new'}) } 'already exists'
    }
    Test-Case 'History follows VM UUID after rename and warns about interrupted operations' {
        $path = Join-Path $testRoot 'success.csv'
        $renamedVM = [pscustomobject]@{Name='VM01 - New Name';Id=$vm.Id;ExtensionData=$vm.ExtensionData}
        $messages = @(Show-ToolkitDiskHistory -VM $renamedVM -Server $server -Path $path 6>&1)
        Assert-True (($messages -join ' ') -match 'ExpandVirtualDisk: 100 GB -> 120 GB') 'History was lost after VM rename.'
        $record = New-ToolkitDiskRecord -VM $renamedVM -Server $server -Operation 'ExpandVirtualDisk' -OldCapacityGB 120 -RequestedCapacityGB 140
        Write-ToolkitCsvRecord -Path $path -Record $record
        $messages = @(Show-ToolkitDiskHistory -VM $renamedVM -Server $server -Path $path 3>&1 6>&1)
        Assert-True (($messages -join ' ') -match 'Latest recorded attempt: Started') 'Interrupted operation did not produce a warning.'
    }
    Test-Case 'Datastore thresholds distinguish thick capacity and missing provisioning data' {
        $datastore = [pscustomobject]@{Name='DS';CapacityGB=1000;FreeSpaceGB=40;ExtensionData=[pscustomobject]@{Summary=[pscustomobject]@{Uncommitted=$null}}}
        $messages = @(Show-ToolkitDatastoreCapacity -Datastore $datastore -AdditionalGB 50 -StorageFormat Thin 3>&1 6>&1)
        Assert-True (($messages -join ' ') -match 'below the configured threshold') 'Low free space was not flagged.'
        Assert-True (($messages -join ' ') -match 'cannot be evaluated') 'Missing provisioning data was presented as known.'
        Assert-Throws { Show-ToolkitDatastoreCapacity -Datastore $datastore -AdditionalGB 50 -StorageFormat Thick } 'Insufficient'
    }
    Test-Case 'Guest readiness and unique framing ignore surrounding output' {
        Reset-GuestMocks
        $json = Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test'
        Assert-True (($json | ConvertFrom-Json).ok) 'Framed JSON could not be extracted.'
        Assert-True ((& $module { $script:MockGuestCalls }) -eq 2) 'Readiness probe was not called.'
    }
    Test-Case 'Authentication failure retries with corrected credentials' {
        Reset-GuestMocks
        & $module { $script:MockGuestMode='Auth' }
        $null = Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test'
        Assert-True ((& $module { $script:MockGuestCalls }) -eq 3) 'Authentication retry count incorrect.'
    }
    Test-Case 'Empty password is replaced before VMware Tools is called' {
        Reset-GuestMocks
        $empty = [pscredential]::new('tester',[securestring]::new())
        $null = Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $empty -ScriptText 'test'
        Assert-True ((& $module { $script:MockGuestCalls }) -eq 2) 'Blank password was submitted.'
    }
    Test-Case 'Unknown guest failures are not replayed and VIX 1 is actionable' {
        Reset-GuestMocks
        & $module { $script:MockGuestMode='Unknown' }
        Assert-Throws { Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test' } 'transport interrupted'
        Assert-True ((& $module { $script:MockGuestCalls }) -eq 1) 'Unknown failure was retried.'
        Reset-GuestMocks
        & $module { $script:MockGuestMode='Vix1' }
        Assert-Throws { Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test' } 'Restart the VMware Tools service'
    }
    Test-Case 'Missing and empty guest payloads fail clearly' {
        Reset-GuestMocks
        & $module { $script:MockGuestMode='Noise' }
        Assert-Throws { Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test' } 'unframed'
        Reset-GuestMocks
        & $module { $script:MockGuestMode='Empty' }
        Assert-Throws { Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test' } 'no guest error details'
    }
    Test-Case 'SID metadata distinguishes users and retains additional identities' {
        Set-ToolkitAssignmentIdentity -VM $vm -Server $server -Account 'DOMAIN\primary' -SID 'S-1-5-21-1'
        Set-ToolkitAssignmentIdentity -VM $vm -Server $server -Account 'DOMAIN\extra' -SID 'S-1-5-21-2' -Additional
        $matches = @(Get-ToolkitDuplicateAssignments -VMs @($vm) -Server $server -SID 'S-1-5-21-2' -FullName 'Different Name')
        Assert-True ($matches.Count -eq 1) 'Additional SID was not found.'
        $matches = @(Get-ToolkitDuplicateAssignments -VMs @($vm) -Server $server -SID 'S-1-5-21-1' -FullName 'Renamed User')
        Assert-True ($matches.Count -eq 1) 'Primary SID was overwritten.'
        $legacy = [pscustomobject]@{Name='11VMDEV500 - Jane Smith';Id='legacy'}
        $matches = @(Get-ToolkitDuplicateAssignments -VMs @($legacy) -Server $server -SID 'S-1-5-21-3' -FullName 'Jane Smith')
        Assert-True ($matches.Count -eq 1) 'Legacy-name fallback failed.'
        Set-ToolkitAssignmentIdentity -VM $vm -Server $server -Account 'DOMAIN\extra2' -SID 'S-1-5-21-4' -Additional
        $matches = @(Get-ToolkitDuplicateAssignments -VMs @($vm) -Server $server -SID 'S-1-5-21-2' -FullName 'Different Name')
        Assert-True ($matches.Count -eq 1) 'Adding another user lost the previous additional SID.'
    }
    Test-Case 'Multiple connections require selection; one connection is reused' {
        $global:DefaultVIServer = $null
        $global:DefaultVIServers = @([pscustomobject]@{Name='vc01';IsConnected=$true},[pscustomobject]@{Name='vc02';IsConnected=$true})
        & $module { function script:Read-Host { param($Prompt) return '2' } }
        Assert-True ((Connect-ToolkitVCenter).Name -eq 'vc02') 'Wrong selected connection.'
        Assert-True ((Connect-ToolkitVCenter -Name vc01).Name -eq 'vc01') 'Explicit connection was not reused.'
        $global:DefaultVIServers = @($global:DefaultVIServers[0])
        Assert-True ((Connect-ToolkitVCenter).Name -eq 'vc01') 'Single connection was not reused.'
    }
    Test-Case 'Guest-only WhatIf stops before credentials or partition mutation' {
        $functions = Get-WorkflowFunctions 'Expand-VSphereVmDisk-v3.ps1'
        & {
            [CmdletBinding(SupportsShouldProcess)]
            param($Definitions)
            . ([scriptblock]::Create($Definitions))
            function Get-WindowsGuestCredential { throw 'Unexpected credential prompt in preview' }
            function Remove-WindowsBlockingPartition { throw 'Unexpected partition deletion in preview' }
            $script:WorkflowCmdlet = $PSCmdlet
            Invoke-WindowsGuestPartitionExtension -VM ([pscustomobject]@{Name='preview';PowerState='PoweredOn'})
        } -Definitions $functions -WhatIf
    }
    Test-Case 'Shared guest helper permits only explicitly read-only preview calls' {
        Reset-GuestMocks
        Assert-Throws {
            & {
                [CmdletBinding(SupportsShouldProcess)]param()
                Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test' -Preview:$WhatIfPreference
            } -WhatIf
        } 'Preview mode blocked'
        $result = & {
            [CmdletBinding(SupportsShouldProcess)]param()
            Invoke-ToolkitGuestPowerShell -VM $vm -Server $server -Credential $credential -ScriptText 'test' -ReadOnly -Preview:$WhatIfPreference
        } -WhatIf
        Assert-True (($result | ConvertFrom-Json).ok) 'Read-only preview failed.'
    }
    Test-Case 'All mutating workflows declare ShouldProcess and use shared helpers' {
        foreach ($file in @('Add-vHardware-v1.ps1','Assign-VDI-v1.ps1','Expand-MultipleVSphereVmDisks-v1.ps1','Expand-VSphereVmDisk-v3.ps1','New-DevDesktops-v3.ps1')) {
            $content = Get-Content -LiteralPath (Join-Path $root $file) -Raw
            Assert-True ($content -match 'CmdletBinding\([^\)]*SupportsShouldProcess') "$file lacks WhatIf."
            Assert-True ($content -match 'ShouldProcess\(') "$file lacks a mutation gate."
            Assert-True ($content -match 'PowerCLI.Toolkit.psm1') "$file lacks shared helpers."
        }
    }
    Test-Case 'Hardware CPU, memory and disk preview never call mutations' {
        $overrides = @'
function Select-ExactVM { return $previewVM }
function Get-VmCoresPerSocket { return 4 }
function Show-ExistingDisks { return $previewDisk }
function Select-ScsiController { [pscustomobject]@{Controller='SCSI 0';BusNumber=0;ControllerKey=1000;FreeUnitNumbers=@(1)} }
function Get-AvailableDatastores { return $previewDatastore }
function Select-Datastore { return $previewDatastore }
function Resolve-UniqueVmdkTarget { [pscustomobject]@{DatastorePath='[DS01] VM01/disk_1.vmdk'} }
'@
        Invoke-TestWorkflowPreview -File 'Add-vHardware-v1.ps1' -Arguments @{VMName='VM01';Action='CPU';TargetCPUCount=16} -Overrides $overrides
        Invoke-TestWorkflowPreview -File 'Add-vHardware-v1.ps1' -Arguments @{VMName='VM01';Action='Memory';MemoryGBToAdd=8} -Overrides $overrides
        Invoke-TestWorkflowPreview -File 'Add-vHardware-v1.ps1' -Arguments @{VMName='VM01';Action='Disk';DiskSizeGB=10} -Overrides $overrides
    }
    Test-Case 'Single-VM expansion preview stops before confirmation and mutation' {
        Invoke-TestWorkflowPreview -File 'Expand-VSphereVmDisk-v3.ps1' -Arguments @{VMName='VM01';DiskNumber=1;GBSizeToIncrease=20} -Overrides @'
function Select-VMWithGuestWorkflow { [pscustomobject]@{VM=$previewVM;GuestOSName='Windows 11';Workflow='Windows'} }
function Test-VMSnapshotPrerequisite { return $true }
function Select-HardDisk { return $previewDisk }
function Read-AdditionalCapacityGB { return 20 }
function Read-YesNo { throw 'Unexpected mutation confirmation in preview' }
'@
    }
    Test-Case 'Batch preview never changes VMDKs or Windows partitions' {
        Invoke-TestWorkflowPreview -File 'Expand-MultipleVSphereVmDisks-v1.ps1' -Arguments @{VMName='VM*';DriveLetter='C';TargetCapacityGB=120} -Overrides @'
$previewVM.PowerState='PoweredOn'
function Get-ResolvedGuestCredential { return $credential }
function Get-WindowsDriveState { [pscustomobject]@{PartitionSizeGB=99;FollowingPartition=$null} }
function Get-HardDiskForWindowsDrive { [pscustomobject]@{HardDisk=$previewDisk;Method='mock UUID'} }
function Resize-WindowsDrivePartition { throw 'Unexpected partition resize in preview' }
function Remove-AdjacentRecoveryPartition { throw 'Unexpected partition deletion in preview' }
'@
    }
    Test-Case 'VDI preview stops before credentials and metadata changes' {
        Invoke-TestWorkflowPreview -File 'Assign-VDI-v1.ps1' -Overrides @'
function Get-ExactCluster { [pscustomobject]@{Name='Developer Desktops'} }
function Initialize-ActiveDirectoryModule {}
function Get-AssignmentWorkItems {
    [pscustomobject]@{RowNumber=$null;ValidationError='';NamingConvention='SPECIFIC';RequestedVMName='VM01';FullName='Jane Smith';Consultant=$false;ADAccountName='jsmith';ADUserSID='S-1-5-21-1'}
}
function Confirm-DuplicateUserAssignment { [pscustomobject]@{Confirmed=$true} }
function Select-SpecificAssignmentVM { [pscustomobject]@{VM=$previewVM;TargetName='VM01 - Jane Smith'} }
function Get-WindowsGuestCredential { throw 'Unexpected guest credential prompt in VDI preview' }
'@
    }
    Test-Case 'Desktop creation preview never creates folders, VMs or disk logs' {
        Invoke-TestWorkflowPreview -File 'New-DevDesktops-v3.ps1' -Overrides @'
function Read-VmNamePrefix { return 'CUSTOM' }
function Read-CustomVmName { return 'VM02' }
function Get-Cluster { [pscustomobject]@{Name='Developer Desktops'} }
function Get-ExistingVmByBaseName {}
function Get-Template { [pscustomobject]@{Name='TMPL-11VM-UEFI'} }
function Get-ClusterRootResourcePool { [pscustomobject]@{Name='Resources'} }
function Get-BestDatastoreFromCluster { return $previewDatastore }
function Get-HardDisk { return $previewDisk }
'@
    }
    Test-Case 'SQL inventory CSV contains raw disk values in numeric disk order' {
        . ([scriptblock]::Create((Get-WorkflowFunctions 'ShowSQLDisk.ps1')))
        function Get-HardDisk {
            @(
                [pscustomobject]@{Name='Hard disk 10';CapacityGB=110;Filename='[DS01] disk10.vmdk'}
                [pscustomobject]@{Name='Hard disk 2';CapacityGB=120;Filename='[DS01] disk2.vmdk'}
            )
        }
        function Get-HardDiskDatastoreSpace { [pscustomobject]@{FreeSpaceGB=500;ProvisionedSpaceGB=900} }
        function Get-GuestVolumeDisplayForHardDisk { return 'D: (Data)' }
        function Get-HardDiskGuestFreeSpace { return '50' }
        $CsvReportPath = Join-Path $testRoot 'sql.csv'
        Show-VirtualDisks -VM $vm -Server $server -VolumeLabelsByPath @{}
        $rows = @(Import-Csv $CsvReportPath)
        Assert-True ($rows.Count -eq 2 -and $rows[0].Disk -eq 'Hard disk 2') 'Disk sort was not numeric.'
        Assert-True ($rows[0].HDCapacityGB -eq '120' -and $rows[0].VCenter -eq 'vc01') 'Raw export data is incorrect.'
        Assert-True ($rows[0].PSObject.Properties.Name -contains 'GuestVolFreeGB') 'Export is missing guest free space.'
    }
    Write-Host "`n$script:passed offline tests passed." -ForegroundColor Green
}
finally {
    if ($null -ne $savedDefaultServer) { Set-Variable DefaultVIServer -Value $savedDefaultServerValue -Scope Global }
    else { Remove-Variable DefaultVIServer -Scope Global -ErrorAction SilentlyContinue }
    if ($null -ne $savedDefaultServers) { Set-Variable DefaultVIServers -Value $savedDefaultServersValue -Scope Global }
    else { Remove-Variable DefaultVIServers -Scope Global -ErrorAction SilentlyContinue }
    Remove-Module PowerCLI.Toolkit
    # Only the exact temporary directory created above is removed.
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($tempParent,[StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot) -like 'PowerCLI-tests-*') {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
