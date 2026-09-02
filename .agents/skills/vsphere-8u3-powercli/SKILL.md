---
name: vsphere-8u3-powercli
description: Create, modify, review, and troubleshoot PowerCLI scripts in this repository for VMware vSphere 8 Update 3 and Windows guests. Use for vCenter connections, VM inventory or lifecycle, virtual hardware and disks, ESXi networking, VMware Tools guest operations, and interactive or CSV PowerCLI workflows. Do not use for VCF 9 automation or generic PowerShell unrelated to vSphere.
---

# vSphere 8u3 PowerCLI

Maintain production-oriented PowerCLI scripts for this repository without importing
VCF 9 assumptions. The current compatibility baseline is VMware vSphere 8 Update 3,
VMware.VimAutomation.Core, and Windows PowerShell 5.1-compatible syntax unless the
user explicitly requests a migration.

## Working method

1. Inspect the target script, nearby implementations, and the Git working tree before
   editing. Preserve unrelated user changes.
2. Read [repository-conventions.md](references/repository-conventions.md) before
   creating a script or changing parameters, prompts, vCenter selection, object
   matching, guest operations, or infrastructure mutations.
3. Confirm cmdlet and parameter behavior instead of inferring it. Prefer Get-Command
   and Get-Help -Full from the installed module. If that is unavailable, use the
   official Broadcom documentation for the applicable PowerCLI and vSphere release.
4. Resolve exact inventory targets and show a read-only preflight before changes.
   Never test a script by mutating a live vCenter unless the user explicitly requests
   that execution.
5. Keep guest OS automation consistent with the existing VMware Tools pattern. Use
   WinRM only when the user explicitly chooses it.
6. After editing, run the included syntax validator. Add focused mocked tests when the
   change affects selection, branching, destructive operations, VMware Tools output,
   or post-change verification.
7. Review the final diff and working-tree status. Commit or push only when authorized
   by the active user request or established repository workflow.

## Verification

For one script:

    & .\.agents\skills\vsphere-8u3-powercli\scripts\Test-PowerCLIScriptSyntax.ps1 -Path .\Assign-VDI-v1.ps1

For every PowerCLI script in the repository:

    & .\.agents\skills\vsphere-8u3-powercli\scripts\Test-PowerCLIScriptSyntax.ps1 -Path . -Recurse

The validator checks ordinary PowerShell syntax. When a change modifies PowerShell
stored inside a here-string for Invoke-VMScript, separately exercise that guest block
through a mock or parse the extracted block because the outer parser treats it as text.
