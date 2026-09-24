<#
.SYNOPSIS
    The launch directory a Claude Code transcript was filed under: the first "cwd" in it.

.DESCRIPTION
    Later lines can carry a different cwd after the session cd's elsewhere; Claude Code
    files the transcript by the launch directory, so only the first one counts.

    Reads line by line and stops at the first hit -- transcripts reach ~1 MB. Only lines
    that contain "cwd" are parsed, and an unparseable line is skipped, not fatal.

    Opened with FileShare ReadWrite|Delete because a running Claude Code session holds its
    transcript open for writing. A plain StreamReader(path) would fail on exactly the
    transcript the user is most likely to be cleaning, and the failure would read as
    "ownerless" -- which can let a folder through as `probable` instead of `certain`.
#>
function Get-ClaudeTranscriptOwner {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $reader = $null
    try {
        $share  = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $reader = [System.IO.StreamReader]::new($stream)

        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.IndexOf('"cwd"') -lt 0) { continue }
            try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($obj.cwd) { return [string]$obj.cwd }
        }
        return $null
    } catch {
        return $null
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}

# Claude Code names ~\.claude\projects\<dir> after the launch directory with every
# character outside A-Za-z0-9 replaced by '-'. Lossy: 'A-B', 'A B' and 'A\B' collide.
# Used ONLY for the `probable` fallback on folders that have no transcript left to read.
function ConvertTo-ClaudeProjectDirName {
    param([Parameter(Mandatory = $true)][string]$Path)

    ([System.IO.Path]::GetFullPath($Path).TrimEnd('\')) -replace '[^A-Za-z0-9]', '-'
}

# owned     -- the transcript's launch directory is the project or inside it
# foreign   -- it has a launch directory, and it is somewhere else
# ownerless -- no cwd at all (e.g. a one-line "teleported-from" stub); counts for nobody
#
# A cwd that ConvertTo-VSCodeUri rejects (UNC, WSL '/home/...', relative) is a real owner
# that cannot be under a drive-path project, so it is foreign -- never ownerless, because
# ownerless would let its folder be taken whole.
function Get-ClaudeTranscriptClass {
    param(
        [AllowNull()][AllowEmptyString()][string]$Owner,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not $Owner) { return 'ownerless' }
    try { $ownerUri = ConvertTo-VSCodeUri -Path $Owner } catch { return 'foreign' }
    if (Test-UriUnderProject -Uri $ownerUri -ProjectUri $ProjectUri) { 'owned' } else { 'foreign' }
}

<#
.SYNOPSIS
    ~\.claude\projects folders (or parts of them) that belong to a project.

.DESCRIPTION
    The folder name is lossy ('A-B', 'A B' and 'A\B' share one), so ownership comes from
    each transcript's recorded cwd, via the same Test-UriUnderProject boundary rule the
    VS Code scanners use. Per folder:

      owned, no foreign     -> whole folder, certain (memory\, <sid>\ and stubs included)
      owned and foreign     -> each owned <sid>.jsonl and its <sid>\ folder, certain;
                               memory\, stubs and the folder stay -- they are shared
      neither               -> whole folder, probable, only if its name equals the
                               project's encoded name (memory-only folders)
      only foreign          -> nothing
#>
function Get-ClaudeProjectArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri,
        [Parameter(Mandatory = $true)][string]$ProjectDirName
    )

    if (-not (Test-Path -LiteralPath $Roots.ClaudeProjects)) { return @() }

    Get-ChildItem -LiteralPath $Roots.ClaudeProjects -Directory | ForEach-Object {
        $dir     = $_
        $owned   = @()
        $foreign = 0

        foreach ($t in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File)) {
            $owner = Get-ClaudeTranscriptOwner -Path $t.FullName
            switch (Get-ClaudeTranscriptClass -Owner $owner -ProjectUri $ProjectUri) {
                'owned'   { $owned += [pscustomobject]@{ File = $t.FullName; SessionId = $t.BaseName; Owner = $owner } }
                'foreign' { $foreign++ }
            }
        }

        if ($owned.Count -gt 0 -and $foreign -eq 0) {
            [pscustomobject]@{
                Path       = $dir.FullName
                Source     = 'claude:projects'
                Confidence = 'certain'
                Hash       = $dir.Name
                SessionIds = @($owned | ForEach-Object { $_.SessionId })
                Owners     = @($owned | ForEach-Object { $_.Owner } | Sort-Object -Unique)
            }
        } elseif ($owned.Count -gt 0) {
            foreach ($o in $owned) {
                [pscustomobject]@{
                    Path       = $o.File
                    Source     = 'claude:projects'
                    Confidence = 'certain'
                    Hash       = $o.SessionId
                    SessionIds = @($o.SessionId)
                    Owners     = @($o.Owner)
                }
                $sub = Join-Path $dir.FullName $o.SessionId
                if (Test-Path -LiteralPath $sub -PathType Container) {
                    # The session ID is carried once, on the transcript artifact above.
                    [pscustomobject]@{
                        Path       = $sub
                        Source     = 'claude:projects'
                        Confidence = 'certain'
                        Hash       = $o.SessionId
                        SessionIds = @()
                        Owners     = @($o.Owner)
                    }
                }
            }
        } elseif ($foreign -eq 0 -and $dir.Name -ieq $ProjectDirName) {
            [pscustomobject]@{
                Path       = $dir.FullName
                Source     = 'claude:projects'
                Confidence = 'probable'
                Hash       = $dir.Name
                SessionIds = @()
                Owners     = @()
            }
        }
    }
}

# Session IDs come from transcript file names, which anything can create. Only a plain
# ID is joined onto a root: '..' would otherwise resolve to ~\.claude itself, which the
# allowlist refuses -- and that refusal aborts the whole deletion, not just this item.
function Get-ClaudeSessionArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [AllowEmptyCollection()][string[]]$SessionIds = @()
    )

    $kinds = @(
        @{ Root = $Roots.ClaudeFileHistory; Source = 'claude:file-history' },
        @{ Root = $Roots.ClaudeSessionEnv;  Source = 'claude:session-env'  }
    )

    foreach ($kind in $kinds) {
        if (-not (Test-Path -LiteralPath $kind.Root)) { continue }

        foreach ($id in ($SessionIds | Sort-Object -Unique)) {
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { continue }

            $dir = Join-Path $kind.Root $id
            if (Test-Path -LiteralPath $dir -PathType Container) {
                [pscustomobject]@{
                    Path       = $dir
                    Source     = $kind.Source
                    Confidence = 'certain'
                    Hash       = $id
                    SessionIds = @()
                    Owners     = @()
                }
            }
        }
    }
}

# ~\.claude\sessions\<pid>.json exists while a session runs and is removed when it exits.
# The pid check covers a crash that left the file behind. Advisory only: the CLI warns,
# it never refuses, so a reused pid costs a spurious warning and nothing else.
function Get-ClaudeRunningSessions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path -LiteralPath $Roots.ClaudeSessions)) { return @() }

    Get-ChildItem -LiteralPath $Roots.ClaudeSessions -Filter '*.json' -File | ForEach-Object {
        $file = $_.FullName
        try {
            $j = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Skipping unreadable $file"
            return
        }

        if (-not $j.cwd -or -not $j.pid) { return }
        if ((Get-ClaudeTranscriptClass -Owner $j.cwd -ProjectUri $ProjectUri) -ne 'owned') { return }
        if (-not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) { return }

        [pscustomobject]@{
            ProcessId = [int]$j.pid
            SessionId = [string]$j.sessionId
            Cwd       = [string]$j.cwd
        }
    }
}
