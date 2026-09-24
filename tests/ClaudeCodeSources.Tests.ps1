. "$PSScriptRoot\..\src\VSCodeUri.ps1"
. "$PSScriptRoot\..\src\VSCodeRoots.ps1"
. "$PSScriptRoot\..\src\ClaudeCodeSources.ps1"
. "$PSScriptRoot\TestHelpers.ps1"

Describe "Get-ClaudeTranscriptOwner" {
    It "returns the first cwd in the transcript" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $file = Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'D:\Nuxt\foo'

        Get-ClaudeTranscriptOwner -Path $file | Should Be 'D:\Nuxt\foo'
    }

    It "ignores a later cwd after the session changed directory" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $file = Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -RawLines @(
            '{"type":"user","cwd":"D:\\Nuxt\\foo"}',
            '{"type":"user","cwd":"D:\\elsewhere"}'
        )

        Get-ClaudeTranscriptOwner -Path $file | Should Be 'D:\Nuxt\foo'
    }

    It "skips an unparseable line and keeps reading" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $file = Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -RawLines @(
            '{"cwd": broken',
            '{"type":"user","cwd":"D:\\Nuxt\\foo"}'
        )

        Get-ClaudeTranscriptOwner -Path $file | Should Be 'D:\Nuxt\foo'
    }

    It "returns null for a transcript with no cwd" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $file = Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -RawLines @(
            '{"type":"teleported-from","remoteSessionId":"r1","messageCount":3}'
        )

        Get-ClaudeTranscriptOwner -Path $file | Should Be $null
    }

    It "returns null for a missing file" {
        Get-ClaudeTranscriptOwner -Path (Join-Path $TestDrive 'nope.jsonl') | Should Be $null
    }

    It "reads a transcript another process holds open for writing" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $file = Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'D:\Nuxt\foo'
        $writer = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
        try {
            Get-ClaudeTranscriptOwner -Path $file | Should Be 'D:\Nuxt\foo'
        } finally {
            $writer.Dispose()
        }
    }
}

Describe "ConvertTo-ClaudeProjectDirName" {
    It "replaces every character outside A-Za-z0-9 with a dash" {
        ConvertTo-ClaudeProjectDirName -Path 'C:\Users\x\OneDrive\Desktop\Neuer Ordner' |
            Should Be 'C--Users-x-OneDrive-Desktop-Neuer-Ordner'
    }
    It "maps look-alike paths to the same name, which is why the name alone is never trusted" {
        $a = ConvertTo-ClaudeProjectDirName -Path 'D:\Nuxt\A-B'
        $b = ConvertTo-ClaudeProjectDirName -Path 'D:\Nuxt\A B'
        $c = ConvertTo-ClaudeProjectDirName -Path 'D:\Nuxt\A\B'
        $a | Should Be 'D--Nuxt-A-B'
        $b | Should Be $a
        $c | Should Be $a
    }
    It "ignores a trailing backslash" {
        ConvertTo-ClaudeProjectDirName -Path 'D:\Nuxt\foo\' | Should Be 'D--Nuxt-foo'
    }
}
