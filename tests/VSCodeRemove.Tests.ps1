. "$PSScriptRoot\..\src\VSCodeRoots.ps1"
. "$PSScriptRoot\..\src\VSCodeRemove.ps1"
. "$PSScriptRoot\TestHelpers.ps1"

Describe "Remove-VSCodeArtifacts" {
    It "deletes certain artifacts and leaves probable ones alone" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws    = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $log   = Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window1' -Content 'x'

        $artifacts = @(
            [pscustomobject]@{ Path = $ws;  Source = 'workspaceStorage'; Confidence = 'certain';  Hash = 'ws1' },
            [pscustomobject]@{ Path = $log; Source = 'logs';             Confidence = 'probable'; Hash = $null }
        )

        $removed = @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots)

        $removed.Count | Should Be 1
        Test-Path $ws  | Should Be $false
        Test-Path $log | Should Be $true
    }

    It "deletes probable artifacts when IncludeProbable is passed" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $log   = Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window1' -Content 'x'

        $artifacts = @([pscustomobject]@{ Path = $log; Source = 'logs'; Confidence = 'probable'; Hash = $null })

        @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots -IncludeProbable).Count | Should Be 1
        Test-Path $log | Should Be $false
    }

    It "throws and deletes nothing when a path is outside the roots" {
        $code    = New-FakeCodeRoot -Parent $TestDrive
        $roots   = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws      = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $outside = Join-Path $TestDrive 'not-vscode'
        New-Item -Path $outside -ItemType Directory -Force | Out-Null

        $artifacts = @(
            [pscustomobject]@{ Path = $ws;      Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'ws1' },
            [pscustomobject]@{ Path = $outside; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'bad' }
        )

        { Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots } | Should Throw
        Test-Path $ws      | Should Be $true
        Test-Path $outside | Should Be $true
    }

    It "refuses to delete a tree containing a junction" {
        $code    = New-FakeCodeRoot -Parent $TestDrive
        $roots   = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws      = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $outside = Join-Path $TestDrive 'outside-the-roots'
        New-Item -Path $outside -ItemType Directory -Force | Out-Null
        'precious' | Out-File -FilePath (Join-Path $outside 'keep.txt') -Encoding utf8
        cmd /c mklink /J "$ws\link" "$outside" | Out-Null

        $artifacts = @([pscustomobject]@{ Path = $ws; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'ws1' })

        { Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots } | Should Throw 'junction or symlink'
        Test-Path (Join-Path $outside 'keep.txt') | Should Be $true
    }

    It "keeps going when one artifact cannot be deleted" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws    = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $gone  = Join-Path $code 'User\History\never-existed'

        $artifacts = @(
            [pscustomobject]@{ Path = $gone; Source = 'History';          Confidence = 'certain'; Hash = 'gone' },
            [pscustomobject]@{ Path = $ws;   Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'ws1'  }
        )

        $removed = @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots -WarningAction SilentlyContinue)

        $removed.Count | Should Be 1
        Test-Path $ws  | Should Be $false
    }

    It "refuses when the artifact path is itself a junction" {
        $code    = New-FakeCodeRoot -Parent $TestDrive
        $roots   = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $outside = Join-Path $TestDrive 'outside-top'
        New-Item -Path $outside -ItemType Directory -Force | Out-Null
        'precious' | Out-File -FilePath (Join-Path $outside 'keep.txt') -Encoding utf8
        $link = Join-Path $code 'User\workspaceStorage\linkws'
        cmd /c mklink /J "$link" "$outside" | Out-Null

        $artifacts = @([pscustomobject]@{ Path = $link; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'linkws' })

        { Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots } | Should Throw 'junction or symlink'
        Test-Path (Join-Path $outside 'keep.txt') | Should Be $true
    }

    It "refuses a hidden junction" {
        $code    = New-FakeCodeRoot -Parent $TestDrive
        $roots   = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws      = Add-FakeWorkspace -CodeRoot $code -Hash 'wsh' -FolderUri 'file:///d%3A/Nuxt/foo'
        $outside = Join-Path $TestDrive 'outside-hidden'
        New-Item -Path $outside -ItemType Directory -Force | Out-Null
        cmd /c mklink /J "$ws\hlink" "$outside" | Out-Null
        (Get-Item -LiteralPath "$ws\hlink" -Force).Attributes = 'Directory, Hidden, ReparsePoint'

        $artifacts = @([pscustomobject]@{ Path = $ws; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'wsh' })

        { Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots } | Should Throw 'junction or symlink'
    }

    It "refuses a junction nested below the top level" {
        $code    = New-FakeCodeRoot -Parent $TestDrive
        $roots   = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws      = Add-FakeWorkspace -CodeRoot $code -Hash 'wsd' -FolderUri 'file:///d%3A/Nuxt/foo'
        $deep    = Join-Path $ws 'a\b\c'
        New-Item -Path $deep -ItemType Directory -Force | Out-Null
        $outside = Join-Path $TestDrive 'outside-deep'
        New-Item -Path $outside -ItemType Directory -Force | Out-Null
        cmd /c mklink /J "$deep\dlink" "$outside" | Out-Null

        $artifacts = @([pscustomobject]@{ Path = $ws; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'wsd' })

        { Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots } | Should Throw 'junction or symlink'
    }

    It "deletes a tree containing a read-only file" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws    = Add-FakeWorkspace -CodeRoot $code -Hash 'wsro' -FolderUri 'file:///d%3A/Nuxt/foo'
        $ro    = Join-Path $ws 'readonly.txt'
        'locked' | Out-File -FilePath $ro -Encoding utf8
        (Get-Item -LiteralPath $ro).IsReadOnly = $true

        $artifacts = @([pscustomobject]@{ Path = $ws; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'wsro' })

        @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots).Count | Should Be 1
        Test-Path $ws | Should Be $false
    }

    It "refuses when a subtree cannot be inspected for junctions" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws    = Add-FakeWorkspace -CodeRoot $code -Hash 'wsacl' -FolderUri 'file:///d%3A/Nuxt/foo'
        $deny  = Join-Path $ws 'zzz-locked'
        New-Item -Path $deny -ItemType Directory -Force | Out-Null
        'x' | Out-File -FilePath (Join-Path $deny 'inner.txt') -Encoding utf8
        $me = "$env:USERDOMAIN\$env:USERNAME"

        try {
            cmd /c icacls "$deny" /deny "${me}:(OI)(CI)(RX)" | Out-Null

            $artifacts = @([pscustomobject]@{ Path = $ws; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'wsacl' })

            { Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots } | Should Throw 'Could not fully inspect'
        } finally {
            # Must reset before Pester tears down $TestDrive, or cleanup fails.
            cmd /c icacls "$deny" /remove:d "$me" | Out-Null
        }
    }

    It "deletes nothing and reports nothing under -WhatIf" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws    = Add-FakeWorkspace -CodeRoot $code -Hash 'wswi' -FolderUri 'file:///d%3A/Nuxt/foo'

        $artifacts = @([pscustomobject]@{ Path = $ws; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'wswi' })

        @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots -WhatIf).Count | Should Be 0
        Test-Path $ws | Should Be $true
    }

    It "skips a confidence value that differs only in case" {
        $code  = New-FakeCodeRoot -Parent $TestDrive
        $roots = Get-VSCodeRoots -CodeRoot $code -UserProfile $TestDrive
        $ws    = Add-FakeWorkspace -CodeRoot $code -Hash 'wscase' -FolderUri 'file:///d%3A/Nuxt/foo'

        $artifacts = @([pscustomobject]@{ Path = $ws; Source = 'workspaceStorage'; Confidence = 'Certain'; Hash = 'wscase' })

        @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots).Count | Should Be 0
        Test-Path $ws | Should Be $true
    }
}
