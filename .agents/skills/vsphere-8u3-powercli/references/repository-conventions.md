# PowerCLI repository conventions

Read the sections relevant to the requested change. These are project-specific
decisions derived from the existing scripts; they are not universal PowerCLI rules.

## Compatibility and discovery

- Target VMware vSphere 8 Update 3. Preserve the existing #requires -Version 5.1
  and #requires -Modules VMware.VimAutomation.Core baseline when present.
- Do not replace VMware.PowerCLI or VMware.VimAutomation.Core with VCF.PowerCLI
  unless the user explicitly requests a VCF 9 migration.
- Use only Windows PowerShell 5.1-compatible language features in scripts that declare
  that baseline.
- Before using an unfamiliar cmdlet, parameter combination, extension-data property,
  or task result, confirm it with the installed module or official documentation.
  Inspect returned objects with Get-Member or the vSphere API type model when needed.
- Treat parameter-set errors as evidence that the proposed combination is invalid;
  do not retry by guessing additional parameters.

## vCenter connections

- Accept optional VIServer and Credential parameters when a script needs vCenter.
- Reuse a single active connection from $global:DefaultVIServer or
  $global:DefaultVIServers when VIServer is omitted.
- If no unambiguous active connection exists, prompt for the server and then credentials.
- Never call Connect-VIServer without a resolved -Server value.
- Do not use a bare Get-VIServer as a connection-discovery shortcut. Some installed
  environments resolve it through a legacy alias and prompt for Connect-VIServer's
  mandatory Server parameter.
- Pass the selected server object through functions and use -Server on PowerCLI
  cmdlets when supported so multiple sessions cannot redirect the operation.

## Object selection and scope

- Use the cluster, host, datastore, or VM scope requested by the user. Do not silently
  broaden a cluster-scoped task to the entire vCenter inventory.
- For an exact VM name, enumerate the intended scope and compare with -ieq.
  Get-VM -Name accepts wildcards and is not an exact-match guarantee.
- Reject wildcard characters for single-VM workflows. Accept them only in workflows
  explicitly designed for multiple VMs, then display the complete matched list before
  making changes.
- Refresh important objects by stable ID immediately before a mutation and verify that
  their relevant state has not changed.
- Sort numbered labels numerically. For example, display Hard disk 2 before
  Hard disk 10; do not rely on lexical name sorting.

## Parameters and interactive behavior

- Support both named parameters and interactive prompts when the workflow calls for
  both. Parameters should suppress only the corresponding prompt.
- Every ordinary text prompt must accept exit case-insensitively. Report whether no
  changes occurred or which irreversible step had already completed.
- When a secure credential is required interactively, first collect an exit-aware user
  name, then open Get-Credential. Request Windows guest credentials only when a guest
  operation is actually going to run.
- Use concise, professional wording. Say VM in prompts, use Enter VM name, and show
  yes/no choices as [Y/N] while accepting Y, Yes, N, and No.
- Separate major sections and decisions with one blank line. Avoid both crowded output
  and duplicate blank lines.
- For vertically grouped label/value output, calculate the longest label and render
  every row as label.PadRight(width) + ' : ' + value so colons align in a monospaced
  PowerShell console.
- Use ordered objects for deliberately ordered table columns. Keep units in column
  names, such as HardDiskCapacityGB and DatastoreFreeGB.

## Mutation safety and verification

- Gather and display current state, proposed state, and exact targets before changing
  infrastructure. Use SupportsShouldProcess when it improves command-line safety.
- Obtain explicit confirmation for interactive mutations unless the requested workflow
  is intentionally unattended. Require a typed confirmation phrase for irreversible
  partition deletion.
- After each mutation, retrieve fresh state and verify the requested outcome. Do not
  report success from a returned task object alone.
- Stop dependent work when its prerequisite did not occur. For example, if a requested
  target disk capacity is not greater than the current VMDK capacity, do not continue
  to Windows partition expansion.
- Do not execute production-affecting PowerCLI cmdlets as a test. Use parser checks,
  mocks, -WhatIf where genuinely supported, and read-only inventory calls.

## Virtual hardware

- Preserve VM CPU topology constraints. When changing total vCPU, confirm hot-add state,
  power state, supported totals, and a valid cores-per-socket value before Set-VM.
- For memory changes, validate the requested direction, hot-add behavior, VM power
  state, and resulting total before applying it.
- When adding a disk, show controllers and their currently attached disks, let the user
  choose the controller, and verify an available unit number.
- Generate a backing filename that is unique across every existing VM disk, including
  disks stored on different datastores. Verify the actual attached disk after creation.
- Avoid invalid New-HardDisk parameter combinations. Confirm the installed cmdlet's
  parameter set before combining datastore, path, controller, storage format, or capacity.

## Windows guest operations through VMware Tools

- Use Invoke-VMScript -ScriptType Powershell with a Windows administrator
  PSCredential; do not imply that VMware Tools uses WinRM.
- Base64-encode dynamic values embedded in guest script text rather than interpolating
  untrusted names or paths directly into executable PowerShell.
- Wrap guest output between unique begin/end markers. Check ExitCode, preserve useful
  guest error text, and report explicitly when VMware Tools returned no details.
- Return compact JSON only inside the markers. Extract the framed payload before
  ConvertFrom-Json; never pass mixed VMware Tools output directly to the JSON parser.
- Verify the guest result independently, such as group membership by SID or the final
  partition size. If guest identity resolves to a different AD SID, roll back a newly
  added membership when safe and do not rename the VM.

## Disk and partition expansion

- Expand the selected VMDK in vSphere before changing Windows, except in an explicit
  guest-only recovery mode.
- Display vSphere disks with numeric disk ordering and include guest volume labels only
  when VMware Tools mapping can establish them. Treat mapping failures as preflight
  failures rather than guessing.
- Before extending a Windows partition, rescan storage and show the Windows disk and
  partition layout. Confirm the selected partition again.
- Extend only into contiguous unallocated space. If another partition immediately
  follows the target, identify and report that blocker.
- Delete a blocking partition only after the user confirms the exact partition and then
  enters the required typed phrase. A Recovery partition warning must explain the WinRE
  consequence. Treat reagentc /disable reporting that WinRE is already disabled as a
  valid state, not by itself as a fatal error.
- After deletion, refresh the layout, confirm that the formerly blocked partition can
  now be extended, perform the extension, and verify its final size. Do not claim that
  the Recovery partition or WinRE was recreated unless the script actually does so.

## Script quality and handoff

- Maintain comment-based help for parameters, interactive behavior, credentials,
  guest-operation transport, destructive effects, and representative examples.
- Catch errors at boundaries where added context is useful, but preserve the underlying
  message. Avoid catch blocks that convert a failure into apparent success.
- Review git diff --check, PowerShell parser results, and git status before handoff.
- Preserve unrelated files and modifications. Commit and push only when authorized by
  the active request or an established repository workflow.
