<#
.SYNOPSIS
    One-off sanity check: records every path VS Code and Claude Code write under their own roots during a
    work session, then diffs that against what the resolver would have found.

.EXAMPLE
    .\vscode-discover.ps1 -Project 'D:\Nuxt\throwaway'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\src\VSCodeUri.ps1"
. "$PSScriptRoot\src\VSCodeRoots.ps1"
. "$PSScriptRoot\src\VSCodeSources.ps1"
. "$PSScriptRoot\src\ClaudeCodeSources.ps1"
. "$PSScriptRoot\src\ProjectArtifacts.ps1"
. "$PSScriptRoot\src\VSCodeReport.ps1"
. "$PSScriptRoot\src\VSCodeDiff.ps1"

if (-not $LogPath) {
    $LogPath = Join-Path (Get-Location) "vscode-discover-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

$roots    = Get-VSCodeRoots
$written  = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
$watchers = @()

foreach ($dir in @($roots.CodeRoot, $roots.DotVscode, $roots.ClaudeRoot)) {
    if (-not (Test-Path $dir)) { continue }

    $w = New-Object System.IO.FileSystemWatcher $dir
    $w.IncludeSubdirectories = $true
    $w.InternalBufferSize    = 65536
    $w.NotifyFilter          = [System.IO.NotifyFilters]::FileName -bor
                               [System.IO.NotifyFilters]::DirectoryName -bor
                               [System.IO.NotifyFilters]::LastWrite
    $w.EnableRaisingEvents   = $true

    foreach ($evt in @('Created', 'Changed')) {
        Register-ObjectEvent -InputObject $w -EventName $evt -MessageData $written -Action {
            $null = $Event.MessageData.Add($Event.SourceEventArgs.FullPath)
        } | Out-Null
    }

    $watchers += $w
}

Write-Host "Watching $($watchers.Count) root(s)."
Write-Host "Now put '$Project' through a full lifecycle in VS Code:"
Write-Host "  create it, open it, edit several files, let extensions activate,"
Write-Host "  start a Claude Code session in it, have it edit a file, quit it,"
Write-Host "  close the window, reopen it, then close VS Code entirely."
Read-Host "Press Enter when done"

foreach ($w in $watchers) { $w.EnableRaisingEvents = $false }
Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.IO.FileSystemWatcher] } | Unregister-Event
foreach ($w in $watchers) { $w.Dispose() }

$written | Sort-Object | Out-File -FilePath $LogPath -Encoding utf8
Write-Host "Recorded $($written.Count) written path(s) -> $LogPath"

$artifacts = @(Get-ProjectArtifacts -Project $Project -Roots $roots)
$diff      = Compare-DiscoveryToResolver -WrittenPaths @($written) -Artifacts $artifacts

$gapLog = [System.IO.Path]::ChangeExtension($LogPath, '.gaps.txt')
$diff.Gaps | Sort-Object | Out-File -FilePath $gapLog -Encoding utf8

Write-Host ""
Write-Host "Covered by resolver: $($diff.Covered.Count) written path(s)"
Write-Host "GAPS (would be left behind): $($diff.Gaps.Count) -> $gapLog"
Write-Host "Stale artifacts from earlier sessions: $($diff.Stale.Count) (expected, not a bug)"

# Writes recorded but nothing covered almost always means the watched session and the
# -Project argument disagree -- typically a different folder was opened in VS Code than
# the one named here. Without this the run looks like a catastrophic resolver failure
# ("every path is a gap") when in fact it answered a question about the wrong project.
if ($written.Count -gt 0 -and $diff.Covered.Count -eq 0) {
    Write-Warning ("Recorded $($written.Count) write(s) but covered none of them. That usually means the " +
                   "folder opened in VS Code was not '$Project'. Check that -Project matches the folder " +
                   "you actually opened, then re-run. The gap list is not meaningful until it does.")
    if ($artifacts.Count -eq 0) {
        Write-Warning "The resolver also found no artifacts at all for '$Project', which supports that reading."
    }
}
