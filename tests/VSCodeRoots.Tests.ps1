. "$PSScriptRoot\..\src\VSCodeRoots.ps1"

Describe "Get-VSCodeRoots" {
    It "derives all roots from the code root" {
        $roots = Get-VSCodeRoots -CodeRoot 'C:\fake\Code' -UserProfile 'C:\fake\user'
        $roots.WorkspaceStorage | Should Be 'C:\fake\Code\User\workspaceStorage'
        $roots.History          | Should Be 'C:\fake\Code\User\History'
        $roots.Backups          | Should Be 'C:\fake\Code\Backups'
        $roots.Logs             | Should Be 'C:\fake\Code\logs'
        $roots.DotVscode        | Should Be 'C:\fake\user\.vscode'
    }
}

Describe "Test-PathUnderArtifactRoots" {
    $roots = Get-VSCodeRoots -CodeRoot 'C:\fake\Code' -UserProfile 'C:\fake\user'

    It "accepts a path inside each artifact root" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\History\abc'          -Roots $roots | Should Be $true
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\workspaceStorage\abc' -Roots $roots | Should Be $true
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\Backups\abc'               -Roots $roots | Should Be $true
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\logs\s1\window1'           -Roots $roots | Should Be $true
    }
    It "rejects shared state that no scanner emits" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\settings.json' -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\snippets'      -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User'               -Roots $roots | Should Be $false
    }
    It "rejects a path inside .vscode" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.vscode\extensions\x' -Roots $roots | Should Be $false
    }
    It "rejects a path outside the roots" {
        Test-PathUnderArtifactRoots -Path 'D:\Nuxt\foo' -Roots $roots | Should Be $false
    }
    It "rejects the code root itself" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code' -Roots $roots | Should Be $false
    }
    It "rejects an artifact root itself" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\History' -Roots $roots | Should Be $false
    }
    It "rejects a sibling with the same prefix" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\CodeOther\x'               -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\HistoryOther\x'  -Roots $roots | Should Be $false
    }
    It "rejects a traversal that escapes the roots" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\History\..\..\..\..\Windows\System32' -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\History\..\snippets' -Roots $roots | Should Be $false
    }
    It "rejects an artifact root with a trailing separator" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\Code\User\History\' -Roots $roots | Should Be $false
    }
    It "accepts a path that differs only in case" {
        Test-PathUnderArtifactRoots -Path 'c:\FAKE\code\user\history\abc' -Roots $roots | Should Be $true
    }
    It "accepts forward slashes" {
        Test-PathUnderArtifactRoots -Path 'C:/fake/Code/User/History/abc' -Roots $roots | Should Be $true
    }
}

Describe "Get-VSCodeRoots (Claude Code)" {
    It "derives the Claude roots from the user profile by default" {
        $roots = Get-VSCodeRoots -CodeRoot 'C:\fake\Code' -UserProfile 'C:\fake\user'
        $roots.ClaudeRoot        | Should Be 'C:\fake\user\.claude'
        $roots.ClaudeProjects    | Should Be 'C:\fake\user\.claude\projects'
        $roots.ClaudeFileHistory | Should Be 'C:\fake\user\.claude\file-history'
        $roots.ClaudeSessionEnv  | Should Be 'C:\fake\user\.claude\session-env'
        $roots.ClaudeSessions    | Should Be 'C:\fake\user\.claude\sessions'
    }
    It "honours an explicit ClaudeRoot" {
        $roots = Get-VSCodeRoots -CodeRoot 'C:\fake\Code' -UserProfile 'C:\fake\user' -ClaudeRoot 'E:\other\.claude'
        $roots.ClaudeRoot     | Should Be 'E:\other\.claude'
        $roots.ClaudeProjects | Should Be 'E:\other\.claude\projects'
    }
}

Describe "Test-PathUnderArtifactRoots (Claude Code)" {
    $roots = Get-VSCodeRoots -CodeRoot 'C:\fake\Code' -UserProfile 'C:\fake\user'

    It "accepts a path inside each of the three Claude artifact roots" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\projects\d--Nuxt-foo'          -Roots $roots | Should Be $true
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\projects\d--Nuxt-foo\s1.jsonl' -Roots $roots | Should Be $true
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\file-history\s1'               -Roots $roots | Should Be $true
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\session-env\s1'                -Roots $roots | Should Be $true
    }
    It "rejects the Claude root and its shared state" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude'                       -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\settings.json'         -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\.credentials.json'     -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\sessions\123.json'     -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\shell-snapshots\x.sh'  -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\plugins\x'             -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude.json'                  -Roots $roots | Should Be $false
    }
    It "rejects a Claude artifact root itself" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\projects'     -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\file-history' -Roots $roots | Should Be $false
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\session-env'  -Roots $roots | Should Be $false
    }
    It "rejects a sibling with the same prefix" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\projects-old\x' -Roots $roots | Should Be $false
    }
    It "rejects a traversal out of a Claude root" {
        Test-PathUnderArtifactRoots -Path 'C:\fake\user\.claude\projects\..\settings.json' -Roots $roots | Should Be $false
    }
}
