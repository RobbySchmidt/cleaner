<#
.SYNOPSIS
    Everything VS Code and Claude Code wrote outside a project folder on its behalf.
#>
function Get-ProjectArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        $Roots = (Get-VSCodeRoots)
    )

    # First, so its drive-root guard throws before anything under ~\.claude is read.
    $vscode = @(Get-VSCodeProjectArtifacts -Project $Project -Roots $Roots)

    $uri      = ConvertTo-VSCodeUri -Path $Project
    $dirName  = ConvertTo-ClaudeProjectDirName -Path $Project
    $projects = @(Get-ClaudeProjectArtifacts -Roots $Roots -ProjectUri $uri -ProjectDirName $dirName)

    # Same hazard as the VS Code parent warning: "Found 40 artifact(s)" reads like one big
    # project, not like several separate ones. Warn, don't refuse -- deleting a parent
    # folder does mean deleting everything under it.
    $owners = @($projects | ForEach-Object { $_.Owners } | Where-Object { $_ } |
                ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
    if ($owners.Count -gt 1) {
        Write-Warning ("'$Project' is a parent of $($owners.Count) separate Claude Code projects. " +
                       "These artifacts belong to all of them, not to one project. " +
                       "Review the report before using -Delete.")
    }

    $ids      = @($projects | ForEach-Object { $_.SessionIds } | Where-Object { $_ })
    $sessions = @(Get-ClaudeSessionArtifacts -Roots $Roots -SessionIds $ids)

    @($vscode + $projects + $sessions)
}
