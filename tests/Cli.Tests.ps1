. "$PSScriptRoot\TestHelpers.ps1"
$script:Cli = Join-Path $PSScriptRoot '..\vscode-cleanup.ps1'

Describe "vscode-cleanup.ps1" {
    It "writes a report and deletes nothing without -Delete" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        $ws   = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r1.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ReportPath $report | Out-Null

        Test-Path $report          | Should Be $true
        (Get-Content $report -Raw) | Should Match 'ws1'
        Test-Path $ws              | Should Be $true
    }

    It "deletes when -Delete is passed" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        $ws   = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r2.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ReportPath $report -Delete | Out-Null

        Test-Path $ws | Should Be $false
    }

    It "deletes nothing under -WhatIf but still writes the report" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        $ws   = Add-FakeWorkspace -CodeRoot $code -Hash 'ws1' -FolderUri 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r3.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ReportPath $report -Delete -WhatIf | Out-Null

        Test-Path $ws     | Should Be $true
        Test-Path $report | Should Be $true
    }

    It "leaves probable artifacts alone unless -IncludeProbable" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        $log  = Add-FakeLog -CodeRoot $code -Session 's1' -Window 'window1' -Content 'file:///d%3A/Nuxt/foo'
        $report = Join-Path $TestDrive 'r4.txt'

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ReportPath $report -Delete | Out-Null
        Test-Path $log | Should Be $true

        & $script:Cli -Project 'D:\Nuxt\foo' -CodeRoot $code -ReportPath $report -Delete -IncludeProbable | Out-Null
        Test-Path $log | Should Be $false
    }

    It "refuses a drive root" {
        $code = New-FakeCodeRoot -Parent $TestDrive
        { & $script:Cli -Project 'D:\' -CodeRoot $code -ReportPath (Join-Path $TestDrive 'r5.txt') } |
            Should Throw 'drive root'
    }
}
