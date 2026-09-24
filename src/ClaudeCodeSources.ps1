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
