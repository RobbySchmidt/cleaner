. "$PSScriptRoot\..\src\VSCodeUri.ps1"
. "$PSScriptRoot\..\src\VSCodeRoots.ps1"
. "$PSScriptRoot\..\src\VSCodeSources.ps1"
. "$PSScriptRoot\TestHelpers.ps1"

Describe "Get-WorkspaceStorageArtifacts" {
    It "finds the folder that matches the project" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeWorkspace -CodeRoot $code -Hash 'match' -FolderUri 'file:///d%3A/Nuxt/foo'    | Out-Null
        Add-FakeWorkspace -CodeRoot $code -Hash 'other' -FolderUri 'file:///d%3A/Nuxt/foobar' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        $result = @(Get-WorkspaceStorageArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo')

        $result.Count         | Should Be 1
        $result[0].Hash       | Should Be 'match'
        $result[0].Source     | Should Be 'workspaceStorage'
        $result[0].Confidence | Should Be 'certain'
    }

    It "also matches a .code-workspace entry" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeWorkspace -CodeRoot $code -Hash 'wsfile' -WorkspaceUri 'file:///d%3A/Nuxt/foo/my.code-workspace' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        @(Get-WorkspaceStorageArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo').Count | Should Be 1
    }

    It "skips malformed json without throwing" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeWorkspace -CodeRoot $code -Hash 'broken' -RawJson '{ not json' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        @(Get-WorkspaceStorageArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo' -WarningAction SilentlyContinue).Count | Should Be 0
    }

    It "returns nothing when the root is missing" {
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nope') -UserProfile $TestDrive
        @(Get-WorkspaceStorageArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo').Count | Should Be 0
    }
}

Describe "Get-HistoryArtifacts" {
    It "matches history entries for files inside the project" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeHistory -CodeRoot $code -Hash 'h1' -ResourceUri 'file:///d%3A/Nuxt/foo/components/A.vue' | Out-Null
        Add-FakeHistory -CodeRoot $code -Hash 'h2' -ResourceUri 'file:///d%3A/Nuxt/foo/pages/B.vue'      | Out-Null
        Add-FakeHistory -CodeRoot $code -Hash 'h3' -ResourceUri 'file:///d%3A/Nuxt/foobar/C.vue'         | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        $result = @(Get-HistoryArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo')

        $result.Count | Should Be 2
        ($result | ForEach-Object { $_.Hash } | Sort-Object) -join ',' | Should Be 'h1,h2'
        $result[0].Source     | Should Be 'History'
        $result[0].Confidence | Should Be 'certain'
    }

    It "returns nothing when the root is missing" {
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nope') -UserProfile $TestDrive
        @(Get-HistoryArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo').Count | Should Be 0
    }
}

Describe "Get-BackupArtifacts" {
    It "matches backups whose hash matches a workspace hit" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeBackup -CodeRoot $code -Hash 'match' | Out-Null
        Add-FakeBackup -CodeRoot $code -Hash 'other' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        $result = @(Get-BackupArtifacts -Roots $roots -WorkspaceHashes @('match'))

        $result.Count         | Should Be 1
        $result[0].Hash       | Should Be 'match'
        $result[0].Source     | Should Be 'Backups'
        $result[0].Confidence | Should Be 'certain'
    }

    It "returns nothing when no workspace hashes were found" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeBackup -CodeRoot $code -Hash 'match' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        @(Get-BackupArtifacts -Roots $roots -WorkspaceHashes @()).Count | Should Be 0
    }
}

Describe "Get-LogArtifacts" {
    It "does not match a sibling project mentioned in a log" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window1' -Content 'opened file:///d%3A/Nuxt/foobar ok'    | Out-Null
        Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window2' -Content 'opened file:///d%3A/Nuxt/foo%20alt ok' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        @(Get-LogArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo').Count | Should Be 0
    }

    It "matches a file inside the project mentioned in a log" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window1' -Content 'opened file:///d%3A/Nuxt/foo/pages/index.vue ok' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        @(Get-LogArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo').Count | Should Be 1
    }

    It "matches window log folders that mention the project uri" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeLog -CodeRoot $code -Session '20260921T072258' -Window 'window1' -Content 'opened file:///d%3A/Nuxt/foo ok' | Out-Null
        Add-FakeLog -CodeRoot $code -Session '20260921T072258' -Window 'window2' -Content 'nothing interesting here'        | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        $result = @(Get-LogArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo')

        $result.Count         | Should Be 1
        $result[0].Source     | Should Be 'logs'
        $result[0].Confidence | Should Be 'probable'
        $result[0].Hash       | Should Be $null
        $result[0].Path       | Should Match 'window1'
    }

    It "matches a mention in a nested log file" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window1' -Content 'nothing here' | Out-Null
        $nested = Join-Path $code 'logs\s1\window1\exthost'
        New-Item -Path $nested -ItemType Directory -Force | Out-Null
        'opened file:///d%3A/Nuxt/foo ok' | Out-File -FilePath (Join-Path $nested 'exthost.log') -Encoding utf8
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        @(Get-LogArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo').Count | Should Be 1
    }

    It "returns nothing when the root is missing" {
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nope') -UserProfile $TestDrive
        @(Get-LogArtifacts -Roots $roots -ProjectUri 'file:///d%3A/Nuxt/foo').Count | Should Be 0
    }
}

Describe "Get-VSCodeProjectArtifacts" {
    It "combines all four sources for one project" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'         | Out-Null
        Add-FakeHistory   -CodeRoot $code -Hash 'h1'  -ResourceUri 'file:///d%3A/Nuxt/foo/A.vue' | Out-Null
        Add-FakeBackup    -CodeRoot $code -Hash 'ws1'                                            | Out-Null
        Add-FakeLog       -CodeRoot $code -Session 's1' -Window 'window1' -Content 'file:///d%3A/Nuxt/foo' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        $result = @(Get-VSCodeProjectArtifacts -Project 'D:\Nuxt\foo' -Roots $roots)

        $result.Count | Should Be 4
        ($result | ForEach-Object { $_.Source } | Sort-Object -Unique) -join ',' |
            Should Be 'Backups,History,logs,workspaceStorage'
    }

    It "returns nothing for an unknown project" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        @(Get-VSCodeProjectArtifacts -Project 'D:\Nuxt\nothing' -Roots $roots).Count | Should Be 0
    }

    It "does not warn about characters that normalization removes" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $w = @()

        Get-VSCodeProjectArtifacts -Project 'D:\@scratch\..\Nuxt\foo' -Roots $roots -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        $w.Count | Should Be 0
    }

    It "warns when the project path contains a character the live data never exercises" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $w = @()

        Get-VSCodeProjectArtifacts -Project 'D:\App (alt)' -Roots $roots -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        $w.Count | Should BeGreaterThan 0
    }

    It "refuses every path that normalizes to a drive root" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive

        foreach ($p in @('D:\', 'D:/', 'd:\', 'D:\\', 'D:\.', 'D:\..', 'D:\ ')) {
            { Get-VSCodeProjectArtifacts -Project $p -Roots $roots } | Should Throw 'drive root'
        }
    }

    It "does not warn for an ordinary project path" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $w = @()

        Get-VSCodeProjectArtifacts -Project 'D:\Nuxt\mastering-nuxt-3 - Kopie' -Roots $roots -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        $w.Count | Should Be 0
    }

    It "warns when the project path is a parent of several projects" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeWorkspace -CodeRoot $code -Hash 'p1' -FolderUri 'file:///d%3A/Nuxt/one' | Out-Null
        Add-FakeWorkspace -CodeRoot $code -Hash 'p2' -FolderUri 'file:///d%3A/Nuxt/two' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $w = @()

        Get-VSCodeProjectArtifacts -Project 'D:\Nuxt' -Roots $roots -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        @($w | Where-Object { $_ -match 'parent of 2 separate' }).Count | Should Be 1
    }

    It "does not warn when several artifacts belong to one project" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeWorkspace -CodeRoot $code -Hash 'q1' -FolderUri 'file:///d%3A/Nuxt/one' | Out-Null
        Add-FakeWorkspace -CodeRoot $code -Hash 'q2' -FolderUri 'file:///d%3A/Nuxt/one' | Out-Null
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $w = @()

        Get-VSCodeProjectArtifacts -Project 'D:\Nuxt\one' -Roots $roots -WarningVariable w -WarningAction SilentlyContinue | Out-Null

        @($w | Where-Object { $_ -match 'parent of' }).Count | Should Be 0
    }
}
