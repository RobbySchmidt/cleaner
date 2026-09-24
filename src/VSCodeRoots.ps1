function Get-VSCodeRoots {
    param(
        [string]$CodeRoot    = (Join-Path $env:APPDATA 'Code'),
        [string]$UserProfile = $env:USERPROFILE,
        [string]$ClaudeRoot
    )

    # Derived from -UserProfile, not straight from $env:USERPROFILE, so every test that
    # already passes -UserProfile $TestDrive stays isolated from the real ~\.claude.
    if (-not $ClaudeRoot) { $ClaudeRoot = Join-Path $UserProfile '.claude' }

    [pscustomobject]@{
        CodeRoot          = $CodeRoot
        WorkspaceStorage  = Join-Path $CodeRoot 'User\workspaceStorage'
        History           = Join-Path $CodeRoot 'User\History'
        Backups           = Join-Path $CodeRoot 'Backups'
        Logs              = Join-Path $CodeRoot 'logs'
        DotVscode         = Join-Path $UserProfile '.vscode'
        ClaudeRoot        = $ClaudeRoot
        ClaudeProjects    = Join-Path $ClaudeRoot 'projects'
        ClaudeFileHistory = Join-Path $ClaudeRoot 'file-history'
        ClaudeSessionEnv  = Join-Path $ClaudeRoot 'session-env'
        ClaudeSessions    = Join-Path $ClaudeRoot 'sessions'
    }
}

# Allowlists only the roots the scanners actually emit from -- NOT CodeRoot or ClaudeRoot
# wholesale. Permitting all of %APPDATA%\Code would also permit deleting User\settings.json,
# snippets, Preferences and machineid; permitting all of ~\.claude would permit
# settings.json, .credentials.json and plugins. None of those can be produced by a scanner.
# A scanner bug that emitted a parent directory would then pass validation and
# Remove-Item -Recurse would take shared state with it. .vscode is deliberately absent: it
# is a discovery watch target, never a deletion source. ClaudeSessions is absent too: it is
# read by the running-session check, never deleted. A future scanner that needs a new root
# must add it here deliberately rather than inherit deletion rights.
#
# Lexical check only. GetFullPath normalizes '.', '..', slashes and 8.3 short names, but it
# does NOT resolve NTFS reparse points -- a junction inside a root still reads as "inside"
# even though it points elsewhere. Resolving link targets needs P/Invoke on PowerShell 5.1,
# and this function must also work on fixture paths that do not exist on disk, so the
# reparse-point guard lives in Remove-VSCodeArtifacts, where deletion happens.
function Test-PathUnderArtifactRoots {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Roots
    )

    $cmp       = [System.StringComparison]::OrdinalIgnoreCase
    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    $allowed = @($Roots.WorkspaceStorage, $Roots.History, $Roots.Backups, $Roots.Logs,
                 $Roots.ClaudeProjects, $Roots.ClaudeFileHistory, $Roots.ClaudeSessionEnv)

    foreach ($root in $allowed) {
        if (-not $root) { continue }
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        # Explicit for intent; subsumed by the separator in the StartsWith below.
        if ($candidate.Equals($r, $cmp)) { return $false }
        if ($candidate.StartsWith($r + '\', $cmp)) { return $true }
    }

    return $false
}
