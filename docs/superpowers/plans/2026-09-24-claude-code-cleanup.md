# Claude Code Project Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `vscode-cleanup.ps1 -Project <path>` also finds and deletes the project's Claude Code data under `~\.claude` (transcripts, subagent transcripts, memory, file-history, session-env).

**Architecture:** New scanners in `src/ClaudeCodeSources.ps1` return the same artifact objects the VS Code scanners return. A new orchestrator `Get-ProjectArtifacts` (`src/ProjectArtifacts.ps1`) merges both. Deletion stays in the existing `Remove-VSCodeArtifacts`, whose allowlist gains exactly three Claude roots. Ownership comes from the `cwd` recorded inside each transcript, never from the lossy folder name alone.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4.0.

**Spec:** `docs/superpowers/specs/2026-09-24-claude-code-cleanup-design.md`

## Global Constraints

- Windows PowerShell 5.1 only. No PowerShell 7 syntax (`??`, `?.`, ternary, `&&`).
- Pester 3.4.0 syntax: `Should Be`, `Should Match`, `Should Throw`, `Should BeGreaterThan`. Never `Should -Be`. Never `Should Contain` (in 3.4 it checks *file content*).
- Run tests with: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script <path>`
- Tests must never read or write the real `~\.claude` or `%APPDATA%\Code`. Every roots object in a test comes from `Get-VSCodeRoots` with `-UserProfile $TestDrive` or `-ClaudeRoot <fixture>`; every CLI test passes `-CodeRoot` **and** `-ClaudeRoot`.
- Deletion happens only in `Remove-VSCodeArtifacts`. No new `Remove-Item` anywhere else.
- Allowlist gains exactly `ClaudeProjects`, `ClaudeFileHistory`, `ClaudeSessionEnv`. Never `ClaudeRoot`, never `ClaudeSessions`.
- Never read-modify-write `~\.claude.json` or any other shared file.
- Artifact objects: `Path`, `Source`, `Confidence` (`'certain'` | `'probable'`, lowercase), `Hash`. Claude artifacts add `SessionIds` (string[]) and `Owners` (string[]).
- Claude `Source` values exactly: `claude:projects`, `claude:file-history`, `claude:session-env`.
- No personal paths in committed files. Use `C:\Users\<you>\...` in docs, and `D:\Nuxt\...` / `$TestDrive` in tests.
- Baseline before starting: 86 tests pass.

## Review Focus

- A transcript that a running Claude Code session holds open for writing: its owner must still be read, not silently treated as ownerless. Test in Task 2.
- A transcript whose `cwd` is not a drive path (UNC `\\server\share\...`, WSL `/home/...`): it counts as *foreign*, doesn't crash, and stops a whole-folder delete. Test in Task 3.
- The project typed with different case or a trailing backslash compared to the recorded `cwd` (`C:\X\foo\` vs `c:\x\Foo`): still matches. Test in Task 3.
- A transcript file named so its session ID is `..` or contains odd characters: it must never make a session artifact resolve to a Claude root or its parent. Test in Task 4.
- `~\.claude` missing entirely (Claude Code never installed): the CLI runs the VS Code cleanup normally, with no error. Test in Task 7.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `src/VSCodeRoots.ps1` | Modify | Roots object gains Claude roots; allowlist gains three of them |
| `src/ClaudeCodeSources.ps1` | Create | Transcript owner, folder-name encoding, Claude scanners, running-session check |
| `src/ProjectArtifacts.ps1` | Create | `Get-ProjectArtifacts`: VS Code + Claude, Claude parent warning |
| `src/VSCodeReport.ps1` | Modify | Report heading no longer says "VS Code" |
| `src/VSCodeRemove.ps1` | Modify | ShouldProcess text no longer says "VS Code" |
| `vscode-cleanup.ps1` | Modify | `-ClaudeRoot`, use `Get-ProjectArtifacts`, running-Claude warning |
| `vscode-discover.ps1` | Modify | Watch `ClaudeRoot`, diff against `Get-ProjectArtifacts` |
| `tests/TestHelpers.ps1` | Modify | Fake `~\.claude` fixtures |
| `tests/VSCodeRoots.Tests.ps1` | Modify | Claude roots + allowlist |
| `tests/ClaudeCodeSources.Tests.ps1` | Create | All Claude scanner tests |
| `tests/ProjectArtifacts.Tests.ps1` | Create | Orchestrator tests |
| `tests/Cli.Tests.ps1` | Modify | Isolate existing tests; Claude end-to-end tests |
| `README.md`, `HOWTO.md` | Modify | Document the Claude Code coverage |

---

### Task 1: Claude roots and allowlist

**Files:**
- Modify: `src/VSCodeRoots.ps1` (whole file shown below)
- Test: `tests/VSCodeRoots.Tests.ps1`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Get-VSCodeRoots [-CodeRoot <string>] [-UserProfile <string>] [-ClaudeRoot <string>]` returns an object with the existing properties plus `ClaudeRoot`, `ClaudeProjects`, `ClaudeFileHistory`, `ClaudeSessionEnv`, `ClaudeSessions` (all strings). `Test-PathUnderArtifactRoots -Path -Roots` also accepts paths under the three Claude roots.

- [ ] **Step 1: Write the failing tests**

Append to `tests/VSCodeRoots.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\VSCodeRoots.Tests.ps1`
Expected: the new `Get-VSCodeRoots (Claude Code)` tests and "accepts a path inside each of the three Claude artifact roots" FAIL (`$roots.ClaudeRoot` is `$null`). The reject tests already pass.

- [ ] **Step 3: Implement**

Replace `src/VSCodeRoots.ps1` with:

```powershell
function Get-VSCodeRoots {
    param(
        [string]$CodeRoot    = (Join-Path $env:APPDATA 'Code'),
        [string]$UserProfile = $env:USERPROFILE,
        [string]$ClaudeRoot
    )

    # Derived from -UserProfile, not straight from $env:USERPROFILE, so every test that
    # already passes -UserProfile $TestDrive stays isolated from the real ~\.claude.
    if (-not $ClaudeRoot) { $ClaudeRoot = Join-Path $UserProfile '.claude' }

    [pscustomobject]@{
        CodeRoot          = $CodeRoot
        WorkspaceStorage  = Join-Path $CodeRoot 'User\workspaceStorage'
        History           = Join-Path $CodeRoot 'User\History'
        Backups           = Join-Path $CodeRoot 'Backups'
        Logs              = Join-Path $CodeRoot 'logs'
        DotVscode         = Join-Path $UserProfile '.vscode'
        ClaudeRoot        = $ClaudeRoot
        ClaudeProjects    = Join-Path $ClaudeRoot 'projects'
        ClaudeFileHistory = Join-Path $ClaudeRoot 'file-history'
        ClaudeSessionEnv  = Join-Path $ClaudeRoot 'session-env'
        ClaudeSessions    = Join-Path $ClaudeRoot 'sessions'
    }
}

# Allowlists only the roots the scanners actually emit from -- NOT CodeRoot or ClaudeRoot
# wholesale. Permitting all of %APPDATA%\Code would also permit deleting User\settings.json,
# snippets, Preferences and machineid; permitting all of ~\.claude would permit
# settings.json, .credentials.json and plugins. None of those can be produced by a scanner.
# A scanner bug that emitted a parent directory would then pass validation and
# Remove-Item -Recurse would take shared state with it. .vscode is deliberately absent: it
# is a discovery watch target, never a deletion source. ClaudeSessions is absent too: it is
# read by the running-session check, never deleted. A future scanner that needs a new root
# must add it here deliberately rather than inherit deletion rights.
#
# Lexical check only. GetFullPath normalizes '.', '..', slashes and 8.3 short names, but it
# does NOT resolve NTFS reparse points -- a junction inside a root still reads as "inside"
# even though it points elsewhere. Resolving link targets needs P/Invoke on PowerShell 5.1,
# and this function must also work on fixture paths that do not exist on disk, so the
# reparse-point guard lives in Remove-VSCodeArtifacts, where deletion happens.
function Test-PathUnderArtifactRoots {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Roots
    )

    $cmp       = [System.StringComparison]::OrdinalIgnoreCase
    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    $allowed = @($Roots.WorkspaceStorage, $Roots.History, $Roots.Backups, $Roots.Logs,
                 $Roots.ClaudeProjects, $Roots.ClaudeFileHistory, $Roots.ClaudeSessionEnv)

    foreach ($root in $allowed) {
        if (-not $root) { continue }
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        # Explicit for intent; subsumed by the separator in the StartsWith below.
        if ($candidate.Equals($r, $cmp)) { return $false }
        if ($candidate.StartsWith($r + '\', $cmp)) { return $true }
    }

    return $false
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\VSCodeRoots.Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Run the full suite**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests`
Expected: 0 failed.

- [ ] **Step 6: Commit**

```bash
git add src/VSCodeRoots.ps1 tests/VSCodeRoots.Tests.ps1
git commit -m "feat: add Claude Code roots and allowlist three of them"
```

---

### Task 2: Transcript owner, folder-name encoding, test fixtures

**Files:**
- Create: `src/ClaudeCodeSources.ps1`
- Modify: `tests/TestHelpers.ps1` (append)
- Create: `tests/ClaudeCodeSources.Tests.ps1`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Get-ClaudeTranscriptOwner -Path <string>` → `[string]` the first `cwd` in the file, or `$null`.
  - `ConvertTo-ClaudeProjectDirName -Path <string>` → `[string]` e.g. `'D:\Nuxt\foo'` → `'D--Nuxt-foo'`.
  - Test helpers: `New-FakeClaudeRoot -Parent`, `Add-FakeClaudeTranscript -ClaudeRoot -DirName -SessionId [-Cwd] [-RawLines] [-WithSessionFolder]` (returns the `.jsonl` path), `Add-FakeClaudeMemory -ClaudeRoot -DirName` (returns the project dir), `Add-FakeClaudeSessionDir -ClaudeRoot -Kind <'file-history'|'session-env'> -SessionId` (returns the dir), `Add-FakeClaudeLiveSession -ClaudeRoot -ProcessId -Cwd [-SessionId] [-RawJson]` (returns the json path).

- [ ] **Step 1: Add the fixtures**

Append to `tests/TestHelpers.ps1`:

```powershell
function New-FakeClaudeRoot {
    param([Parameter(Mandatory = $true)][string]$Parent)

    $root = Join-Path $Parent ('claude-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    foreach ($sub in @('projects', 'file-history', 'session-env', 'sessions')) {
        New-Item -Path (Join-Path $root $sub) -ItemType Directory -Force | Out-Null
    }
    $root
}

function Add-FakeClaudeTranscript {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][string]$DirName,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [string]$Cwd,
        [string[]]$RawLines,
        [switch]$WithSessionFolder
    )

    $dir = Join-Path $ClaudeRoot "projects\$DirName"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null

    $lines = if ($PSBoundParameters.ContainsKey('RawLines')) { $RawLines } else {
        @(
            (@{ type = 'summary'; summary = 'no cwd on this line' } | ConvertTo-Json -Compress),
            (@{ type = 'user'; cwd = $Cwd; sessionId = $SessionId } | ConvertTo-Json -Compress)
        )
    }

    $file = Join-Path $dir "$SessionId.jsonl"
    [System.IO.File]::WriteAllLines($file, [string[]]$lines)

    if ($WithSessionFolder) {
        $sub = Join-Path $dir "$SessionId\subagents"
        New-Item -Path $sub -ItemType Directory -Force | Out-Null
        '{}' | Out-File -FilePath (Join-Path $sub 'agent-1.jsonl') -Encoding utf8
    }
    $file
}

function Add-FakeClaudeMemory {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][string]$DirName
    )

    $dir = Join-Path $ClaudeRoot "projects\$DirName"
    New-Item -Path (Join-Path $dir 'memory') -ItemType Directory -Force | Out-Null
    '- a memory' | Out-File -FilePath (Join-Path $dir 'memory\MEMORY.md') -Encoding utf8
    $dir
}

function Add-FakeClaudeSessionDir {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][ValidateSet('file-history', 'session-env')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$SessionId
    )

    $dir = Join-Path $ClaudeRoot "$Kind\$SessionId"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'before edit' | Out-File -FilePath (Join-Path $dir 'x@v1') -Encoding utf8
    $dir
}

function Add-FakeClaudeLiveSession {
    param(
        [Parameter(Mandatory = $true)][string]$ClaudeRoot,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string]$Cwd,
        [string]$SessionId = 'live',
        [string]$RawJson
    )

    $json = if ($PSBoundParameters.ContainsKey('RawJson')) { $RawJson }
            else { @{ pid = $ProcessId; sessionId = $SessionId; cwd = $Cwd; status = 'busy' } | ConvertTo-Json -Compress }
    $file = Join-Path $ClaudeRoot "sessions\$ProcessId.json"
    $json | Out-File -FilePath $file -Encoding utf8
    $file
}
```

- [ ] **Step 2: Write the failing tests**

Create `tests/ClaudeCodeSources.Tests.ps1`:

```powershell
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: FAIL. The dot-source of `src\ClaudeCodeSources.ps1` errors (file missing), then every test fails with "The term 'Get-ClaudeTranscriptOwner' is not recognized".

- [ ] **Step 4: Implement**

Create `src/ClaudeCodeSources.ps1`:

```powershell
<#
.SYNOPSIS
    The launch directory a Claude Code transcript was filed under: the first "cwd" in it.

.DESCRIPTION
    Later lines can carry a different cwd after the session cd's elsewhere; Claude Code
    files the transcript by the launch directory, so only the first one counts.

    Reads line by line and stops at the first hit -- transcripts reach ~1 MB. Only lines
    that contain "cwd" are parsed, and an unparseable line is skipped, not fatal.

    Opened with FileShare ReadWrite|Delete because a running Claude Code session holds its
    transcript open for writing. A plain StreamReader(path) would fail on exactly the
    transcript the user is most likely to be cleaning, and the failure would read as
    "ownerless" -- which can let a folder through as `probable` instead of `certain`.
#>
function Get-ClaudeTranscriptOwner {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $reader = $null
    try {
        $share  = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        $reader = [System.IO.StreamReader]::new($stream)

        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.IndexOf('"cwd"') -lt 0) { continue }
            try { $obj = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($obj.cwd) { return [string]$obj.cwd }
        }
        return $null
    } catch {
        return $null
    } finally {
        if ($reader) { $reader.Dispose() } elseif ($stream) { $stream.Dispose() }
    }
}

# Claude Code names ~\.claude\projects\<dir> after the launch directory with every
# character outside A-Za-z0-9 replaced by '-'. Lossy: 'A-B', 'A B' and 'A\B' collide.
# Used ONLY for the `probable` fallback on folders that have no transcript left to read.
function ConvertTo-ClaudeProjectDirName {
    param([Parameter(Mandatory = $true)][string]$Path)

    ([System.IO.Path]::GetFullPath($Path).TrimEnd('\')) -replace '[^A-Za-z0-9]', '-'
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/ClaudeCodeSources.ps1 tests/ClaudeCodeSources.Tests.ps1 tests/TestHelpers.ps1
git commit -m "feat: read Claude Code transcript owners"
```

---

### Task 3: `Get-ClaudeProjectArtifacts` (the five folder rules)

**Files:**
- Modify: `src/ClaudeCodeSources.ps1` (append)
- Test: `tests/ClaudeCodeSources.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Get-ClaudeTranscriptOwner`, `ConvertTo-VSCodeUri` and `Test-UriUnderProject` (existing, `src/VSCodeUri.ps1`), `Get-VSCodeRoots` (Task 1).
- Produces:
  - `Get-ClaudeTranscriptClass -Owner <string|null> -ProjectUri <string>` → `'owned'` | `'foreign'` | `'ownerless'`.
  - `Get-ClaudeProjectArtifacts -Roots <roots> -ProjectUri <string> -ProjectDirName <string>` → artifacts with `Source = 'claude:projects'`, plus `SessionIds` (string[]) and `Owners` (string[]).

- [ ] **Step 1: Write the failing tests**

Append to `tests/ClaudeCodeSources.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: the new `Get-ClaudeProjectArtifacts` tests FAIL with "The term 'Get-ClaudeProjectArtifacts' is not recognized". Task 2 tests still pass.

- [ ] **Step 3: Implement**

Append to `src/ClaudeCodeSources.ps1`:

```powershell
# owned     -- the transcript's launch directory is the project or inside it
# foreign   -- it has a launch directory, and it is somewhere else
# ownerless -- no cwd at all (e.g. a one-line "teleported-from" stub); counts for nobody
#
# A cwd that ConvertTo-VSCodeUri rejects (UNC, WSL '/home/...', relative) is a real owner
# that cannot be under a drive-path project, so it is foreign -- never ownerless, because
# ownerless would let its folder be taken whole.
function Get-ClaudeTranscriptClass {
    param(
        [AllowNull()][AllowEmptyString()][string]$Owner,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not $Owner) { return 'ownerless' }
    try { $ownerUri = ConvertTo-VSCodeUri -Path $Owner } catch { return 'foreign' }
    if (Test-UriUnderProject -Uri $ownerUri -ProjectUri $ProjectUri) { 'owned' } else { 'foreign' }
}

<#
.SYNOPSIS
    ~\.claude\projects folders (or parts of them) that belong to a project.

.DESCRIPTION
    The folder name is lossy ('A-B', 'A B' and 'A\B' share one), so ownership comes from
    each transcript's recorded cwd, via the same Test-UriUnderProject boundary rule the
    VS Code scanners use. Per folder:

      owned, no foreign     -> whole folder, certain (memory\, <sid>\ and stubs included)
      owned and foreign     -> each owned <sid>.jsonl and its <sid>\ folder, certain;
                               memory\, stubs and the folder stay -- they are shared
      neither               -> whole folder, probable, only if its name equals the
                               project's encoded name (memory-only folders)
      only foreign          -> nothing
#>
function Get-ClaudeProjectArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri,
        [Parameter(Mandatory = $true)][string]$ProjectDirName
    )

    if (-not (Test-Path -LiteralPath $Roots.ClaudeProjects)) { return @() }

    Get-ChildItem -LiteralPath $Roots.ClaudeProjects -Directory | ForEach-Object {
        $dir     = $_
        $owned   = @()
        $foreign = 0

        foreach ($t in @(Get-ChildItem -LiteralPath $dir.FullName -Filter '*.jsonl' -File)) {
            $owner = Get-ClaudeTranscriptOwner -Path $t.FullName
            switch (Get-ClaudeTranscriptClass -Owner $owner -ProjectUri $ProjectUri) {
                'owned'   { $owned += [pscustomobject]@{ File = $t.FullName; SessionId = $t.BaseName; Owner = $owner } }
                'foreign' { $foreign++ }
            }
        }

        if ($owned.Count -gt 0 -and $foreign -eq 0) {
            [pscustomobject]@{
                Path       = $dir.FullName
                Source     = 'claude:projects'
                Confidence = 'certain'
                Hash       = $dir.Name
                SessionIds = @($owned | ForEach-Object { $_.SessionId })
                Owners     = @($owned | ForEach-Object { $_.Owner } | Sort-Object -Unique)
            }
        } elseif ($owned.Count -gt 0) {
            foreach ($o in $owned) {
                [pscustomobject]@{
                    Path       = $o.File
                    Source     = 'claude:projects'
                    Confidence = 'certain'
                    Hash       = $o.SessionId
                    SessionIds = @($o.SessionId)
                    Owners     = @($o.Owner)
                }
                $sub = Join-Path $dir.FullName $o.SessionId
                if (Test-Path -LiteralPath $sub -PathType Container) {
                    # The session ID is carried once, on the transcript artifact above.
                    [pscustomobject]@{
                        Path       = $sub
                        Source     = 'claude:projects'
                        Confidence = 'certain'
                        Hash       = $o.SessionId
                        SessionIds = @()
                        Owners     = @($o.Owner)
                    }
                }
            }
        } elseif ($foreign -eq 0 -and $dir.Name -ieq $ProjectDirName) {
            [pscustomobject]@{
                Path       = $dir.FullName
                Source     = 'claude:projects'
                Confidence = 'probable'
                Hash       = $dir.Name
                SessionIds = @()
                Owners     = @()
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ClaudeCodeSources.ps1 tests/ClaudeCodeSources.Tests.ps1
git commit -m "feat: find a project's Claude Code transcript folders"
```

---

### Task 4: `Get-ClaudeSessionArtifacts`

**Files:**
- Modify: `src/ClaudeCodeSources.ps1` (append)
- Test: `tests/ClaudeCodeSources.Tests.ps1` (append)

**Interfaces:**
- Consumes: roots from Task 1; session IDs from `Get-ClaudeProjectArtifacts` (`SessionIds`).
- Produces: `Get-ClaudeSessionArtifacts -Roots <roots> [-SessionIds <string[]>]` → artifacts with `Source` `claude:file-history` / `claude:session-env`, `Confidence = 'certain'`, `Hash` = session ID, `SessionIds = @()`, `Owners = @()`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ClaudeCodeSources.Tests.ps1`:

```powershell
Describe "Get-ClaudeSessionArtifacts" {
    It "returns file-history and session-env folders for the given sessions only" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $fh     = Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 's1'
        $se     = Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'session-env'  -SessionId 's1'
        Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 'orphan' | Out-Null
        Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'session-env'  -SessionId 'orphan' | Out-Null
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        $result = @(Get-ClaudeSessionArtifacts -Roots $roots -SessionIds @('s1'))

        $result.Count | Should Be 2
        (@($result | Where-Object { $_.Source -eq 'claude:file-history' }))[0].Path | Should Be $fh
        (@($result | Where-Object { $_.Source -eq 'claude:session-env' }))[0].Path  | Should Be $se
        @($result | Where-Object { $_.Confidence -ne 'certain' }).Count | Should Be 0
    }

    It "returns nothing for an empty session list" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeSessionDir -ClaudeRoot $claude -Kind 'file-history' -SessionId 's1' | Out-Null
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        @(Get-ClaudeSessionArtifacts -Roots $roots -SessionIds @()).Count | Should Be 0
    }

    It "ignores a session ID that could escape its root" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        @(Get-ClaudeSessionArtifacts -Roots $roots -SessionIds @('..', '.', 'a\..\..', '')).Count | Should Be 0
    }

    It "returns nothing when the roots are missing" {
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot (Join-Path $TestDrive 'noclaude')
        @(Get-ClaudeSessionArtifacts -Roots $roots -SessionIds @('s1')).Count | Should Be 0
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: the new tests FAIL with "The term 'Get-ClaudeSessionArtifacts' is not recognized".

- [ ] **Step 3: Implement**

Append to `src/ClaudeCodeSources.ps1`:

```powershell
# Session IDs come from transcript file names, which anything can create. Only a plain
# ID is joined onto a root: '..' would otherwise resolve to ~\.claude itself, which the
# allowlist refuses -- and that refusal aborts the whole deletion, not just this item.
function Get-ClaudeSessionArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [AllowEmptyCollection()][string[]]$SessionIds = @()
    )

    $kinds = @(
        @{ Root = $Roots.ClaudeFileHistory; Source = 'claude:file-history' },
        @{ Root = $Roots.ClaudeSessionEnv;  Source = 'claude:session-env'  }
    )

    foreach ($kind in $kinds) {
        if (-not (Test-Path -LiteralPath $kind.Root)) { continue }

        foreach ($id in ($SessionIds | Sort-Object -Unique)) {
            if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { continue }

            $dir = Join-Path $kind.Root $id
            if (Test-Path -LiteralPath $dir -PathType Container) {
                [pscustomobject]@{
                    Path       = $dir
                    Source     = $kind.Source
                    Confidence = 'certain'
                    Hash       = $id
                    SessionIds = @()
                    Owners     = @()
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ClaudeCodeSources.ps1 tests/ClaudeCodeSources.Tests.ps1
git commit -m "feat: find a project's Claude Code file-history and session-env"
```

---

### Task 5: `Get-ClaudeRunningSessions`

**Files:**
- Modify: `src/ClaudeCodeSources.ps1` (append)
- Test: `tests/ClaudeCodeSources.Tests.ps1` (append)

**Interfaces:**
- Consumes: `Get-ClaudeTranscriptClass` (Task 3), roots (Task 1).
- Produces: `Get-ClaudeRunningSessions -Roots <roots> -ProjectUri <string>` → objects `{ ProcessId [int]; SessionId [string]; Cwd [string] }`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/ClaudeCodeSources.Tests.ps1`:

```powershell
Describe "Get-ClaudeRunningSessions" {
    $uri = ConvertTo-VSCodeUri -Path 'D:\Nuxt\foo'

    It "reports a live session running in the project" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeLiveSession -ClaudeRoot $claude -ProcessId $PID -Cwd 'D:\Nuxt\foo\sub' -SessionId 's1' | Out-Null
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        $result = @(Get-ClaudeRunningSessions -Roots $roots -ProjectUri $uri)

        $result.Count        | Should Be 1
        $result[0].ProcessId | Should Be $PID
        $result[0].SessionId | Should Be 's1'
    }

    It "ignores a live session in another project" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeLiveSession -ClaudeRoot $claude -ProcessId $PID -Cwd 'D:\Nuxt\foo-main' | Out-Null
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        @(Get-ClaudeRunningSessions -Roots $roots -ProjectUri $uri).Count | Should Be 0
    }

    It "ignores a session whose process has exited" {
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'exit' -PassThru -WindowStyle Hidden
        $p.WaitForExit()
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeLiveSession -ClaudeRoot $claude -ProcessId $p.Id -Cwd 'D:\Nuxt\foo' | Out-Null
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude

        @(Get-ClaudeRunningSessions -Roots $roots -ProjectUri $uri).Count | Should Be 0
    }

    It "warns and skips an unreadable session file" {
        $claude = New-FakeClaudeRoot -Parent $TestDrive
        Add-FakeClaudeLiveSession -ClaudeRoot $claude -ProcessId 1 -RawJson '{ not json' | Out-Null
        $roots  = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot $claude
        $w = @()

        $result = @(Get-ClaudeRunningSessions -Roots $roots -ProjectUri $uri -WarningVariable w -WarningAction SilentlyContinue)

        $result.Count | Should Be 0
        $w.Count      | Should BeGreaterThan 0
    }

    It "returns nothing when the sessions root is missing" {
        $roots = Get-VSCodeRoots -CodeRoot (Join-Path $TestDrive 'nocode') -ClaudeRoot (Join-Path $TestDrive 'noclaude')
        @(Get-ClaudeRunningSessions -Roots $roots -ProjectUri $uri).Count | Should Be 0
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: the new tests FAIL with "The term 'Get-ClaudeRunningSessions' is not recognized".

- [ ] **Step 3: Implement**

Append to `src/ClaudeCodeSources.ps1`:

```powershell
# ~\.claude\sessions\<pid>.json exists while a session runs and is removed when it exits.
# The pid check covers a crash that left the file behind. Advisory only: the CLI warns,
# it never refuses, so a reused pid costs a spurious warning and nothing else.
function Get-ClaudeRunningSessions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path -LiteralPath $Roots.ClaudeSessions)) { return @() }

    Get-ChildItem -LiteralPath $Roots.ClaudeSessions -Filter '*.json' -File | ForEach-Object {
        $file = $_.FullName
        try {
            $j = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Warning "Skipping unreadable $file"
            return
        }

        if (-not $j.cwd -or -not $j.pid) { return }
        if ((Get-ClaudeTranscriptClass -Owner $j.cwd -ProjectUri $ProjectUri) -ne 'owned') { return }
        if (-not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) { return }

        [pscustomobject]@{
            ProcessId = [int]$j.pid
            SessionId = [string]$j.sessionId
            Cwd       = [string]$j.cwd
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ClaudeCodeSources.Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ClaudeCodeSources.ps1 tests/ClaudeCodeSources.Tests.ps1
git commit -m "feat: detect Claude Code sessions running in a project"
```

---

### Task 6: `Get-ProjectArtifacts` orchestrator

**Files:**
- Create: `src/ProjectArtifacts.ps1`
- Create: `tests/ProjectArtifacts.Tests.ps1`

**Interfaces:**
- Consumes: `Get-VSCodeProjectArtifacts` (existing), `ConvertTo-VSCodeUri`, `ConvertTo-ClaudeProjectDirName`, `Get-ClaudeProjectArtifacts`, `Get-ClaudeSessionArtifacts`.
- Produces: `Get-ProjectArtifacts -Project <string> [-Roots <roots>]` → VS Code artifacts followed by Claude artifacts. Throws `drive root` for drive roots. Warns `parent of N separate Claude Code projects`.

- [ ] **Step 1: Write the failing tests**

Create `tests/ProjectArtifacts.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ProjectArtifacts.Tests.ps1`
Expected: FAIL with "The term 'Get-ProjectArtifacts' is not recognized".

- [ ] **Step 3: Implement**

Create `src/ProjectArtifacts.ps1`:

```powershell
<#
.SYNOPSIS
    Everything VS Code and Claude Code wrote outside a project folder on its behalf.
#>
function Get-ProjectArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        $Roots = (Get-VSCodeRoots)
    )

    # First, so its drive-root guard throws before anything under ~\.claude is read.
    $vscode = @(Get-VSCodeProjectArtifacts -Project $Project -Roots $Roots)

    $uri      = ConvertTo-VSCodeUri -Path $Project
    $dirName  = ConvertTo-ClaudeProjectDirName -Path $Project
    $projects = @(Get-ClaudeProjectArtifacts -Roots $Roots -ProjectUri $uri -ProjectDirName $dirName)

    # Same hazard as the VS Code parent warning: "Found 40 artifact(s)" reads like one big
    # project, not like several separate ones. Warn, don't refuse -- deleting a parent
    # folder does mean deleting everything under it.
    $owners = @($projects | ForEach-Object { $_.Owners } | Where-Object { $_ } |
                ForEach-Object { $_.TrimEnd('\') } | Sort-Object -Unique)
    if ($owners.Count -gt 1) {
        Write-Warning ("'$Project' is a parent of $($owners.Count) separate Claude Code projects. " +
                       "These artifacts belong to all of them, not to one project. " +
                       "Review the report before using -Delete.")
    }

    $ids      = @($projects | ForEach-Object { $_.SessionIds } | Where-Object { $_ })
    $sessions = @(Get-ClaudeSessionArtifacts -Roots $Roots -SessionIds $ids)

    @($vscode + $projects + $sessions)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\ProjectArtifacts.Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ProjectArtifacts.ps1 tests/ProjectArtifacts.Tests.ps1
git commit -m "feat: combine VS Code and Claude Code artifacts per project"
```

---

### Task 7: CLI wiring, report heading, running-Claude warning

**Files:**
- Modify: `vscode-cleanup.ps1` (whole file shown below)
- Modify: `src/VSCodeReport.ps1:25`
- Modify: `src/VSCodeRemove.ps1:72`
- Modify: `tests/Cli.Tests.ps1` (whole file shown below)

**Interfaces:**
- Consumes: `Get-VSCodeRoots -ClaudeRoot` (Task 1), `Get-ProjectArtifacts` (Task 6), `Get-ClaudeRunningSessions` (Task 5).
- Produces: `vscode-cleanup.ps1 -Project [-Delete] [-IncludeProbable] [-ReportPath] [-CodeRoot] [-ClaudeRoot] [-WhatIf]`.

- [ ] **Step 1: Write the failing tests**

Replace `tests/Cli.Tests.ps1` with the version below. The existing five tests are unchanged except that each now passes `-ClaudeRoot $claude`, so none of them read the real `~\.claude`.

```powershell
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\Cli.Tests.ps1`
Expected: FAIL. Every test errors with "A parameter cannot be found that matches parameter name 'ClaudeRoot'".

- [ ] **Step 3: Implement the CLI**

Replace `vscode-cleanup.ps1` with:

```powershell
<#
.SYNOPSIS
    Finds (and optionally deletes) everything VS Code and Claude Code wrote outside a
    project folder on that project's behalf.

.EXAMPLE
    .\vscode-cleanup.ps1 -Project 'D:\Nuxt\foo'
    .\vscode-cleanup.ps1 -Project 'D:\Nuxt\foo' -Delete
    .\vscode-cleanup.ps1 -Project 'D:\Nuxt\foo' -Delete -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [switch]$Delete,
    [switch]$IncludeProbable,
    [string]$ReportPath,
    # Testing seam, and genuinely useful for a portable VS Code install.
    # Without it this script has no way to be pointed at a fixture, which would leave
    # the one place -Delete is wired up as the only untested code in the project.
    [string]$CodeRoot,
    # Same seam for ~\.claude. Tests must pass it: without it they would scan the real one.
    [string]$ClaudeRoot
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\src\VSCodeUri.ps1"
. "$PSScriptRoot\src\VSCodeRoots.ps1"
. "$PSScriptRoot\src\VSCodeSources.ps1"
. "$PSScriptRoot\src\ClaudeCodeSources.ps1"
. "$PSScriptRoot\src\ProjectArtifacts.ps1"
. "$PSScriptRoot\src\VSCodeReport.ps1"
. "$PSScriptRoot\src\VSCodeRemove.ps1"

$rootArgs = @{}
if ($CodeRoot)   { $rootArgs.CodeRoot   = $CodeRoot }
if ($ClaudeRoot) { $rootArgs.ClaudeRoot = $ClaudeRoot }
$roots     = Get-VSCodeRoots @rootArgs
$artifacts = @(Get-ProjectArtifacts -Project $Project -Roots $roots | Add-ArtifactSize)

if (-not $ReportPath) {
    $safeName   = (Split-Path $Project -Leaf) -replace '[^\w\-]', '_'
    $ReportPath = Join-Path (Get-Location) "vscode-artifacts-$safeName-$(Get-Date -Format 'yyyyMMdd').txt"
}

Write-ArtifactReport -Artifacts $artifacts -Project $Project -ReportPath $ReportPath | Out-Null

$total = ($artifacts | Measure-Object -Property SizeBytes -Sum).Sum
if (-not $total) { $total = 0 }
Write-Host "Found $($artifacts.Count) artifact(s), $([math]::Round($total / 1MB, 2)) MB"
Write-Host "Report: $ReportPath"

if (-not $Delete) {
    Write-Host "Nothing was deleted. Re-run with -Delete to purge."
    return
}

if (Test-VSCodeRunning) {
    # "Close it first" is not enough and is actively misleading: VS Code keeps state.vscdb
    # open for every workspace it touched this session and releases the handles only on
    # exit. Measured on this machine: 14 workspaces locked while 2 windows were open.
    Write-Warning ("VS Code is running. Quit it completely before deleting - closing the project's " +
                   "window is not enough, because VS Code holds state.vscdb open for every workspace " +
                   "it touched this session. Otherwise those artifacts stay locked and are left behind.")
}

$running = @(Get-ClaudeRunningSessions -Roots $roots -ProjectUri (ConvertTo-VSCodeUri -Path $Project))
if ($running.Count -gt 0) {
    # A live session keeps appending to its transcript, so deleting under it either fails
    # on the lock or leaves a fresh transcript behind the moment the session writes again.
    Write-Warning ("Claude Code is running in this project (PID $(($running | ForEach-Object { $_.ProcessId }) -join ', ')). " +
                   "Quit that session first - it is still writing its transcript, which would be " +
                   "left behind or recreated.")
}

$removed = @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots -IncludeProbable:$IncludeProbable)
Write-Host "Deleted $($removed.Count) artifact(s)."
```

- [ ] **Step 4: Drop "VS Code" from the shared report heading and the delete prompt**

In `src/VSCodeReport.ps1`, line 25, change:

```powershell
    $lines.Add("VS Code artifacts for project: $Project")
```

to:

```powershell
    $lines.Add("Artifacts for project: $Project")
```

In `src/VSCodeRemove.ps1`, line 72, change:

```powershell
        if (-not $PSCmdlet.ShouldProcess($t.Path, 'Delete VS Code artifact')) { continue }
```

to:

```powershell
        if (-not $PSCmdlet.ShouldProcess($t.Path, 'Delete artifact')) { continue }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests\Cli.Tests.ps1`
Expected: all 10 PASS.

- [ ] **Step 6: Run the full suite**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests`
Expected: 0 failed. (`VSCodeReport.Tests.ps1` "names the project" still passes; it only checks the path.)

- [ ] **Step 7: Commit**

```bash
git add vscode-cleanup.ps1 src/VSCodeReport.ps1 src/VSCodeRemove.ps1 tests/Cli.Tests.ps1
git commit -m "feat: clean up Claude Code data from the cleanup command"
```

---

### Task 8: Discovery covers `~\.claude`

**Files:**
- Modify: `vscode-discover.ps1:17-21` (dot-sources), `:31` (watch list), `:64` (resolver call)

**Interfaces:**
- Consumes: `Get-ProjectArtifacts` (Task 6), `$roots.ClaudeRoot` (Task 1).
- Produces: nothing new; the script watches 3 roots and its diff includes Claude artifacts.

This script is interactive (`Read-Host`), so it has no automated test. It gets a syntax check and a manual check instead.

- [ ] **Step 1: Update the dot-sources**

Replace lines 17-21:

```powershell
. "$PSScriptRoot\src\VSCodeUri.ps1"
. "$PSScriptRoot\src\VSCodeRoots.ps1"
. "$PSScriptRoot\src\VSCodeSources.ps1"
. "$PSScriptRoot\src\VSCodeReport.ps1"
. "$PSScriptRoot\src\VSCodeDiff.ps1"
```

with:

```powershell
. "$PSScriptRoot\src\VSCodeUri.ps1"
. "$PSScriptRoot\src\VSCodeRoots.ps1"
. "$PSScriptRoot\src\VSCodeSources.ps1"
. "$PSScriptRoot\src\ClaudeCodeSources.ps1"
. "$PSScriptRoot\src\ProjectArtifacts.ps1"
. "$PSScriptRoot\src\VSCodeReport.ps1"
. "$PSScriptRoot\src\VSCodeDiff.ps1"
```

- [ ] **Step 2: Watch `~\.claude` too**

Change line 31:

```powershell
foreach ($dir in @($roots.CodeRoot, $roots.DotVscode)) {
```

to:

```powershell
foreach ($dir in @($roots.CodeRoot, $roots.DotVscode, $roots.ClaudeRoot)) {
```

- [ ] **Step 3: Diff against both tools**

Change line 64:

```powershell
$artifacts = @(Get-VSCodeProjectArtifacts -Project $Project -Roots $roots)
```

to:

```powershell
$artifacts = @(Get-ProjectArtifacts -Project $Project -Roots $roots)
```

Also update the `.SYNOPSIS` line 3 from `records every path VS Code writes under its own roots` to `records every path VS Code and Claude Code write under their own roots`.

- [ ] **Step 4: Syntax check**

Run:

```powershell
$e = $null; [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\vscode-discover.ps1), [ref]$null, [ref]$e) | Out-Null; "parse errors: $($e.Count)"
```

Expected: `parse errors: 0`

- [ ] **Step 5: Run the full suite**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests`
Expected: 0 failed.

- [ ] **Step 6: Commit**

```bash
git add vscode-discover.ps1
git commit -m "feat: discovery run also watches ~\.claude"
```

---

### Task 9: Docs and a real read-only check

**Files:**
- Modify: `README.md`, `HOWTO.md`

**Interfaces:**
- Consumes: the finished CLI.
- Produces: user-facing docs.

- [ ] **Step 1: Read-only check against real data**

This only reads; no `-Delete`. It needs a project on this machine that has Claude Code data: the `A` test folder if it still exists, otherwise any project listed under `~\.claude\projects`.

```powershell
.\vscode-cleanup.ps1 -Project "$env:USERPROFILE\A" -ReportPath "$env:TEMP\claude-check.txt"
Get-Content "$env:TEMP\claude-check.txt"
```

Expected: the report contains a `[claude:projects]` section with `~\.claude\projects\c--Users-<you>-A` as `(certain)`, plus `[claude:file-history]` / `[claude:session-env]` entries for its session IDs, and no path outside `~\.claude\projects`, `file-history`, `session-env` or the VS Code roots. If it shows anything else, stop and report it.

Then check a memory-only folder (5 exist on this machine, e.g. the `fps` project under `Dokumente\GitHub`):

```powershell
.\vscode-cleanup.ps1 -Project "$env:USERPROFILE\OneDrive\Dokumente\GitHub\fps" -ReportPath "$env:TEMP\claude-check2.txt"
Select-String -Path "$env:TEMP\claude-check2.txt" -Pattern 'claude:'
```

Expected: `[claude:projects]` with that folder marked `(probable)`.

- [ ] **Step 2: Update `README.md`**

1. Replace the intro paragraph (lines 6-8) with:

```markdown
Finds everything VS Code **and Claude Code** wrote **outside** a project folder on that
project's behalf — local file history, workspace storage, unsaved-buffer backups, window
logs, Claude Code chat transcripts, subagent transcripts, project memory and pre-edit file
copies — so a project can be deleted properly instead of leaving state behind forever.
```

2. In "## Flags", add a row after `-CodeRoot`:

```markdown
| `-ClaudeRoot <dir>` | Point at a different Claude Code data folder (default `~\.claude`). For testing. |
```

3. In "## certain vs probable", after the `probable` paragraph, add:

```markdown
For Claude Code, `certain` means a transcript inside the folder records the project as its
launch directory (`cwd`). `probable` is a `~\.claude\projects` folder with no transcript
left — usually just `memory\` — that matches only by its folder name. That name is lossy:
`A-B`, `A B` and `A\B` all become `...-A-B`, which is why it is never enough on its own.
```

4. In "## What it refuses to do", change the first bullet to:

```markdown
- **Won't delete outside the artifact folders.** Only VS Code's `workspaceStorage`,
  `History`, `Backups` and `logs`, and Claude Code's `projects`, `file-history` and
  `session-env`. Not `settings.json`, not `snippets`, not your extensions, not
  `~\.claude.json`, not your Claude login.
```

5. In "## What it does *not* touch", add at the end of the list:

```markdown
- **`~\.claude.json`** — one shared file with your Claude Code login, settings and one
  entry per project. Like `storage.json`, never edited per project.
- **Claude Code's shared folders** — `shell-snapshots`, `sessions`, `backups`, `plugins`,
  `skills`, `cache`, `ide`, `telemetry`.
- **`session-env` folders that belong to no transcript.** Most of them, on this machine.
  They can't be tied to a project.
```

6. In "## Warnings you may see", add:

```markdown
**"Claude Code is running in this project"**
A Claude Code session started in that folder (or below it) is still open. Quit it first;
it keeps writing its transcript.

**"is a parent of N separate Claude Code projects"**
Same as the VS Code warning, for Claude Code transcripts.
```

7. In "## vscode-discover.ps1", change `wait for \`Watching 2 root(s)\`` to `wait for \`Watching 3 root(s)\``.

- [ ] **Step 3: Update `HOWTO.md`**

1. Part 1, step 3: change `Wait for \`Watching 2 root(s).\`` to `Wait for \`Watching 3 root(s).\``.

2. Part 1, "Reading the gaps file" table: add these rows before the `**Anything else under \`User\`**` row:

```markdown
| `.claude\backups`, `.claude\plugins`, `.claude\cache`, `.claude\ide`, `.claude\sessions`, `.claude\shell-snapshots`, `.claude\.last-cleanup` | Claude Code's own shared state. **Ignore.** |
| `.claude\session-env\<id>` or `.claude\projects\<other>` of a *different* session | Another Claude Code session was running during the test (e.g. the one in this repo). **Ignore.** |
```

and change the last row's label from `**Anything else under \`User\`**` to `**Anything else under \`User\` or \`.claude\`**`.

3. Part 2, Step 1: change the heading to `## Step 1 — Quit VS Code and Claude Code completely`, and add after the first paragraph:

```markdown
Also quit any **Claude Code** session that was started in the project (or a folder inside
it). A running session keeps writing its transcript.

> **Heads-up:** this also deletes Claude Code's **memory** for that project
> (`~\.claude\projects\<project>\memory\`). If there's something in it you want to keep,
> copy it out first.
```

4. Part 2, Step 4, in the "What you're looking at" list, add:

```markdown
- **`claude:projects`** — Claude Code chat transcripts, subagent transcripts and project memory
- **`claude:file-history`** — Claude Code's copies of files from before it edited them
- **`claude:session-env`** — Claude Code per-session environment data
```

and change `Every one should sit under \`AppData\Roaming\Code\User\`` to `Every one should sit under \`AppData\Roaming\Code\User\` or \`.claude\``.

5. Part 2, Step 4, report example: change the first line `VS Code artifacts for project: D:\Nuxt\mastering-nuxt-3` to `Artifacts for project: D:\Nuxt\mastering-nuxt-3`.

- [ ] **Step 4: Check for personal paths**

Run: `git grep -n -i -e wildc -e robbyschmidt`
Expected: no output.

- [ ] **Step 5: Run the full suite one last time**

Run: `Import-Module Pester -RequiredVersion 3.4.0; Invoke-Pester -Script .\tests`
Expected: 0 failed; 130 tests (86 existing + 44 new: Task 1 7, Task 2 9, Task 3 9, Task 4 4, Task 5 5, Task 6 5, Task 7 5).

- [ ] **Step 6: Commit**

```bash
git add README.md HOWTO.md
git commit -m "docs: document Claude Code cleanup"
```
