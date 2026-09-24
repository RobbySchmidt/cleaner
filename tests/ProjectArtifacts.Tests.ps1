. "$PSScriptRoot\..\src\VSCodeUri.ps1"
. "$PSScriptRoot\..\src\VSCodeRoots.ps1"
. "$PSScriptRoot\..\src\VSCodeSources.ps1"
. "$PSScriptRoot\..\src\ClaudeCodeSources.ps1"
. "$PSScriptRoot\..\src\ProjectArtifacts.ps1"
. "$PSScriptRoot\TestHelpers.ps1"

Describe "Get-ProjectArtifacts" {
    It "combines VS Code and Claude Code artifacts for one project" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeWorkspace        -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo' | Out-Null
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'D:\Nuxt\foo' | Out-Null
        Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 's1' | Out-Null
        Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'session-env'  -SessionId 's1' | Out-Null
        Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 'orphan' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -ClaudeRoot $claude

        $result = @(Get-ProjectArtifacts -Project 'D:\Nuxt\foo' -Roots $roots)

        $result.Count | Should Be 4
        ($result | ForEach-Object { $_.Source } | Sort-Object) -join ',' |
            Should Be 'claude:file-history,claude:projects,claude:session-env,workspaceStorage'
    }

    It "does not take session folders of a folder it only matched by name" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeMemory     -ClaudeRoot $claude -DirName 'd--Nuxt-foo' | Out-Null
        Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 's1' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -ClaudeRoot $claude

        $result = @(Get-ProjectArtifacts -Project 'D:\Nuxt\foo' -Roots $roots)

        $result.Count         | Should Be 1
        $result[0].Confidence | Should Be 'probable'
    }

    It "refuses a drive root before reading any Claude data" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'D:\Nuxt\foo' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -ClaudeRoot $claude

        { Get-ProjectArtifacts -Project 'D:\' -Roots $roots } | Should Throw 'drive root'
    }

    It "warns when the path is a parent of several Claude Code projects" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-one' -SessionId 's1' -Cwd 'D:\Nuxt\one' | Out-Null
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-two' -SessionId 's2' -Cwd 'D:\Nuxt\two' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -ClaudeRoot $claude
        $w = @()

        Get-ProjectArtifacts -Project 'D:\Nuxt' -Roots $roots -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        @($w | Where-Object { $_ -match 'parent of 2 separate Claude Code projects' }).Count | Should Be 1
    }

    It "does not warn when several transcripts belong to one project" {
        $code   = New-FakeCodeRoot   -Parent $TestDrive
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-one' -SessionId 's1' -Cwd 'D:\Nuxt\one' | Out-Null
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-one' -SessionId 's2' -Cwd 'd:\nuxt\ONE' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -ClaudeRoot $claude
        $w = @()

        Get-ProjectArtifacts -Project 'D:\Nuxt\one' -Roots $roots -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        @($w | Where-Object { $_ -match 'parent of' }).Count | Should Be 0
    }
}
