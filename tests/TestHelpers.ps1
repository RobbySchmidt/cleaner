function New-FakeCodeRoot {
    param([Parameter(Mandatory = $true)][string]$Parent)

    $root = Join-Path $Parent ('Code-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    foreach ($sub in @('User\workspaceStorage', 'User\History', 'Backups', 'logs')) {
        New-Item -Path (Join-Path $root $sub) -ItemType Directory -Force | Out-Null
    }
    $root
}

function Add-FakeWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Hash,
        [string]$FolderUri,
        [string]$WorkspaceUri,
        [string]$RawJson
    )

    $dir = Join-Path $CodeRoot "User\workspaceStorage\$Hash"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'placeholder' | Out-File -FilePath (Join-Path $dir 'state.vscdb') -Encoding utf8

    $json = if ($PSBoundParameters.ContainsKey('RawJson')) { $RawJson }
            elseif ($FolderUri)    { (@{ folder    = $FolderUri }    | ConvertTo-Json) }
            else                   { (@{ workspace = $WorkspaceUri } | ConvertTo-Json) }

    $json | Out-File -FilePath (Join-Path $dir 'workspace.json') -Encoding utf8
    $dir
}

function Add-FakeHistory {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$ResourceUri
    )

    $dir = Join-Path $CodeRoot "User\History\$Hash"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'old content' | Out-File -FilePath (Join-Path $dir 'aaaa.vue') -Encoding utf8
    @{ version = 1; resource = $ResourceUri; entries = @() } |
        ConvertTo-Json | Out-File -FilePath (Join-Path $dir 'entries.json') -Encoding utf8
    $dir
}

function Add-FakeBackup {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Hash
    )

    $dir = Join-Path $CodeRoot "Backups\$Hash"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'unsaved' | Out-File -FilePath (Join-Path $dir 'file1') -Encoding utf8
    $dir
}

function Add-FakeLog {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Window,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $dir = Join-Path $CodeRoot "logs\$Session\$Window"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $Content | Out-File -FilePath (Join-Path $dir 'renderer.log') -Encoding utf8
    $dir
}

function New-FakeClaudeRoot {
    param([Parameter(Mandatory = $true)][string]$Parent)

    $root = Join-Path $Parent ('claude-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    foreach ($sub in @('projects', 'file-history', 'session-env', 'sessions')) {
        New-Item -Path (Join-Path $root $sub) -ItemType Directory -Force | Out-Null
    }
    $root
}

function Add-FakeClaudeTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][string]$DirName,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$Cwd,
        [string[]]$RawLines,
        [switch]$WithSessionFolder
    )

    $dir = Join-Path $ClaudeRoot "projects\$DirName"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null

    $lines = if ($PSBoundParameters.ContainsKey('RawLines')) { $RawLines } else {
        @(
            (@{ type = 'summary'; summary = 'no cwd on this line' } | ConvertTo-Json -Compress),
            (@{ type = 'user'; cwd = $Cwd; sessionId = $SessionId } | ConvertTo-Json -Compress)
        )
    }

    $file = Join-Path $dir "$SessionId.jsonl"
    [System.IO.File]::WriteAllLines($file, [string[]]$lines)

    if ($WithSessionFolder) {
        $sub = Join-Path $dir "$SessionId\subagents"
        New-Item -Path $sub -ItemType Directory -Force | Out-Null
        '{}' | Out-File -FilePath (Join-Path $sub 'agent-1.jsonl') -Encoding utf8
    }
    $file
}

function Add-FakeClaudeMemory {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][string]$DirName
    )

    $dir = Join-Path $ClaudeRoot "projects\$DirName"
    New-Item -Path (Join-Path $dir 'memory') -ItemType Directory -Force | Out-Null
    '- a memory' | Out-File -FilePath (Join-Path $dir 'memory\MEMORY.md') -Encoding utf8
    $dir
}

function Add-FakeClaudeSessionDir {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][ValidateSet('file-history', 'session-env')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    $dir = Join-Path $ClaudeRoot "$Kind\$SessionId"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'before edit' | Out-File -FilePath (Join-Path $dir 'x@v1') -Encoding utf8
    $dir
}

function Add-FakeClaudeLiveSession {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$Cwd,
        [string]$SessionId = 'live',
        [string]$RawJson
    )

    $json = if ($PSBoundParameters.ContainsKey('RawJson')) { $RawJson }
            else { @{ pid = $ProcessId; sessionId = $SessionId; cwd = $Cwd; status = 'busy' } | ConvertTo-Json -Compress }
    $file = Join-Path $ClaudeRoot "sessions\$ProcessId.json"
    $json | Out-File -FilePath $file -Encoding utf8
    $file
}
