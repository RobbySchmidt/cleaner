function Get-WorkspaceStorageArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path $Roots.WorkspaceStorage)) { return @() }

    Get-ChildItem -Path $Roots.WorkspaceStorage -Directory | ForEach-Object {
        $meta = Join-Path $_.FullName 'workspace.json'
        if (-not (Test-Path $meta)) { return }

        try {
            $json = Get-Content -LiteralPath $meta -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            Write-Warning "Skipping unreadable $meta"
            return
        }

        $uri = if ($json.folder) { $json.folder } elseif ($json.workspace) { $json.workspace } else { $null }
        if ($uri -and (Test-UriUnderProject -Uri $uri -ProjectUri $ProjectUri)) {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'workspaceStorage'
                Confidence = 'certain'
                Hash       = $_.Name
            }
        }
    }
}

function Get-HistoryArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path $Roots.History)) { return @() }

    Get-ChildItem -Path $Roots.History -Directory | ForEach-Object {
        $meta = Join-Path $_.FullName 'entries.json'
        if (-not (Test-Path $meta)) { return }

        try {
            $json = Get-Content -LiteralPath $meta -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            Write-Warning "Skipping unreadable $meta"
            return
        }

        if ($json.resource -and (Test-UriUnderProject -Uri $json.resource -ProjectUri $ProjectUri)) {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'History'
                Confidence = 'certain'
                Hash       = $_.Name
            }
        }
    }
}

function Get-BackupArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [AllowEmptyCollection()][string[]]$WorkspaceHashes = @()
    )

    if ($WorkspaceHashes.Count -eq 0)    { return @() }
    if (-not (Test-Path $Roots.Backups)) { return @() }

    Get-ChildItem -Path $Roots.Backups -Directory |
        Where-Object { $WorkspaceHashes -contains $_.Name } |
        ForEach-Object {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'Backups'
                Confidence = 'certain'
                Hash       = $_.Name
            }
        }
}

function Get-LogArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path $Roots.Logs)) { return @() }

    Get-ChildItem -Path $Roots.Logs -Directory -Recurse -Filter 'window*' | ForEach-Object {
        # NOT -SimpleMatch. A project URI is a prefix of its own siblings, so a bare
        # substring match hands back 'mastering-nuxt-3-main' and 'mastering-nuxt-3%20fixed'
        # as artifacts of 'mastering-nuxt-3' -- the exact collision Test-UriUnderProject
        # exists to prevent. The lookahead requires the next character to be one that
        # cannot continue a folder name: '/' and delimiters pass, name characters do not.
        #
        # -Recurse: a window dir also holds exthost\ and output_logging_*\ subdirectories
        # that contain file:// URIs. The whole window dir is the artifact either way.
        $pattern = [regex]::Escape($ProjectUri) + '(?![A-Za-z0-9\-._~%])'
        $hit = Get-ChildItem -Path $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
               Select-String -Pattern $pattern -List -ErrorAction SilentlyContinue

        if ($hit) {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'logs'
                Confidence = 'probable'
                Hash       = $null
            }
        }
    }
}

function Get-VSCodeProjectArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        $Roots = (Get-VSCodeRoots)
    )

    $uri = ConvertTo-VSCodeUri -Path $Project

    # A drive root is not a project. ConvertTo-VSCodeUri legitimately renders 'D:\' as
    # file:///d%3A/, which as a prefix matches every artifact on that drive -- so -Delete
    # would purge the VS Code history of every project on D: in one invocation.
    #
    # Guard the NORMALIZED URI, not the raw input. A lexical regex on $Project misses
    # 'D:\\', 'D:\.', 'D:\..' and 'D:\ ' (trailing space), all of which GetFullPath
    # collapses to exactly the same whole-drive URI. ('D:' with no separator never gets
    # here -- ConvertTo-VSCodeUri rejects it as not rooted.)
    if ($uri -match '^file:///[a-z]%3A/?$') {
        throw "A drive root is not a project: $Project"
    }

    # Characters proven against the live data: letters, digits, - . _ ~ / \ [ ] and space.
    # Anything else is encoded by a rule no live URI exercises. If VS Code happens to write
    # it differently, nothing matches, the run reports "no artifacts found", and the user
    # deletes the project believing it was clean. Warn rather than quietly guess.
    #
    # Inspect the NORMALIZED path, for the same reason the guard above does. GetFullPath
    # expands 8.3 short names when the path exists, so 'C:\Users\ROBBYS~1\My+Co' and its
    # long form produce one URI but only the long form contains the '+' -- reading $Project
    # raw would stay silent in exactly the case this warning exists for. It also stops
    # 'D:\@scratch\..\Nuxt\foo' warning about an '@' that the resolved URI never contains.
    $unverified = ([System.IO.Path]::GetFullPath($Project)).Substring(2) -replace '[A-Za-z0-9\-._~/\\\[\] ]', ''
    if ($unverified) {
        Write-Warning ("Project path contains character(s) that appear nowhere in this machine's " +
                       "VS Code data: $unverified -- their URI encoding is unverified, so artifacts " +
                       "may be missed. Review the report before using -Delete.")
    }

    $workspaces = @(Get-WorkspaceStorageArtifacts -Roots $Roots -ProjectUri $uri)

    # A parent directory is a legitimate project -- this machine has Desktop registered as
    # a VS Code workspace in its own right -- but resolving one sweeps in every project
    # nested beneath it. Measured here: 'D:\Nuxt' returns artifacts belonging to 53
    # distinct projects, 'C:\Users\...\Documents\GitHub' to 68. Deleting a parent folder
    # genuinely does mean deleting all of them, so this warns rather than refuses. The
    # artifact count alone does not convey it: "Found 343 artifact(s)" reads like a big
    # project, not like 52 separate ones.
    $owners = @($workspaces | ForEach-Object {
        try {
            $j = Get-Content -LiteralPath (Join-Path $_.Path 'workspace.json') -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($j.folder) { $j.folder } else { $j.workspace }
        } catch { }
    } | Sort-Object -Unique)
    if ($owners.Count -gt 1) {
        Write-Warning ("'$Project' is a parent of $($owners.Count) separate VS Code projects. " +
                       "These artifacts belong to all of them, not to one project. " +
                       "Review the report before using -Delete.")
    }

    $history    = @(Get-HistoryArtifacts          -Roots $Roots -ProjectUri $uri)
    $hashes     = @($workspaces | ForEach-Object { $_.Hash })
    $backups    = @(Get-BackupArtifacts           -Roots $Roots -WorkspaceHashes $hashes)
    $logs       = @(Get-LogArtifacts              -Roots $Roots -ProjectUri $uri)

    @($workspaces + $history + $backups + $logs)
}
