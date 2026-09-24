. "$PSScriptRoot\TestHelpers.ps1"
$script:Cli = Join-Path $PSScriptRoot '..\vscode-cleanup.ps1'

Describe "vscode-cleanup.ps1" {
    It "writes a report and deletes nothing without -Delete" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $ws     = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r1.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $claude -ReportPath $report | Out-Null

        Test-Path $report          | Should Be $true
        (Get-Content $report -Raw) | Should Match 'ws1'
        Test-Path $ws              | Should Be $true
    }

    It "deletes when -Delete is passed" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $ws     = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r2.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $claude -ReportPath $report -Delete | Out-Null

        Test-Path $ws | Should Be $false
    }

    It "deletes nothing under -WhatIf but still writes the report" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $ws     = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r3.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $claude -ReportPath $report -Delete -WhatIf | Out-Null

        Test-Path $ws     | Should Be $true
        Test-Path $report | Should Be $true
    }

    It "leaves probable artifacts alone unless -IncludeProbable" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $log    = Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window1' -Content 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r4.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $claude -ReportPath $report -Delete | Out-Null
        Test-Path $log | Should Be $true

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $claude -ReportPath $report -Delete -IncludeProbable | Out-Null
        Test-Path $log | Should Be $false
    }

    It "refuses a drive root" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        { & $script:Cli -Project 'D:\' -CodeRoot $code -ClaudeRoot $claude -ReportPath (Join-Path $TestDrive 'r5.txt') } |
            Should Throw 'drive root'
    }
}

# Top level, not inside Describe: keeps it visible to every It block regardless of how
# Pester 3.4 scopes them. $TestDrive is resolved when it is called, inside an It.
function New-ClaudeFixture {
    $claude = New-FakeClaudeRoot -Parent $TestDrive
    Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'D:\Nuxt\foo' -WithSessionFolder | Out-Null
    $settings = Join-Path $claude 'settings.json'
    '{}' | Out-File -FilePath $settings -Encoding utf8
    [pscustomobject]@{
        Root     = $claude
        Project  = Join-Path $claude 'projects\d--Nuxt-foo'
        History  = Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 's1'
        Env      = Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'session-env'  -SessionId 's1'
        Orphan   = Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 'orphan'
        Settings = $settings
    }
}

Describe "vscode-cleanup.ps1 (Claude Code)" {
    It "reports the Claude Code artifacts" {
        $code   = New-FakeCodeRoot -Parent $TestDrive
        $f      = New-ClaudeFixture
        $report = Join-Path $TestDrive 'c1.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $f.Root -ReportPath $report | Out-Null

        $text = Get-Content $report -Raw
        $text | Should Match '\[claude:projects\]'
        $text | Should Match '\[claude:file-history\]'
        $text | Should Match '\[claude:session-env\]'
        Test-Path $f.Project | Should Be $true
    }

    It "deletes the project's Claude Code data and nothing else under ~\.claude" {
        $code   = New-FakeCodeRoot -Parent $TestDrive
        $f      = New-ClaudeFixture
        $report = Join-Path $TestDrive 'c2.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $f.Root -ReportPath $report -Delete | Out-Null

        Test-Path $f.Project  | Should Be $false
        Test-Path $f.History  | Should Be $false
        Test-Path $f.Env      | Should Be $false
        Test-Path $f.Orphan   | Should Be $true
        Test-Path $f.Settings | Should Be $true
    }

    It "deletes no Claude Code data under -WhatIf" {
        $code   = New-FakeCodeRoot -Parent $TestDrive
        $f      = New-ClaudeFixture
        $report = Join-Path $TestDrive 'c3.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $f.Root -ReportPath $report -Delete -WhatIf | Out-Null

        Test-Path $f.Project | Should Be $true
        Test-Path $f.History | Should Be $true
        Test-Path $f.Env     | Should Be $true
    }

    It "warns when Claude Code is running in the project" {
        $code   = New-FakeCodeRoot -Parent $TestDrive
        $f      = New-ClaudeFixture
        Add-FakeClaudeLiveSession -ClaudeRoot $f.Root -ProcessId $PID -Cwd 'D:\Nuxt\foo' -SessionId 's1' | Out-Null
        $report = Join-Path $TestDrive 'c4.txt'
        $w = @()

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot $f.Root -ReportPath $report -Delete -WhatIf -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        @($w | Where-Object { $_ -match 'Claude Code is running' }).Count | Should Be 1
    }

    It "works when there is no ~\.claude at all" {
        $code   = New-FakeCodeRoot -Parent $TestDrive
        $ws     = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'c5.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ClaudeRoot (Join-Path $TestDrive 'no-claude-here') -ReportPath $report -Delete | Out-Null

        Test-Path $ws | Should Be $false
    }
}
