# vSphere 8 Update 3 PowerCLI toolkit

Interactive administration of Windows VMs, VDI assignments, virtual hardware,
disk expansion, and ESXi switch connectivity. Target: Windows PowerShell 5.1
and VMware.VimAutomation.Core, with Windows guest commands through VMware Tools.
VDI account lookup also requires the ActiveDirectory module.

Keep the **Modules** folder beside the scripts. The common toolkit release is
displayed at startup and recorded with disk operations. Filename versions identify
the workflow generation; the toolkit release identifies this shared implementation.

## Start and repeat workflows

```powershell
.\Start-PowerCLITools.ps1
.\Start-PowerCLITools.ps1 -Preview
```

The launcher offers to repeat a workflow or return to its menu. Existing vCenter
sessions remain connected. Each script reuses one connection or asks you to select
one when several are active. Optional -VIServer selects a named connection.
Guest passwords stay in memory for one script invocation; they are not logged.
Enter exit at text prompts or cancel credential dialogs to stop. Completed changes
are not rolled back automatically.

## Preview changes

All five mutating workflows support -WhatIf:

```powershell
.\Expand-VSphereVmDisk-v3.ps1 -VMName APP01 -DiskNumber 1 -GBSizeToIncrease 20 -WhatIf
.\Expand-MultipleVSphereVmDisks-v1.ps1 -VMName 'APP-*' -DriveLetter C -TargetCapacityGB 160 -WhatIf
.\Add-vHardware-v1.ps1 -VMName APP01 -Action Memory -MemoryGBToAdd 8 -WhatIf
.\Assign-VDI-v1.ps1 -WhatIf
.\New-DevDesktops-v3.ps1 -WhatIf
```

Preview may connect, ask for selection/credentials, and read inventory. Server disk
labels and batch drive mapping need read-only guest commands. Batch preview does
not rescan guest storage. Preview does not resize, delete partitions, rename VMs,
grant access, create custom attributes, clone VMs, create VM folders, or log a disk
operation. Single-VM preview describes optional guest extension without attempting
partition selection/deletion. It cannot predict all runtime failures.

## vSphere disk history

The expansion, hardware, and desktop-creation scripts write **Logs/DiskOperations.csv**.
Use the same -LogPath on each workstation for shared history:

```powershell
.\Expand-VSphereVmDisk-v3.ps1 -LogPath '\\fileserver\ITLogs\DiskOperations.csv'
.\ShowSQLDisk.ps1 -VMName SQL01 -LogPath '\\fileserver\ITLogs\DiskOperations.csv'
```

Logs record vSphere hard disk operations only, not Windows partition changes,
CPU/memory changes, passwords, or unrelated vSphere UI operations. VM selection
shows the last successful recorded disk change and warns about unresolved attempts.
Identity uses vCenter plus VM instance UUID, so a VM rename keeps its history.

Columns:

- OperationId, StartedUTC, CompletedUTC
- VCenter, VCenterUser, Operator
- VMName, VMInstanceUUID, VMId, Cluster
- Operation, HardDisk, VMDKPath, Datastore
- OldCapacityGB, RequestedIncreaseGB, RequestedCapacityGB, VerifiedCapacityGB
- Result, ErrorMessage, ScriptName, ScriptVersion

Each operation appends a Started row followed by a Success, Failed, or Unverified
row with the same OperationId. For reporting, use the last row for each operation.
An unmatched Started row requires investigation, not an automatic retry.
Cloning records the combined template-disk capacity and created paths in one
CloneVMDisks operation. A clone interrupted before identity is known is recorded
by requested name and operation ID; inspect the CSV directly for those attempts.

Logging must succeed before disk changes start. If completion logging fails,
the script stops dependent work and asks you to verify the actual state.
CSV appends use an exclusive writer lock and reject incompatible headers.
This is operational tracking, not a tamper-proof audit system. Secure and back up
the log share. Logs contain infrastructure names and operator identities.
Logs, Reports, and TestResults are Git-ignored; do not commit production exports.

## Verification and datastore warnings

Disk expansion refreshes the selected disk, rejects changed plans and snapshots,
and verifies the resulting capacity before any dependent partition work.
Disk attachment also checks capacity and controller. Cloning checks disk capacities.
The guest helper probes VMware Tools execution before running a guest command.
Recognized authentication failures prompt again. Unknown guest failures are not
automatically replayed because the operation might already have changed the VM.

Disk-writing scripts accept:

- -MinimumDatastoreFreePercent (default 10)
- -MinimumDatastoreFreeGB (default 50)
- -MaximumDatastoreProvisionedPercent (default 150)

Thin virtual capacity is potential future allocation, not space immediately used.
Projected provisioning is an estimate based on datastore usage plus uncommitted
space and the requested increase; concurrent activity can change it. Thresholds
warn, not reserve capacity. Known thick changes exceeding free space are blocked.
Clone provisioning follows the template and the report is a conservative estimate.

## VDI identity tracking

Successful primary assignments/reassignments save:

- VDI.AssignedADAccount
- VDI.AssignedADSID

Additional users are recorded as account/SID JSON in VDI.AdditionalUsers without
overwriting the primary assignment. Duplicate checks use SIDs and fall back to
the assigned-name suffix for legacy VMs without primary SID metadata.
Attributes are created when needed; the operator needs permissions to create
custom fields and set their values.

If assignment succeeds but metadata cannot be verified, the result is
Partial-MetadataFailed. Repair the attributes rather than repeating the assignment.
Reassignment does **not** remove previous GPO-managed access. Attributes track
assignments made by the toolkit, not every effective group membership; previous
primary assignments are replaced, not retained as current assignments.

## Inventory export

```powershell
.\ShowSQLDisk.ps1 -VMName SQL01 -CsvReportPath .\Reports\SQL01-disks.csv
```

Create the Reports directory first. Export contains the displayed unformatted
disk values plus UTC collection time, vCenter and VM name. An existing report
is not overwritten. Potential Excel formula strings are escaped.

## Offline validation

```powershell
& .\.agents\skills\vsphere-8u3-powercli\scripts\Test-PowerCLIScriptSyntax.ps1 -Path . -Recurse
& .\Tests\Test-Toolkit.ps1
```

GitHub Actions runs the same parser and mocked regression checks on pushes and
pull requests. Tests do not require vCenter credentials or mutate infrastructure.
They do not replace controlled testing against your vSphere/Windows environment.
