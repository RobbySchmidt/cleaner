# 'Code - Insiders' is a separate process name; a user running Insiders would otherwise
# be told nothing is running while it holds files open.
function Test-VSCodeRunning {
    [bool](Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue)
}

# Test-PathUnderArtifactRoots is lexical and cannot see that a junction inside a root
# points outside it. Recursive delete has historically followed such links and destroyed
# the target's contents; it does not reproduce on every build, and is not contractually
# guaranteed either way -- do not remove this guard on the strength of one build behaving.
# Detecting a reparse point is cheap; resolving its target needs P/Invoke, so refuse
# rather than resolve. Refusing costs one un-deleted artifact; resolving wrongly costs data.
#
# This must fail CLOSED: if any subtree cannot be enumerated (ACL denial, or a path past
# MAX_PATH -- LongPathsEnabled is 0 on this machine while VS Code, being Node, writes
# beyond it) we refuse rather than assume it was clean. Refuse when you could not look,
# exactly as you refuse when you found one.
function Test-PathHasReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }

    $errors = @()
    $found  = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +errors |
              Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
              Select-Object -First 1

    if ($errors.Count -gt 0) {
        throw "Could not fully inspect $Path for junctions ($($errors.Count) unreadable item(s)); refusing to delete it."
    }

    return [bool]$found
}

function Remove-VSCodeArtifacts {
    # SupportsShouldProcess gives the project's only destructive function the idiomatic
    # -WhatIf. It also fixes a false success report: without it, running with
    # $WhatIfPreference = $true in scope made the inner Remove-Item a silent no-op while
    # this function still emitted $t, so the CLI printed "Deleted 1 artifact(s)" having
    # deleted nothing. No ConfirmImpact: raising it to High would prompt on every call
    # and hang non-interactive runs.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)]$Roots,
        [switch]$IncludeProbable
    )

    # -ceq, not -eq: PowerShell's -eq is case-insensitive, so 'Certain' would be swept as
    # though it were 'certain'. Unknown casing now falls to the safe side and is skipped.
    $targets = @($Artifacts | Where-Object { $IncludeProbable -or $_.Confidence -ceq 'certain' })

    # Validate every target before deleting any of them. This ordering exists so a bad
    # entry cannot leave a half-purged state -- it is NOT a TOCTOU defence, and should not
    # be reasoned about as one. Swapping an artifact for a junction between the two loops
    # needs write access to %APPDATA%\Code under the same user token, which already grants
    # everything the tool could be tricked into doing. No privilege boundary is crossed.
    foreach ($t in $targets) {
        if (-not (Test-PathUnderArtifactRoots -Path $t.Path -Roots $Roots)) {
            throw "Refusing to delete path outside the artifact roots: $($t.Path)"
        }
        if (Test-PathHasReparsePoint -Path $t.Path) {
            throw "Refusing to delete a tree containing a junction or symlink: $($t.Path)"
        }
    }

    # A single failure (locked file, already gone) must not abort the rest.
    foreach ($t in $targets) {
        if (-not $PSCmdlet.ShouldProcess($t.Path, 'Delete artifact')) { continue }
        try {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
            $t
        } catch {
            Write-Warning "Could not delete $($t.Path): $($_.Exception.Message)"
        }
    }
}
