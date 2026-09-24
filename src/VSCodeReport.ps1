function Add-ArtifactSize {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)]$Artifact)

    process {
        $bytes = 0
        if (Test-Path -LiteralPath $Artifact.Path) {
            $sum = (Get-ChildItem -LiteralPath $Artifact.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            if ($sum) { $bytes = $sum }
        }

        $Artifact | Add-Member -NotePropertyName SizeBytes -NotePropertyValue ([int64]$bytes) -Force -PassThru
    }
}

function Format-ArtifactReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)][string]$Project
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Artifacts for project: $Project")
    $lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('')

    if ($Artifacts.Count -eq 0) {
        $lines.Add('No artifacts found.')
        return ($lines -join [Environment]::NewLine)
    }

    foreach ($group in ($Artifacts | Group-Object Source | Sort-Object Name)) {
        $groupTotal = ($group.Group | Measure-Object -Property SizeBytes -Sum).Sum
        $lines.Add("[$($group.Name)] $($group.Count) item(s), $groupTotal bytes")
        foreach ($a in $group.Group) {
            $lines.Add("  ($($a.Confidence)) $($a.SizeBytes) bytes  $($a.Path)")
        }
        $lines.Add('')
    }

    $total = ($Artifacts | Measure-Object -Property SizeBytes -Sum).Sum
    $lines.Add("TOTAL: $total bytes across $($Artifacts.Count) artifact(s)")

    $lines -join [Environment]::NewLine
}

function Write-ArtifactReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    # -WhatIf:$false is deliberate. $WhatIfPreference propagates into Out-File, so under
    # the CLI's -WhatIf the report would silently not be written while the CLI still
    # printed "Report: <path>" -- naming a file that does not exist. The report is the
    # output of a read, not a destructive act: previewing a deletion should still produce
    # the document you review before committing to it.
    Format-ArtifactReport -Artifacts $Artifacts -Project $Project |
        Out-File -FilePath $ReportPath -Encoding utf8 -WhatIf:$false

    $ReportPath
}
