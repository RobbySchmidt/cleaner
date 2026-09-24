. "$PSScriptRoot\..\src\VSCodeDiff.ps1"

Describe "Compare-DiscoveryToResolver" {
    $artifacts = @(
        [pscustomobject]@{ Path = 'C:\Code\User\History\h1';          Source = 'History';          Confidence = 'certain'; Hash = 'h1' },
        [pscustomobject]@{ Path = 'C:\Code\User\workspaceStorage\w1'; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'w1' }
    )
    $written = @(
        'C:\Code\User\History\h1\aaaa.vue',
        'C:\Code\User\globalStorage\some.ext\state.json'
    )

    It "counts a written path under a known artifact as covered" {
        $r = Compare-DiscoveryToResolver -WrittenPaths $written -Artifacts $artifacts
        @($r.Covered).Count | Should Be 1
        $r.Covered[0]       | Should Be 'C:\Code\User\History\h1\aaaa.vue'
    }
    It "reports a written path under no artifact as a gap" {
        $r = Compare-DiscoveryToResolver -WrittenPaths $written -Artifacts $artifacts
        @($r.Gaps).Count | Should Be 1
        $r.Gaps[0]       | Should Be 'C:\Code\User\globalStorage\some.ext\state.json'
    }
    It "reports artifacts nothing wrote to as stale" {
        $r = Compare-DiscoveryToResolver -WrittenPaths $written -Artifacts $artifacts
        @($r.Stale).Count | Should Be 1
        $r.Stale[0]       | Should Be 'C:\Code\User\workspaceStorage\w1'
    }
}
