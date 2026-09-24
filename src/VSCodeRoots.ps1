function Get-VSCodeRoots {
    param(
        [string]$CodeRoot    = (Join-Path $env:APPDATA 'Code'),
        [string]$UserProfile = $env:USERPROFILE
    )

    [pscustomobject]@{
        CodeRoot         = $CodeRoot
        WorkspaceStorage = Join-Path $CodeRoot 'User\workspaceStorage'
        History          = Join-Path $CodeRoot 'User\History'
        Backups          = Join-Path $CodeRoot 'Backups'
        Logs             = Join-Path $CodeRoot 'logs'
        DotVscode        = Join-Path $UserProfile '.vscode'
    }
}

# Allowlists only the four roots the scanners actually emit from -- NOT CodeRoot wholesale.
# Permitting all of %APPDATA%\Code would also permit deleting User\settings.json, snippets,
# Preferences and machineid, none of which any scanner can produce. A scanner bug that
# emitted a parent directory would then pass validation and Remove-Item -Recurse would take
# shared state with it. .vscode is deliberately absent: it is a discovery watch target
# (Task 15), never a deletion source. A future scanner that needs a new root must add it
# here deliberately rather than inherit deletion rights.
#
# Lexical check only. GetFullPath normalizes '.', '..', slashes and 8.3 short names, but it
# does NOT resolve NTFS reparse points -- a junction inside a root still reads as "inside"
# even though it points elsewhere. Resolving link targets needs P/Invoke on PowerShell 5.1,
# and this function must also work on fixture paths that do not exist on disk, so the
# reparse-point guard lives in Remove-VSCodeArtifacts (Task 12), where deletion happens.
function Test-PathUnderArtifactRoots {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Roots
    )

    $cmp       = [System.StringComparison]::OrdinalIgnoreCase
    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    foreach ($root in @($Roots.WorkspaceStorage, $Roots.History, $Roots.Backups, $Roots.Logs)) {
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        # Explicit for intent; subsumed by the separator in the StartsWith below.
        if ($candidate.Equals($r, $cmp)) { return $false }
        if ($candidate.StartsWith($r + '\', $cmp)) { return $true }
    }

    return $false
}
