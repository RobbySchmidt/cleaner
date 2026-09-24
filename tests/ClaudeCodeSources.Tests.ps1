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

Describe "Get-ClaudeProjectArtifacts" {
    $uri  = ConvertTo-VSCodeUri -Path 'D:\Nuxt\foo'
    $name = ConvertTo-ClaudeProjectDirName -Path 'D:\Nuxt\foo'

    It "returns the whole folder when every transcript belongs to the project" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'D:\Nuxt\foo' -WithSessionFolder | Out-Null
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's2' -Cwd 'd:\Nuxt\foo' | Out-Null
        $dir   = Add-FakeClaudeMemory -ClaudeRoot $claude -DirName 'd--Nuxt-foo'
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        $result = @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $uri -ProjectDirName $name)

        $result.Count         | Should Be 1
        $result[0].Path       | Should Be $dir
        $result[0].Source     | Should Be 'claude:projects'
        $result[0].Confidence | Should Be 'certain'
        (@($result[0].SessionIds) | Sort-Object) -join ',' | Should Be 's1,s2'
        @($result[0].Owners).Count | Should Be 1
    }

    It "matches a transcript launched in a subfolder of the project" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo-sub' -SessionId 's1' -Cwd 'D:\Nuxt\foo\sub' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        $result = @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $uri -ProjectDirName $name)

        $result.Count         | Should Be 1
        $result[0].Confidence | Should Be 'certain'
    }

    It "does not match a sibling whose name starts with the project name" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo-main' -SessionId 's1' -Cwd 'D:\Nuxt\foo-main' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $uri -ProjectDirName $name).Count | Should Be 0
    }

    It "splits a folder shared by look-alike projects and leaves the shared parts" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $mine   = Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-A-B' -SessionId 'mine'   -Cwd 'D:\Nuxt\A-B' -WithSessionFolder
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-A-B' -SessionId 'theirs' -Cwd 'D:\Nuxt\A B' | Out-Null
        $dir    = Add-FakeClaudeMemory -ClaudeRoot $claude -DirName 'd--Nuxt-A-B'
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude
        $abUri  = ConvertTo-VSCodeUri -Path 'D:\Nuxt\A-B'
        $abName = ConvertTo-ClaudeProjectDirName -Path 'D:\Nuxt\A-B'

        $result = @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $abUri -ProjectDirName $abName)
        $paths  = @($result | ForEach-Object { $_.Path })

        $result.Count | Should Be 2
        ($paths -contains $mine)                     | Should Be $true
        ($paths -contains (Join-Path $dir 'mine'))   | Should Be $true
        ($paths -contains $dir)                      | Should Be $false
        ($paths -contains (Join-Path $dir 'memory')) | Should Be $false
        @($result | Where-Object { $_.Confidence -ne 'certain' }).Count | Should Be 0
        (@($result | ForEach-Object { $_.SessionIds }) -join ',') | Should Be 'mine'
    }

    It "treats an ownerless stub as neutral, not as another project" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'D:\Nuxt\foo' | Out-Null
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 'stub' -RawLines @(
            '{"type":"teleported-from","remoteSessionId":"r1","messageCount":3}'
        ) | Out-Null
        $dir   = Add-FakeClaudeMemory -ClaudeRoot $claude -DirName 'd--Nuxt-foo'
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        $result = @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $uri -ProjectDirName $name)

        $result.Count         | Should Be 1
        $result[0].Path       | Should Be $dir
        $result[0].Confidence | Should Be 'certain'
        (@($result[0].SessionIds) -join ',') | Should Be 's1'
    }

    It "returns a memory-only folder as probable when its name matches" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $dir    = Add-FakeClaudeMemory -ClaudeRoot $claude -DirName 'd--Nuxt-foo'
        Add-FakeClaudeMemory -ClaudeRoot $claude -DirName 'd--Nuxt-other' | Out-Null
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        $result = @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $uri -ProjectDirName $name)

        $result.Count         | Should Be 1
        $result[0].Path       | Should Be $dir
        $result[0].Confidence | Should Be 'probable'
        @($result[0].SessionIds).Count | Should Be 0
    }

    It "treats a cwd that is not a drive path as another project" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 'mine' -Cwd 'D:\Nuxt\foo' | Out-Null
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 'unc'  -Cwd '\\server\share\foo' | Out-Null
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 'wsl'  -Cwd '/home/me/foo' | Out-Null
        $dir   = Add-FakeClaudeMemory -ClaudeRoot $claude -DirName 'd--Nuxt-foo'
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        $result = @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $uri -ProjectDirName $name)
        $paths  = @($result | ForEach-Object { $_.Path })

        $result.Count          | Should Be 1
        ($paths -contains $dir) | Should Be $false
    }

    It "matches regardless of case and a trailing backslash on the project path" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeTranscript -ClaudeRoot $claude -DirName 'd--Nuxt-foo' -SessionId 's1' -Cwd 'd:\nuxt\FOO' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude
        $u = ConvertTo-VSCodeUri -Path 'D:\Nuxt\foo\'
        $n = ConvertTo-ClaudeProjectDirName -Path 'D:\Nuxt\foo\'

        @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $u -ProjectDirName $n).Count | Should Be 1
    }

    It "returns nothing when the projects root is missing" {
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot (Join-Path $TestDrive 'noclaude')
        @(Get-ClaudeProjectArtifacts -Roots $roots -ProjectUri $uri -ProjectDirName $name).Count | Should Be 0
    }
}
