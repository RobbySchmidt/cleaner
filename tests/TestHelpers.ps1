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
