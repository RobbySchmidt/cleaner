<#
.SYNOPSIS
    Finds (and optionally deletes) everything VS Code and Claude Code wrote outside a
    project folder on that project's behalf.

.EXAMPLE
    .\vscode-cleanup.ps1 -Project 'D:\Nuxt\foo'
    .\vscode-cleanup.ps1 -Project 'D:\Nuxt\foo' -Delete
    .\vscode-cleanup.ps1 -Project 'D:\Nuxt\foo' -Delete -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [switch]$Delete,
    [switch]$IncludeProbable,
    [string]$ReportPath,
    # Testing seam, and genuinely useful for a portable VS Code install.
    # Without it this script has no way to be pointed at a fixture, which would leave
    # the one place -Delete is wired up as the only untested code in the project.
    [string]$CodeRoot,
    # Same seam for ~\.claude. Tests must pass it: without it they would scan the real one.
    [string]$ClaudeRoot
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\src\VSCodeUri.ps1"
. "$PSScriptRoot\src\VSCodeRoots.ps1"
. "$PSScriptRoot\src\VSCodeSources.ps1"
. "$PSScriptRoot\src\ClaudeCodeSources.ps1"
. "$PSScriptRoot\src\ProjectArtifacts.ps1"
. "$PSScriptRoot\src\VSCodeReport.ps1"
. "$PSScriptRoot\src\VSCodeRemove.ps1"

$rootArgs = @{}
if ($CodeRoot)   { $rootArgs.CodeRoot   = $CodeRoot }
if ($ClaudeRoot) { $rootArgs.ClaudeRoot = $ClaudeRoot }
$roots     = Get-VSCodeRoots @rootArgs
$artifacts = @(Get-ProjectArtifacts -Project $Project -Roots $roots | Add-ArtifactSize)

if (-not $ReportPath) {
    $safeName   = (Split-Path $Project -Leaf) -replace '[^\w\-]', '_'
    $ReportPath = Join-Path (Get-Location) "vscode-artifacts-$safeName-$(Get-Date -Format 'yyyyMMdd').txt"
}

Write-ArtifactReport -Artifacts $artifacts -Project $Project -ReportPath $ReportPath | Out-Null

$total = ($artifacts | Measure-Object -Property SizeBytes -Sum).Sum
if (-not $total) { $total = 0 }
Write-Host "Found $($artifacts.Count) artifact(s), $([math]::Round($total / 1MB, 2)) MB"
Write-Host "Report: $ReportPath"

if (-not $Delete) {
    Write-Host "Nothing was deleted. Re-run with -Delete to purge."
    return
}

if (Test-VSCodeRunning) {
    # "Close it first" is not enough and is actively misleading: VS Code keeps state.vscdb
    # open for every workspace it touched this session and releases the handles only on
    # exit. Measured on this machine: 14 workspaces locked while 2 windows were open.
    Write-Warning ("VS Code is running. Quit it completely before deleting - closing the project's " +
                   "window is not enough, because VS Code holds state.vscdb open for every workspace " +
                   "it touched this session. Otherwise those artifacts stay locked and are left behind.")
}

$running = @(Get-ClaudeRunningSessions -Roots $roots -ProjectUri (ConvertTo-VSCodeUri -Path $Project))
if ($running.Count -gt 0) {
    # A live session keeps appending to its transcript, so deleting under it either fails
    # on the lock or leaves a fresh transcript behind the moment the session writes again.
    Write-Warning ("Claude Code is running in this project (PID $(($running | ForEach-Object { $_.ProcessId }) -join ', ')). " +
                   "Quit that session first - it is still writing its transcript, which would be " +
                   "left behind or recreated.")
}

$removed = @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots -IncludeProbable:$IncludeProbable)
Write-Host "Deleted $($removed.Count) artifact(s)."
