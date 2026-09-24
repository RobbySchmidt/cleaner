function Compare-DiscoveryToResolver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$WrittenPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts
    )

    $cmp      = [System.StringComparison]::OrdinalIgnoreCase
    $covered  = New-Object System.Collections.Generic.List[string]
    $gaps     = New-Object System.Collections.Generic.List[string]
    $hitPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $WrittenPaths) {
        $owner = $null
        foreach ($a in $Artifacts) {
            $root = $a.Path.TrimEnd('\')
            if ($p.Equals($root, $cmp) -or $p.StartsWith($root + '\', $cmp)) { $owner = $a.Path; break }
        }

        if ($owner) {
            $covered.Add($p)
            $null = $hitPaths.Add($owner)
        } else {
            $gaps.Add($p)
        }
    }

    $stale = @($Artifacts | Where-Object { -not $hitPaths.Contains($_.Path) } | ForEach-Object { $_.Path })

    [pscustomobject]@{
        Covered = $covered.ToArray()
        Gaps    = $gaps.ToArray()
        Stale   = $stale
    }
}
