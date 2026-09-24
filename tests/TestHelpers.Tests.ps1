. "$PSScriptRoot\TestHelpers.ps1"

Describe "New-FakeCodeRoot" {
    It "creates the four root directories" {
        $root = New-FakeCodeRoot -Parent $TestDrive
        Test-Path (Join-Path $root 'User\workspaceStorage') | Should Be $true
        Test-Path (Join-Path $root 'User\History')          | Should Be $true
        Test-Path (Join-Path $root 'Backups')               | Should Be $true
        Test-Path (Join-Path $root 'logs')                  | Should Be $true
    }
}

Describe "Add-FakeWorkspace" {
    It "writes a workspace.json containing the folder uri" {
        $root = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeWorkspace -CodeRoot $root -Hash 'abc123' -FolderUri 'file:///d%3A/Nuxt/foo' | Out-Null
        $meta = Join-Path $root 'User\workspaceStorage\abc123\workspace.json'
        (Get-Content $meta -Raw | ConvertFrom-Json).folder | Should Be 'file:///d%3A/Nuxt/foo'
    }
}

Describe "Add-FakeHistory" {
    It "writes an entries.json containing the resource uri" {
        $root = New-FakeCodeRoot -Parent $TestDrive
        Add-FakeHistory -CodeRoot $root -Hash 'hist1' -ResourceUri 'file:///d%3A/Nuxt/foo/a.vue' | Out-Null
        $meta = Join-Path $root 'User\History\hist1\entries.json'
        (Get-Content $meta -Raw | ConvertFrom-Json).resource | Should Be 'file:///d%3A/Nuxt/foo/a.vue'
    }
}
