# VS Code Project Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Given a project folder path, find and optionally delete every artifact VS Code wrote elsewhere on that project's behalf.

**Architecture:** A set of small dot-sourced PowerShell files under `src/`, each with one responsibility (URI normalization, root allowlist, source scanners, reporting, removal), wired together by two entry-point scripts at the repo root. Ownership of each artifact is resolved from the artifact's own metadata (`workspace.json`, `entries.json`), so the tool works retroactively on projects that were never tracked. A separate one-off discovery script validates that the resolver isn't missing anything.

**Tech Stack:** Windows PowerShell 5.1, Pester 3.4.0 (already installed at `C:\Program Files\WindowsPowerShell\Modules\Pester\3.4.0`), git.

**Spec:** `docs/superpowers/specs/2026-09-22-vscode-project-cleanup-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `src/VSCodeUri.ps1` | Windows path <-> VS Code `file://` URI conversion, descendant matching |
| `src/VSCodeRoots.ps1` | The VS Code root allowlist, and the "is this path safe to delete" check |
| `src/VSCodeSources.ps1` | The four source scanners + the orchestrator that combines them |
| `src/VSCodeReport.ps1` | Artifact sizes, grouping, report text and report file |
| `src/VSCodeRemove.ps1` | Deletion guardrails and the actual removal |
| `src/VSCodeDiff.ps1` | Diff between discovered writes and resolver output |
| `tests/TestHelpers.ps1` | Fixture builders shared by all test files |
| `tests/*.Tests.ps1` | One Pester file per `src/` file |
| `vscode-cleanup.ps1` | CLI entry point: parameters, wiring, console summary |
| `vscode-discover.ps1` | One-off FileSystemWatcher run + diff against the resolver |

**Data shape.** Every scanner returns zero or more records of this exact shape:

```powershell
[pscustomobject]@{
    Path       = 'C:\...\workspaceStorage\abc123'  # string, the directory to delete
    Source     = 'workspaceStorage'                # workspaceStorage | History | Backups | logs
    Confidence = 'certain'                         # certain | probable
    Hash       = 'abc123'                          # string or $null (logs)
}
```

`Add-ArtifactSize` later adds a `SizeBytes` ([int64]) property. No other properties exist anywhere in this codebase.

---

### Task 0: Repository setup

**Files:**
- Create: `.gitignore`
- Create: `src/` and `tests/` directories

- [ ] **Step 1: Initialize the repository**

```bash
cd "C:/Users/<you>/Desktop/Test"
git init
mkdir -p src tests
```

- [ ] **Step 2: Create `.gitignore`**

```
vscode-artifacts-*.txt
vscode-discover-*.log
vscode-discover-*.gaps.txt
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore docs
git commit -m "chore: initialize vscode cleanup project with spec and plan"
```

---

### Task 1: Convert a Windows path to a VS Code URI

VS Code stores `D:\Nuxt\foo` as `file:///d%3A/Nuxt/foo` — lowercased drive letter, forward slashes, and percent-encoding of everything outside the unreserved set `A-Za-z0-9-._~`.

See the spec's **Path normalization** section for why the rule is the full unreserved set rather than just colon-and-space: the live data on this machine contains 118 `%5B`/`%5D` escapes from Nuxt dynamic-route folders, and leaving `%` itself unencoded lets `C:\My%20Project` and `C:\My Project` collapse to the same URI — which, in a tool that deletes things, means purging the wrong project's artifacts.

**Files:**
- Create: `src/VSCodeUri.ps1`
- Test: `tests/VSCodeUri.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/VSCodeUri.Tests.ps1`:

```powershell
. "$PSScriptRoot\..\src\VSCodeUri.ps1"

Describe "ConvertTo-VSCodeUri" {
    It "converts a simple path" {
        ConvertTo-VSCodeUri -Path 'D:\Nuxt\foo' | Should Be 'file:///d%3A/Nuxt/foo'
    }
    It "lowercases the drive letter" {
        ConvertTo-VSCodeUri -Path 'C:\Temp' | Should Be 'file:///c%3A/Temp'
    }
    It "strips a trailing backslash" {
        ConvertTo-VSCodeUri -Path 'D:\Nuxt\foo\' | Should Be 'file:///d%3A/Nuxt/foo'
    }
    It "encodes spaces" {
        ConvertTo-VSCodeUri -Path 'C:\Users\Rob\My Project' | Should Be 'file:///c%3A/Users/Rob/My%20Project'
    }
    It "encodes square brackets from nuxt dynamic routes" {
        ConvertTo-VSCodeUri -Path 'D:\Nuxt\foo\pages\[id]\index.vue' |
            Should Be 'file:///d%3A/Nuxt/foo/pages/%5Bid%5D/index.vue'
    }
    It "encodes a literal percent so it cannot collide with an encoded space" {
        ConvertTo-VSCodeUri -Path 'C:\My%20Project' | Should Be 'file:///c%3A/My%2520Project'
        ConvertTo-VSCodeUri -Path 'C:\My%20Project' |
            Should Not Be (ConvertTo-VSCodeUri -Path 'C:\My Project')
    }
    It "encodes non-ascii as utf-8 bytes" {
        $p = 'C:\Gr' + [char]0x00FC + 'n'
        ConvertTo-VSCodeUri -Path $p | Should Be 'file:///c%3A/Gr%C3%BCn'
    }
    It "encodes a surrogate pair as one four-byte sequence" {
        $p = 'C:\p' + [char]0xD83D + [char]0xDE00 + 'q'
        ConvertTo-VSCodeUri -Path $p | Should Be 'file:///c%3A/p%F0%9F%98%80q'
    }
    It "accepts forward slashes" {
        ConvertTo-VSCodeUri -Path 'C:/foo/bar' | Should Be 'file:///c%3A/foo/bar'
    }
    It "keeps the trailing slash for a drive root" {
        ConvertTo-VSCodeUri -Path 'D:\' | Should Be 'file:///d%3A/'
    }
    It "throws on a UNC path" {
        { ConvertTo-VSCodeUri -Path '\\server\share\proj' } | Should Throw 'Only rooted drive paths'
    }
    It "throws on a relative path" {
        { ConvertTo-VSCodeUri -Path 'rel\proj' } | Should Throw 'Only rooted drive paths'
    }
    It "throws on a drive-relative path" {
        { ConvertTo-VSCodeUri -Path 'C:foo' } | Should Throw 'Only rooted drive paths'
    }
}
```

Three notes on these tests:

- The non-ASCII and surrogate-pair strings are built with `[char]` and bound to `$p` first. Writing `ConvertTo-VSCodeUri -Path 'C:\Gr' + [char]0x00FC + 'n'` does **not** work — PowerShell parses the `+` as trailing positional arguments and errors with "no positional parameter accepts argument '+'". Binding to `$p` avoids both that and any dependency on the file's own encoding surviving git's CRLF handling.
- The surrogate-pair case is the subtlest property of the encoder: iterating UTF-8 bytes of the whole string yields one correct 4-byte sequence, whereas the obvious per-`[char]` loop would split the pair into two 3-byte CESU-8 sequences. `U+1F600` must come out as `%F0%9F%98%80`.
- `Should Throw 'Only rooted drive paths'` pins the guard rather than the symptom. A bare `Should Throw` would still pass if the guard were deleted and `GetFullPath` happened to fail for an unrelated reason — which, for the UNC case, it plausibly would.

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeUri.Tests.ps1`
Expected: FAIL — `The term 'ConvertTo-VSCodeUri' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Create `src/VSCodeUri.ps1`:

```powershell
# Percent-encodes a URI path. Iterates UTF-8 bytes of the whole string, so a
# surrogate pair becomes one 4-byte sequence rather than two CESU-8 sequences.
function ConvertTo-UriPathEncoded {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $sb = New-Object System.Text.StringBuilder
    foreach ($byte in [System.Text.Encoding]::UTF8.GetBytes($Text)) {
        $c = [char]$byte
        if (($c -ge 'A' -and $c -le 'Z') -or ($c -ge 'a' -and $c -le 'z') -or
            ($c -ge '0' -and $c -le '9') -or '-._~/'.Contains($c)) {
            [void]$sb.Append($c)
        } else {
            [void]$sb.AppendFormat('%{0:X2}', $byte)
        }
    }

    $sb.ToString()
}

<#
.SYNOPSIS
    Converts a Windows path into the file:// URI form VS Code stores in its own metadata.

.DESCRIPTION
    Everything outside the unreserved set (A-Za-z0-9-._~) and the path separator is
    percent-encoded as UTF-8 bytes. This rule was validated by decoding all 2232 live
    file:// URIs under %APPDATA%\Code back to Windows paths, re-encoding them, and
    comparing: 0 mismatches. Only rooted drive paths are supported; UNC and relative
    paths throw, because silently producing a URI that matches nothing would make the
    tool report "no artifacts found" and look like success.

.EXAMPLE
    ConvertTo-VSCodeUri -Path 'D:\Nuxt\mastering-nuxt-3'
    file:///d%3A/Nuxt/mastering-nuxt-3
#>
function ConvertTo-VSCodeUri {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($Path -notmatch '^[A-Za-z]:[\\/]') {
        throw "Only rooted drive paths are supported (for example 'D:\Nuxt\foo'). Got: $Path"
    }

    $full  = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $drive = $full.Substring(0, 1).ToLowerInvariant()
    $rest  = ConvertTo-UriPathEncoded ($full.Substring(2) -replace '\\', '/')
    if (-not $rest) { $rest = '/' }   # bare drive root: VS Code writes file:///d%3A/

    "file:///$drive%3A$rest"
}
```

**The comment-based help block must sit immediately above `ConvertTo-VSCodeUri`, not above the helper.** PowerShell binds a `<#...#>` block to whatever function follows it. Put it above `ConvertTo-UriPathEncoded` and `Get-Help ConvertTo-VSCodeUri` returns nothing while the private helper gets an `.EXAMPLE` that calls a different function. That Description is the only place in code recording why UNC throws, so it has to hang off the public function.

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeUri.Tests.ps1`
Expected: PASS, 13 of 13

Then confirm the help landed on the right function:

Run: `. .\src\VSCodeUri.ps1; (Get-Help ConvertTo-VSCodeUri).Synopsis`
Expected: the synopsis text, not an empty line

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeUri.ps1 tests/VSCodeUri.Tests.ps1
git commit -m "feat: convert windows paths to vscode file URIs"
```

---

### Task 2: Match a URI against a project

History entries point at individual files, so `file:///d%3A/Nuxt/foo/components/X.vue` belongs to project `foo`. The trap to avoid: `file:///d%3A/Nuxt/foobar` must NOT match project `foo`.

This trap is not hypothetical on this machine. `D:\Nuxt\mastering-nuxt-3` coexists with `mastering-nuxt-3-main`, `mastering-nuxt-3 fixed`, `mastering-nuxt-3 4.3`, `mastering-nuxt-3 4.6` and `mastering-nuxt-3 - Kopie`, so the fixtures below use those real names instead of `foo`/`foobar`.

**Files:**
- Modify: `src/VSCodeUri.ps1`
- Test: `tests/VSCodeUri.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `tests/VSCodeUri.Tests.ps1`:

```powershell
Describe "Test-UriUnderProject" {
    $project = 'file:///d%3A/Nuxt/mastering-nuxt-3'

    It "matches the project itself" {
        Test-UriUnderProject -Uri $project -ProjectUri $project | Should Be $true
    }
    It "matches a file inside the project" {
        Test-UriUnderProject -Uri "$project/components/X.vue" -ProjectUri $project | Should Be $true
    }
    It "does not match a sibling with the same prefix" {
        Test-UriUnderProject -Uri 'file:///d%3A/Nuxt/mastering-nuxt-3-main' -ProjectUri $project | Should Be $false
    }
    It "does not match a sibling whose extra characters are encoded" {
        Test-UriUnderProject -Uri 'file:///d%3A/Nuxt/mastering-nuxt-3%20fixed' -ProjectUri $project | Should Be $false
        Test-UriUnderProject -Uri 'file:///d%3A/Nuxt/mastering-nuxt-3%20-%20Kopie' -ProjectUri $project | Should Be $false
    }
    It "does not match an unrelated path" {
        Test-UriUnderProject -Uri 'file:///c%3A/other' -ProjectUri $project | Should Be $false
    }
    It "does not match a different uri scheme" {
        Test-UriUnderProject -Uri 'vscode-userdata:/c%3A/Users/x/settings.json' -ProjectUri $project | Should Be $false
    }
    It "ignores case" {
        Test-UriUnderProject -Uri 'file:///D%3A/NUXT/MASTERING-NUXT-3/a.txt' -ProjectUri $project | Should Be $true
    }
    It "matches when the project uri has a trailing slash" {
        Test-UriUnderProject -Uri $project -ProjectUri "$project/" | Should Be $true
        Test-UriUnderProject -Uri "$project/components/X.vue" -ProjectUri "$project/" | Should Be $true
    }
    It "matches when the stored uri has a trailing slash" {
        Test-UriUnderProject -Uri "$project/" -ProjectUri $project | Should Be $true
    }
    It "does not match the parent directory" {
        Test-UriUnderProject -Uri 'file:///d%3A/Nuxt' -ProjectUri $project | Should Be $false
    }
}
```

The `vscode-userdata:` case is not invented — one live entry under `%APPDATA%\Code` uses that scheme instead of `file:`, and it must not match any project.

The three trailing-slash and parent-directory tests exist because mutation testing showed `TrimEnd('/')` could be deleted outright with the original seven tests still passing — it was the one line the suite did not pin.

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeUri.Tests.ps1`
Expected: FAIL — `The term 'Test-UriUnderProject' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Append to `src/VSCodeUri.ps1`:

```powershell
<#
.SYNOPSIS
    Decides whether a stored VS Code URI belongs to a project.

.DESCRIPTION
    This is the boundary that decides what gets deleted, so two non-obvious details
    are deliberate.

    The exact-match branch is load-bearing, not decoration. A workspace's own 'folder'
    URI *is* the project URI, so every workspaceStorage hit goes through it; the '/'
    boundary alone would reject all of them.

    The trailing '/' on the prefix is the whole point of the function. Without it,
    project 'mastering-nuxt-3' would swallow the sibling 'mastering-nuxt-3-main' --
    and five such siblings exist in this machine's live metadata.

    Both comparisons use OrdinalIgnoreCase, and both sides are trimmed so the
    trailing-slash contract is symmetric. Case-insensitivity is here because Windows
    paths are case-insensitive; that it also makes a lowercase '%3a' compare equal to
    '%3A' is a harmless side effect, not the intent -- do not "fix" these to
    case-sensitive comparisons. Dot segments are not normalized, because VS Code
    normalizes before writing and no live URI contains '/../'.

.EXAMPLE
    Test-UriUnderProject -Uri 'file:///d%3A/Nuxt/foo/components/X.vue' -ProjectUri 'file:///d%3A/Nuxt/foo'
    True
#>
function Test-UriUnderProject {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    $cmp     = [System.StringComparison]::OrdinalIgnoreCase
    $project = $ProjectUri.TrimEnd('/')

    if ($Uri.TrimEnd('/').Equals($project, $cmp)) { return $true }

    return $Uri.StartsWith($project + '/', $cmp)
}
```

Both sides are trimmed rather than only the project side. The original one-sided form left an asymmetry — `Uri='…/foo'` with `ProjectUri='…/foo/'` returned `$false` when it should be `$true` — because the equality branch compared raw strings before any normalization. Using `.Equals(..., OrdinalIgnoreCase)` rather than `-eq` also makes both comparisons the same comparison; `-eq` is invariant-culture and therefore linguistic, which treats zero-width and soft-hyphen code points as equal when an ordinal comparison would not. Unreachable today, but it errs toward a false positive in a tool that deletes.

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeUri.Tests.ps1`
Expected: PASS, 23 of 23 (13 from Task 1 plus 10 here)

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeUri.ps1 tests/VSCodeUri.Tests.ps1
git commit -m "feat: match uris against a project root without prefix collisions"
```

---

### Task 3: VS Code roots and the deletion guardrail

`Get-VSCodeRoots` is parameterized so tests can point it at a fixture directory instead of the real `%APPDATA%\Code`.

**Files:**
- Create: `src/VSCodeRoots.ps1`
- Test: `tests/VSCodeRoots.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/VSCodeRoots.Tests.ps1`:

```powershell
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
```

The last four tests exist because mutation testing on the original six found that 11 of 23 mutants survived. Most importantly, removing `[System.IO.Path]::GetFullPath($Path)` — the single line standing between this tool and `C:\Windows\System32` — left the whole suite green. The traversal, trailing-separator, case and forward-slash tests each pin one of those mutants.

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeRoots.Tests.ps1`
Expected: FAIL — `The term 'Get-VSCodeRoots' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Create `src/VSCodeRoots.ps1`:

```powershell
function Get-VSCodeRoots {
    param(
        [string]$CodeRoot    = (Join-Path $env:APPDATA 'Code'),
        [string]$UserProfile = $env:USERPROFILE
    )

    [pscustomobject]@{
        CodeRoot         = $CodeRoot
        WorkspaceStorage = Join-Path $CodeRoot 'User\workspaceStorage'
        History          = Join-Path $CodeRoot 'User\History'
        Backups          = Join-Path $CodeRoot 'Backups'
        Logs             = Join-Path $CodeRoot 'logs'
        DotVscode        = Join-Path $UserProfile '.vscode'
    }
}

# Allowlists only the four roots the scanners actually emit from -- NOT CodeRoot wholesale.
# Permitting all of %APPDATA%\Code would also permit deleting User\settings.json, snippets,
# Preferences and machineid, none of which any scanner can produce. A scanner bug that
# emitted a parent directory would then pass validation and Remove-Item -Recurse would take
# shared state with it. .vscode is deliberately absent: it is a discovery watch target
# (Task 15), never a deletion source. A future scanner that needs a new root must add it
# here deliberately rather than inherit deletion rights.
#
# Lexical check only. GetFullPath normalizes '.', '..', slashes and 8.3 short names, but it
# does NOT resolve NTFS reparse points -- a junction inside a root still reads as "inside"
# even though it points elsewhere. Resolving link targets needs P/Invoke on PowerShell 5.1,
# and this function must also work on fixture paths that do not exist on disk, so the
# reparse-point guard lives in Remove-VSCodeArtifacts (Task 12), where deletion happens.
function Test-PathUnderArtifactRoots {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Roots
    )

    $cmp       = [System.StringComparison]::OrdinalIgnoreCase
    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')

    foreach ($root in @($Roots.WorkspaceStorage, $Roots.History, $Roots.Backups, $Roots.Logs)) {
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
        # Explicit for intent; subsumed by the separator in the StartsWith below.
        if ($candidate.Equals($r, $cmp)) { return $false }
        if ($candidate.StartsWith($r + '\', $cmp)) { return $true }
    }

    return $false
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeRoots.Tests.ps1`
Expected: PASS, 12 of 12

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeRoots.ps1 tests/VSCodeRoots.Tests.ps1
git commit -m "feat: add vscode root allowlist and deletion guardrail"
```

---

### Task 4: Test fixture builder

Every scanner test needs a fake `%APPDATA%\Code` tree. Build it once, use it everywhere.

**Files:**
- Create: `tests/TestHelpers.ps1`
- Test: `tests/TestHelpers.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/TestHelpers.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\TestHelpers.Tests.ps1`
Expected: FAIL — `The term 'New-FakeCodeRoot' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Create `tests/TestHelpers.ps1`:

```powershell
function New-FakeCodeRoot {
    param([Parameter(Mandatory = $true)][string]$Parent)

    $root = Join-Path $Parent ('Code-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    foreach ($sub in @('User\workspaceStorage', 'User\History', 'Backups', 'logs')) {
        New-Item -Path (Join-Path $root $sub) -ItemType Directory -Force | Out-Null
    }
    $root
}

function Add-FakeWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Hash,
        [string]$FolderUri,
        [string]$WorkspaceUri,
        [string]$RawJson
    )

    $dir = Join-Path $CodeRoot "User\workspaceStorage\$Hash"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'placeholder' | Out-File -FilePath (Join-Path $dir 'state.vscdb') -Encoding utf8

    $json = if ($PSBoundParameters.ContainsKey('RawJson')) { $RawJson }
            elseif ($FolderUri)    { (@{ folder    = $FolderUri }    | ConvertTo-Json) }
            else                   { (@{ workspace = $WorkspaceUri } | ConvertTo-Json) }

    $json | Out-File -FilePath (Join-Path $dir 'workspace.json') -Encoding utf8
    $dir
}

function Add-FakeHistory {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Hash,
        [Parameter(Mandatory = $true)][string]$ResourceUri
    )

    $dir = Join-Path $CodeRoot "User\History\$Hash"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'old content' | Out-File -FilePath (Join-Path $dir 'aaaa.vue') -Encoding utf8
    @{ version = 1; resource = $ResourceUri; entries = @() } |
        ConvertTo-Json | Out-File -FilePath (Join-Path $dir 'entries.json') -Encoding utf8
    $dir
}

function Add-FakeBackup {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Hash
    )

    $dir = Join-Path $CodeRoot "Backups\$Hash"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    'unsaved' | Out-File -FilePath (Join-Path $dir 'file1') -Encoding utf8
    $dir
}

function Add-FakeLog {
    param(
        [Parameter(Mandatory = $true)][string]$CodeRoot,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Window,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $dir = Join-Path $CodeRoot "logs\$Session\$Window"
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    $Content | Out-File -FilePath (Join-Path $dir 'renderer.log') -Encoding utf8
    $dir
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\TestHelpers.Tests.ps1`
Expected: PASS, 3 of 3

- [ ] **Step 5: Commit**

```bash
git add tests/TestHelpers.ps1 tests/TestHelpers.Tests.ps1
git commit -m "test: add fake vscode code root fixture builder"
```

---

### Task 5: Scan workspaceStorage

**Files:**
- Create: `src/VSCodeSources.ps1`
- Test: `tests/VSCodeSources.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/VSCodeSources.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: FAIL — `The term 'Get-WorkspaceStorageArtifacts' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Create `src/VSCodeSources.ps1`:

```powershell
function Get-WorkspaceStorageArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path $Roots.WorkspaceStorage)) { return @() }

    Get-ChildItem -Path $Roots.WorkspaceStorage -Directory | ForEach-Object {
        $meta = Join-Path $_.FullName 'workspace.json'
        if (-not (Test-Path $meta)) { return }

        try {
            $json = Get-Content -LiteralPath $meta -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            Write-Warning "Skipping unreadable $meta"
            return
        }

        $uri = if ($json.folder) { $json.folder } elseif ($json.workspace) { $json.workspace } else { $null }
        if ($uri -and (Test-UriUnderProject -Uri $uri -ProjectUri $ProjectUri)) {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'workspaceStorage'
                Confidence = 'certain'
                Hash       = $_.Name
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: PASS, 4 of 4

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeSources.ps1 tests/VSCodeSources.Tests.ps1
git commit -m "feat: resolve workspaceStorage folders to their project"
```

---

### Task 6: Scan History

**Files:**
- Modify: `src/VSCodeSources.ps1`
- Test: `tests/VSCodeSources.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `tests/VSCodeSources.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: FAIL — `The term 'Get-HistoryArtifacts' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Append to `src/VSCodeSources.ps1`:

```powershell
function Get-HistoryArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path $Roots.History)) { return @() }

    Get-ChildItem -Path $Roots.History -Directory | ForEach-Object {
        $meta = Join-Path $_.FullName 'entries.json'
        if (-not (Test-Path $meta)) { return }

        try {
            $json = Get-Content -LiteralPath $meta -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            Write-Warning "Skipping unreadable $meta"
            return
        }

        if ($json.resource -and (Test-UriUnderProject -Uri $json.resource -ProjectUri $ProjectUri)) {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'History'
                Confidence = 'certain'
                Hash       = $_.Name
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: PASS, 6 of 6

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeSources.ps1 tests/VSCodeSources.Tests.ps1
git commit -m "feat: resolve local history folders to their project"
```

---

### Task 7: Scan Backups

Backup folders are keyed by the same hash as the workspaceStorage folder, so they are matched indirectly.

**Files:**
- Modify: `src/VSCodeSources.ps1`
- Test: `tests/VSCodeSources.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `tests/VSCodeSources.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: FAIL — `The term 'Get-BackupArtifacts' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Append to `src/VSCodeSources.ps1`:

```powershell
function Get-BackupArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [AllowEmptyCollection()][string[]]$WorkspaceHashes = @()
    )

    if ($WorkspaceHashes.Count -eq 0)    { return @() }
    if (-not (Test-Path $Roots.Backups)) { return @() }

    Get-ChildItem -Path $Roots.Backups -Directory |
        Where-Object { $WorkspaceHashes -contains $_.Name } |
        ForEach-Object {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'Backups'
                Confidence = 'certain'
                Hash       = $_.Name
            }
        }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: PASS, 8 of 8

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeSources.ps1 tests/VSCodeSources.Tests.ps1
git commit -m "feat: match backup folders via workspace hash"
```

---

### Task 8: Scan logs

Logs are keyed by session timestamp, not project, so ownership is inferred from the log text. These are marked `probable`.

**Files:**
- Modify: `src/VSCodeSources.ps1`
- Test: `tests/VSCodeSources.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `tests/VSCodeSources.Tests.ps1`:

```powershell
Describe "Get-LogArtifacts" {
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
```

A real window directory holds `renderer.log`, `network.log`, `views.log` and friends directly, plus `exthost\` and `output_logging_*\` subdirectories that also contain `file://` URIs. On this machine every project URI happens to appear in `renderer.log`, so a non-recursive file listing gets the right answer today — but that is an unstated assumption about VS Code's logging, and recursing costs 0.31s across all 394 log files. The whole window directory is what gets deleted either way.

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: FAIL — `The term 'Get-LogArtifacts' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Append to `src/VSCodeSources.ps1`:

```powershell
function Get-LogArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Roots,
        [Parameter(Mandatory = $true)][string]$ProjectUri
    )

    if (-not (Test-Path $Roots.Logs)) { return @() }

    Get-ChildItem -Path $Roots.Logs -Directory -Recurse -Filter 'window*' | ForEach-Object {
        # NOT -SimpleMatch. A project URI is a prefix of its own siblings, so a bare
        # substring match hands back 'mastering-nuxt-3-main' and 'mastering-nuxt-3%20fixed'
        # as artifacts of 'mastering-nuxt-3' -- the exact collision Test-UriUnderProject
        # exists to prevent. The lookahead requires the next character to be one that
        # cannot continue a folder name: '/' and delimiters pass, name characters do not.
        #
        # -Recurse: a window dir also holds exthost\ and output_logging_*\ subdirectories
        # that contain file:// URIs. The whole window dir is the artifact either way.
        $pattern = [regex]::Escape($ProjectUri) + '(?![A-Za-z0-9\-._~%])'
        $hit = Get-ChildItem -Path $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
               Select-String -Pattern $pattern -List -ErrorAction SilentlyContinue

        if ($hit) {
            [pscustomobject]@{
                Path       = $_.FullName
                Source     = 'logs'
                Confidence = 'probable'
                Hash       = $null
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: PASS, 13 of 13

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeSources.ps1 tests/VSCodeSources.Tests.ps1
git commit -m "feat: match window log folders that reference the project"
```

---

### Task 9: Combine the scanners

**Files:**
- Modify: `src/VSCodeSources.ps1`
- Test: `tests/VSCodeSources.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `tests/VSCodeSources.Tests.ps1`:

```powershell
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
```

The second of those two matters as much as the first: one project legitimately owns many `workspaceStorage` folders (`mastering-nuxt-3` has 8 on this machine, one per time it was reopened). Warning on artifact *count* would fire constantly; warning on distinct *owners* fires exactly when the path spans more than one project.

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: FAIL — `The term 'Get-VSCodeProjectArtifacts' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Append to `src/VSCodeSources.ps1`:

```powershell
function Get-VSCodeProjectArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        $Roots = (Get-VSCodeRoots)
    )

    $uri = ConvertTo-VSCodeUri -Path $Project

    # A drive root is not a project. ConvertTo-VSCodeUri legitimately renders 'D:\' as
    # file:///d%3A/, which as a prefix matches every artifact on that drive -- so -Delete
    # would purge the VS Code history of every project on D: in one invocation.
    #
    # Guard the NORMALIZED URI, not the raw input. A lexical regex on $Project misses
    # 'D:\\', 'D:\.', 'D:\..' and 'D:\ ' (trailing space), all of which GetFullPath
    # collapses to exactly the same whole-drive URI. ('D:' with no separator never gets
    # here -- ConvertTo-VSCodeUri rejects it as not rooted.)
    if ($uri -match '^file:///[a-z]%3A/?$') {
        throw "A drive root is not a project: $Project"
    }

    # Characters proven against the live data: letters, digits, - . _ ~ / \ [ ] and space.
    # Anything else is encoded by a rule no live URI exercises. If VS Code happens to write
    # it differently, nothing matches, the run reports "no artifacts found", and the user
    # deletes the project believing it was clean. Warn rather than quietly guess.
    # Inspect the NORMALIZED path, for the same reason the guard above does. GetFullPath
    # expands 8.3 short names when the path exists, so 'C:\Users\ROBBYS~1\My+Co' and its
    # long form produce one URI but only the long form contains the '+' -- reading $Project
    # raw would stay silent in exactly the case this warning exists for. It also stops
    # 'D:\@scratch\..\Nuxt\foo' warning about an '@' that the resolved URI never contains.
    $unverified = ([System.IO.Path]::GetFullPath($Project)).Substring(2) -replace '[A-Za-z0-9\-._~/\\\[\] ]', ''
    if ($unverified) {
        Write-Warning ("Project path contains character(s) that appear nowhere in this machine's " +
                       "VS Code data: $unverified -- their URI encoding is unverified, so artifacts " +
                       "may be missed. Review the report before using -Delete.")
    }

    $workspaces = @(Get-WorkspaceStorageArtifacts -Roots $Roots -ProjectUri $uri)

    # A parent directory is a legitimate project -- this machine has Desktop registered as
    # a VS Code workspace in its own right -- but resolving one sweeps in every project
    # nested beneath it. Measured here: 'D:\Nuxt' returns artifacts belonging to 53
    # distinct projects, 'C:\Users\...\Documents\GitHub' to 68. Deleting a parent folder
    # genuinely does mean deleting all of them, so this warns rather than refuses. The
    # artifact count alone does not convey it: "Found 343 artifact(s)" reads like a big
    # project, not like 52 separate ones.
    $owners = @($workspaces | ForEach-Object {
        try {
            $j = Get-Content -LiteralPath (Join-Path $_.Path 'workspace.json') -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($j.folder) { $j.folder } else { $j.workspace }
        } catch { }
    } | Sort-Object -Unique)
    if ($owners.Count -gt 1) {
        Write-Warning ("'$Project' is a parent of $($owners.Count) separate VS Code projects. " +
                       "These artifacts belong to all of them, not to one project. " +
                       "Review the report before using -Delete.")
    }

    $history    = @(Get-HistoryArtifacts          -Roots $Roots -ProjectUri $uri)
    $hashes     = @($workspaces | ForEach-Object { $_.Hash })
    $backups    = @(Get-BackupArtifacts           -Roots $Roots -WorkspaceHashes $hashes)
    $logs       = @(Get-LogArtifacts              -Roots $Roots -ProjectUri $uri)

    @($workspaces + $history + $backups + $logs)
}
```

**Return contract.** This emits to the pipeline, so PowerShell unrolls it: with no artifacts the caller receives `$null`, and with exactly one it receives a bare object whose `.Count` is `$null`. The `@()` on the final line does not change that. Every call site must therefore wrap: `@(Get-VSCodeProjectArtifacts ...)`. Tasks 13 and 15 both do. The test is named "returns nothing" rather than "returns an empty array" because the latter would have been untrue — and untestable, since the test does its own wrapping.

**On performance.** A real run takes about 5.7s, and the breakdown is not where you would guess: History is 4.6s (1977 `ConvertFrom-Json` calls), workspaceStorage 0.6s, logs 0.44s, Backups 0.03s. The recursive log scan is 8% of the run, so do not make it opt-in to save time. Replacing the History JSON parse with a regex over the raw text measures ~1.6s instead of 4.6s, but trades a real parser for pattern-matching in a tool that deletes; not worth it at this scale.

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeSources.Tests.ps1`
Expected: PASS, 21 of 21

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeSources.ps1 tests/VSCodeSources.Tests.ps1
git commit -m "feat: combine all artifact sources for a project"
```

---

### Task 10: Artifact sizes

**Files:**
- Create: `src/VSCodeReport.ps1`
- Test: `tests/VSCodeReport.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/VSCodeReport.Tests.ps1`:

```powershell
. "$PSScriptRoot\..\src\VSCodeReport.ps1"

Describe "Add-ArtifactSize" {
    It "sums the bytes under the artifact path" {
        $dir = Join-Path $TestDrive 'artifact1'
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'a.bin'), (New-Object byte[] 100))
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'b.bin'), (New-Object byte[] 50))

        $artifact = [pscustomobject]@{ Path = $dir; Source = 'History'; Confidence = 'certain'; Hash = 'x' }
        $result   = $artifact | Add-ArtifactSize

        $result.SizeBytes | Should Be 150
    }

    It "reports zero for a path that no longer exists" {
        $artifact = [pscustomobject]@{ Path = (Join-Path $TestDrive 'gone'); Source = 'History'; Confidence = 'certain'; Hash = 'x' }
        ($artifact | Add-ArtifactSize).SizeBytes | Should Be 0
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeReport.Tests.ps1`
Expected: FAIL — `The term 'Add-ArtifactSize' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Create `src/VSCodeReport.ps1`:

```powershell
function Add-ArtifactSize {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, ValueFromPipeline = $true)]$Artifact)

    process {
        $bytes = 0
        if (Test-Path -LiteralPath $Artifact.Path) {
            $sum = (Get-ChildItem -LiteralPath $Artifact.Path -Recurse -File -Force -ErrorAction SilentlyContinue |
                    Measure-Object -Property Length -Sum).Sum
            if ($sum) { $bytes = $sum }
        }

        $Artifact | Add-Member -NotePropertyName SizeBytes -NotePropertyValue ([int64]$bytes) -Force -PassThru
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeReport.Tests.ps1`
Expected: PASS, 2 of 2

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeReport.ps1 tests/VSCodeReport.Tests.ps1
git commit -m "feat: compute artifact sizes on disk"
```

---

### Task 11: Report text and report file

**Files:**
- Modify: `src/VSCodeReport.ps1`
- Test: `tests/VSCodeReport.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Append to `tests/VSCodeReport.Tests.ps1`:

```powershell
Describe "Format-ArtifactReport" {
    $artifacts = @(
        [pscustomobject]@{ Path = 'C:\a\ws1';  Source = 'workspaceStorage'; Confidence = 'certain';  Hash = 'ws1'; SizeBytes = [int64]1000 },
        [pscustomobject]@{ Path = 'C:\a\h1';   Source = 'History';          Confidence = 'certain';  Hash = 'h1';  SizeBytes = [int64]500  },
        [pscustomobject]@{ Path = 'C:\a\log1'; Source = 'logs';             Confidence = 'probable'; Hash = $null; SizeBytes = [int64]250  }
    )

    It "names the project" {
        (Format-ArtifactReport -Artifacts $artifacts -Project 'D:\Nuxt\foo') | Should Match 'D:\\Nuxt\\foo'
    }
    It "lists every artifact path" {
        $text = Format-ArtifactReport -Artifacts $artifacts -Project 'D:\Nuxt\foo'
        $text | Should Match 'C:\\a\\ws1'
        $text | Should Match 'C:\\a\\h1'
        $text | Should Match 'C:\\a\\log1'
    }
    It "reports the grand total in bytes" {
        (Format-ArtifactReport -Artifacts $artifacts -Project 'D:\Nuxt\foo') | Should Match 'TOTAL: 1750 bytes'
    }
    It "handles an empty artifact set" {
        (Format-ArtifactReport -Artifacts @() -Project 'D:\Nuxt\foo') | Should Match 'No artifacts found'
    }
}

Describe "Write-ArtifactReport" {
    It "writes the report and returns its path" {
        $artifacts = @([pscustomobject]@{ Path = 'C:\a\ws1'; Source = 'workspaceStorage'; Confidence = 'certain'; Hash = 'ws1'; SizeBytes = [int64]1000 })
        $target    = Join-Path $TestDrive 'report.txt'

        $returned = Write-ArtifactReport -Artifacts $artifacts -Project 'D:\Nuxt\foo' -ReportPath $target

        $returned                  | Should Be $target
        Test-Path $target          | Should Be $true
        (Get-Content $target -Raw) | Should Match 'C:\\a\\ws1'
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeReport.Tests.ps1`
Expected: FAIL — `The term 'Format-ArtifactReport' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Append to `src/VSCodeReport.ps1`:

```powershell
function Format-ArtifactReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)][string]$Project
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("VS Code artifacts for project: $Project")
    $lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('')

    if ($Artifacts.Count -eq 0) {
        $lines.Add('No artifacts found.')
        return ($lines -join [Environment]::NewLine)
    }

    foreach ($group in ($Artifacts | Group-Object Source | Sort-Object Name)) {
        $groupTotal = ($group.Group | Measure-Object -Property SizeBytes -Sum).Sum
        $lines.Add("[$($group.Name)] $($group.Count) item(s), $groupTotal bytes")
        foreach ($a in $group.Group) {
            $lines.Add("  ($($a.Confidence)) $($a.SizeBytes) bytes  $($a.Path)")
        }
        $lines.Add('')
    }

    $total = ($Artifacts | Measure-Object -Property SizeBytes -Sum).Sum
    $lines.Add("TOTAL: $total bytes across $($Artifacts.Count) artifact(s)")

    $lines -join [Environment]::NewLine
}

function Write-ArtifactReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$ReportPath
    )

    # -WhatIf:$false is deliberate. $WhatIfPreference propagates into Out-File, so under
    # the CLI's -WhatIf the report would silently not be written while the CLI still
    # printed "Report: <path>" -- naming a file that does not exist. The report is the
    # output of a read, not a destructive act: previewing a deletion should still produce
    # the document you review before committing to it.
    Format-ArtifactReport -Artifacts $Artifacts -Project $Project |
        Out-File -FilePath $ReportPath -Encoding utf8 -WhatIf:$false

    $ReportPath
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeReport.Tests.ps1`
Expected: PASS, 7 of 7

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeReport.ps1 tests/VSCodeReport.Tests.ps1
git commit -m "feat: format and write the artifact report"
```

---

### Task 12: Deletion with guardrails

All paths are validated **before** anything is deleted, so a bad entry can never leave a half-purged state.

**Files:**
- Create: `src/VSCodeRemove.ps1`
- Test: `tests/VSCodeRemove.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/VSCodeRemove.Tests.ps1`:

```powershell
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
```

Seven tests were added after mutation testing showed the original five left eight mutants alive. The pattern was consistent: the four guardrails *named* in the plan were well defended, while the implementation details that make them work — the top-level reparse attribute check, `-Force` on both the scan and the delete, `-Recurse` on the scan, and the fail-closed `throw` — could each be deleted with a green suite. Three of those had a demonstrated behavioural difference on real fixtures, so they were not equivalent mutants.

Two survivors are deliberately left unpinned: `-ErrorVariable +errors` (the `+` is redundant because `$errors` is function-local, so removing it changes nothing) and `-ErrorAction Stop` on the `Get-Item` (the `Test-Path` above already ran).

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeRemove.Tests.ps1`
Expected: FAIL — `The term 'Remove-VSCodeArtifacts' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Create `src/VSCodeRemove.ps1`:

```powershell
# 'Code - Insiders' is a separate process name; a user running Insiders would otherwise
# be told nothing is running while it holds files open.
function Test-VSCodeRunning {
    [bool](Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue)
}

# Test-PathUnderArtifactRoots is lexical and cannot see that a junction inside a root
# points outside it. Recursive delete has historically followed such links and destroyed
# the target's contents; it does not reproduce on every build, and is not contractually
# guaranteed either way -- do not remove this guard on the strength of one build behaving.
# Detecting a reparse point is cheap; resolving its target needs P/Invoke, so refuse
# rather than resolve. Refusing costs one un-deleted artifact; resolving wrongly costs data.
#
# This must fail CLOSED: if any subtree cannot be enumerated (ACL denial, or a path past
# MAX_PATH -- LongPathsEnabled is 0 on this machine while VS Code, being Node, writes
# beyond it) we refuse rather than assume it was clean. Refuse when you could not look,
# exactly as you refuse when you found one.
function Test-PathHasReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return $true }

    $errors = @()
    $found  = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +errors |
              Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
              Select-Object -First 1

    if ($errors.Count -gt 0) {
        throw "Could not fully inspect $Path for junctions ($($errors.Count) unreadable item(s)); refusing to delete it."
    }

    return [bool]$found
}

function Remove-VSCodeArtifacts {
    # SupportsShouldProcess gives the project's only destructive function the idiomatic
    # -WhatIf. It also fixes a false success report: without it, running with
    # $WhatIfPreference = $true in scope made the inner Remove-Item a silent no-op while
    # this function still emitted $t, so the CLI printed "Deleted 1 artifact(s)" having
    # deleted nothing. No ConfirmImpact: raising it to High would prompt on every call
    # and hang non-interactive runs.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts,
        [Parameter(Mandatory = $true)]$Roots,
        [switch]$IncludeProbable
    )

    # -ceq, not -eq: PowerShell's -eq is case-insensitive, so 'Certain' would be swept as
    # though it were 'certain'. Unknown casing now falls to the safe side and is skipped.
    $targets = @($Artifacts | Where-Object { $IncludeProbable -or $_.Confidence -ceq 'certain' })

    # Validate every target before deleting any of them. This ordering exists so a bad
    # entry cannot leave a half-purged state -- it is NOT a TOCTOU defence, and should not
    # be reasoned about as one. Swapping an artifact for a junction between the two loops
    # needs write access to %APPDATA%\Code under the same user token, which already grants
    # everything the tool could be tricked into doing. No privilege boundary is crossed.
    foreach ($t in $targets) {
        if (-not (Test-PathUnderArtifactRoots -Path $t.Path -Roots $Roots)) {
            throw "Refusing to delete path outside the VS Code roots: $($t.Path)"
        }
        if (Test-PathHasReparsePoint -Path $t.Path) {
            throw "Refusing to delete a tree containing a junction or symlink: $($t.Path)"
        }
    }

    # A single failure (locked file, already gone) must not abort the rest.
    foreach ($t in $targets) {
        if (-not $PSCmdlet.ShouldProcess($t.Path, 'Delete VS Code artifact')) { continue }
        try {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction Stop
            $t
        } catch {
            Write-Warning "Could not delete $($t.Path): $($_.Exception.Message)"
        }
    }
}
```

**On `-Force` and `-Recurse`.** Both appear twice and both are load-bearing, so the tests below pin each occurrence. `Remove-Item -Force` is what lets a tree containing a read-only file be deleted at all — real VS Code state contains them. `Get-ChildItem -Force` in the reparse scan is what makes a *hidden* junction visible; without it the guard silently finds nothing, which is a fail-open hiding inside a fail-closed check. `Get-ChildItem -Recurse` is what finds a junction below the top level.

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeRemove.Tests.ps1`
Expected: PASS, 12 of 12

- [ ] **Step 5: Commit**

```bash
git add src/VSCodeRemove.ps1 tests/VSCodeRemove.Tests.ps1
git commit -m "feat: remove artifacts behind allowlist and confidence guardrails"
```

---

### Task 13: CLI entry point

**Files:**
- Create: `vscode-cleanup.ps1`

- [ ] **Step 1: Write the script**

Create `vscode-cleanup.ps1`:

```powershell
<#
.SYNOPSIS
    Finds (and optionally deletes) everything VS Code wrote outside a project folder
    on that project's behalf.

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
    [string]$CodeRoot
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\src\VSCodeUri.ps1"
. "$PSScriptRoot\src\VSCodeRoots.ps1"
. "$PSScriptRoot\src\VSCodeSources.ps1"
. "$PSScriptRoot\src\VSCodeReport.ps1"
. "$PSScriptRoot\src\VSCodeRemove.ps1"

$roots     = if ($CodeRoot) { Get-VSCodeRoots -CodeRoot $CodeRoot } else { Get-VSCodeRoots }
$artifacts = @(Get-VSCodeProjectArtifacts -Project $Project -Roots $roots | Add-ArtifactSize)

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

$removed = @(Remove-VSCodeArtifacts -Artifacts $artifacts -Roots $roots -IncludeProbable:$IncludeProbable)
Write-Host "Deleted $($removed.Count) artifact(s)."
```

- [ ] **Step 2: Write the CLI tests**

Create `tests/Cli.Tests.ps1`. These run the real script end to end against a fixture — the `-CodeRoot` seam is what makes that possible.

```powershell
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
```

- [ ] **Step 3: Run the tests**

Run: `Invoke-Pester -Script .\tests\Cli.Tests.ps1`
Expected: PASS, 5 of 5

Then the whole suite: `Invoke-Pester -Script .\tests`
Expected: PASS, 83 of 83

- [ ] **Step 4: Verify it runs against a project that has no artifacts**

Run: `.\vscode-cleanup.ps1 -Project 'D:\Nuxt\does-not-exist'`
Expected: `Found 0 artifact(s), 0 MB`, a report path, and `Nothing was deleted.`

- [ ] **Step 5: Commit**

```bash
git add vscode-cleanup.ps1 tests/Cli.Tests.ps1
git commit -m "feat: add vscode-cleanup CLI entry point"
```

---

### Task 14: Verify against a real project

This is the spec's verification requirement. Manual, no test file.

**Files:** none

- [ ] **Step 1: Pick a real project that has VS Code state**

```powershell
Get-ChildItem "$env:APPDATA\Code\User\workspaceStorage" -Directory |
    Select-Object -First 5 |
    ForEach-Object {
        $meta = Join-Path $_.FullName 'workspace.json'
        if (Test-Path $meta) {
            [pscustomobject]@{ Hash = $_.Name; Folder = (Get-Content $meta -Raw | ConvertFrom-Json).folder }
        }
    } | Format-Table -AutoSize
```

- [ ] **Step 2: Convert one of those URIs back to a Windows path and run the resolver**

Take a `Folder` value such as `file:///d%3A/Nuxt/mastering-nuxt-3` and run:

```powershell
.\vscode-cleanup.ps1 -Project 'D:\Nuxt\mastering-nuxt-3'
```

- [ ] **Step 3: Confirm the named workspaceStorage folder is the right one**

Open the report, find the `workspaceStorage` entry, and check by hand that its `workspace.json` contains that project's URI and no other project's:

```powershell
Get-Content "$env:APPDATA\Code\User\workspaceStorage\<hash-from-report>\workspace.json"
```

Expected: the `folder` value matches the project you passed. If it does not, stop — the URI normalizer or the matcher is wrong, and `-Delete` must not be used until it is fixed.

- [ ] **Step 4: Record the verification**

```bash
git commit --allow-empty -m "test: verify resolver against a real workspaceStorage entry"
```

---

### Task 15: Discovery watcher

**Files:**
- Create: `vscode-discover.ps1`

- [ ] **Step 1: Write the script**

Create `vscode-discover.ps1`:

```powershell
<#
.SYNOPSIS
    One-off sanity check: records every path VS Code writes under its own roots during a
    work session, then diffs that against what the resolver would have found.

.EXAMPLE
    .\vscode-discover.ps1 -Project 'D:\Nuxt\throwaway'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\src\VSCodeUri.ps1"
. "$PSScriptRoot\src\VSCodeRoots.ps1"
. "$PSScriptRoot\src\VSCodeSources.ps1"
. "$PSScriptRoot\src\VSCodeReport.ps1"

if (-not $LogPath) {
    $LogPath = Join-Path (Get-Location) "vscode-discover-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
}

$roots    = Get-VSCodeRoots
$written  = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
$watchers = @()

foreach ($dir in @($roots.CodeRoot, $roots.DotVscode)) {
    if (-not (Test-Path $dir)) { continue }

    $w = New-Object System.IO.FileSystemWatcher $dir
    $w.IncludeSubdirectories = $true
    $w.InternalBufferSize    = 65536
    $w.NotifyFilter          = [System.IO.NotifyFilters]::FileName -bor
                               [System.IO.NotifyFilters]::DirectoryName -bor
                               [System.IO.NotifyFilters]::LastWrite
    $w.EnableRaisingEvents   = $true

    foreach ($evt in @('Created', 'Changed')) {
        Register-ObjectEvent -InputObject $w -EventName $evt -MessageData $written -Action {
            $null = $Event.MessageData.Add($Event.SourceEventArgs.FullPath)
        } | Out-Null
    }

    $watchers += $w
}

Write-Host "Watching $($watchers.Count) root(s)."
Write-Host "Now put '$Project' through a full lifecycle in VS Code:"
Write-Host "  create it, open it, edit several files, let extensions activate,"
Write-Host "  close the window, reopen it, then close VS Code entirely."
Read-Host "Press Enter when done"

foreach ($w in $watchers) { $w.EnableRaisingEvents = $false }
Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.IO.FileSystemWatcher] } | Unregister-Event
foreach ($w in $watchers) { $w.Dispose() }

$written | Sort-Object | Out-File -FilePath $LogPath -Encoding utf8
Write-Host "Recorded $($written.Count) written path(s) -> $LogPath"
```

- [ ] **Step 2: Verify the watcher records writes**

Run it, and while it is waiting for Enter, in a second terminal:

```powershell
New-Item -Path "$env:APPDATA\Code\User\History\zzz-discover-test" -ItemType Directory -Force
```

Press Enter in the first terminal.
Expected: the log file contains a line ending in `zzz-discover-test`.

Then clean up:

```powershell
Remove-Item "$env:APPDATA\Code\User\History\zzz-discover-test" -Recurse -Force
```

- [ ] **Step 3: Commit**

```bash
git add vscode-discover.ps1
git commit -m "feat: add one-off filesystem watcher for vscode write discovery"
```

---

### Task 16: The diff

**Files:**
- Create: `src/VSCodeDiff.ps1`
- Modify: `vscode-discover.ps1`
- Test: `tests/VSCodeDiff.Tests.ps1`

- [ ] **Step 1: Write the failing test**

Create `tests/VSCodeDiff.Tests.ps1`:

```powershell
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Script .\tests\VSCodeDiff.Tests.ps1`
Expected: FAIL — `The term 'Compare-DiscoveryToResolver' is not recognized`

- [ ] **Step 3: Write minimal implementation**

Create `src/VSCodeDiff.ps1`:

```powershell
function Compare-DiscoveryToResolver {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$WrittenPaths,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Artifacts
    )

    $cmp      = [System.StringComparison]::OrdinalIgnoreCase
    $covered  = New-Object System.Collections.Generic.List[string]
    $gaps     = New-Object System.Collections.Generic.List[string]
    $hitPaths = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($p in $WrittenPaths) {
        $owner = $null
        foreach ($a in $Artifacts) {
            $root = $a.Path.TrimEnd('\')
            if ($p.Equals($root, $cmp) -or $p.StartsWith($root + '\', $cmp)) { $owner = $a.Path; break }
        }

        if ($owner) {
            $covered.Add($p)
            $null = $hitPaths.Add($owner)
        } else {
            $gaps.Add($p)
        }
    }

    $stale = @($Artifacts | Where-Object { -not $hitPaths.Contains($_.Path) } | ForEach-Object { $_.Path })

    [pscustomobject]@{
        Covered = $covered.ToArray()
        Gaps    = $gaps.ToArray()
        Stale   = $stale
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Script .\tests\VSCodeDiff.Tests.ps1`
Expected: PASS, 3 of 3

- [ ] **Step 5: Wire the diff into the discovery script**

In `vscode-discover.ps1`, add this dot-source next to the others:

```powershell
. "$PSScriptRoot\src\VSCodeDiff.ps1"
```

and append to the end of the file:

```powershell
$artifacts = @(Get-VSCodeProjectArtifacts -Project $Project -Roots $roots)
$diff      = Compare-DiscoveryToResolver -WrittenPaths @($written) -Artifacts $artifacts

$gapLog = [System.IO.Path]::ChangeExtension($LogPath, '.gaps.txt')
$diff.Gaps | Sort-Object | Out-File -FilePath $gapLog -Encoding utf8

Write-Host ""
Write-Host "Covered by resolver: $($diff.Covered.Count) written path(s)"
Write-Host "GAPS (would be left behind): $($diff.Gaps.Count) -> $gapLog"
Write-Host "Stale artifacts from earlier sessions: $($diff.Stale.Count) (expected, not a bug)"
```

- [ ] **Step 6: Run the full test suite**

Run: `Invoke-Pester -Script .\tests`
Expected: 0 failed

- [ ] **Step 7: Commit**

```bash
git add src/VSCodeDiff.ps1 tests/VSCodeDiff.Tests.ps1 vscode-discover.ps1
git commit -m "feat: diff discovered writes against resolver output"
```

---

### Task 17: Run the discovery once and close the gaps

This is the payoff. Manual, no test file.

**Files:**
- Create: `docs/discovery-findings.md`
- Modify: `src/VSCodeSources.ps1` (only if gaps turn out to be project-specific)

- [ ] **Step 1: Run the discovery against a throwaway project**

```powershell
.\vscode-discover.ps1 -Project 'C:\Users\<you>\Desktop\throwaway-test'
```

Follow the on-screen lifecycle instructions, then press Enter.

- [ ] **Step 2: Read the gap file**

Open the `.gaps.txt` file the script names. If it is empty or contains only obviously global paths (`Cache`, `GPUCache`, `Code Cache`, `Network`, log folders from other windows), the resolver is complete and no code changes are needed.

If the gap list is implausibly short — under roughly 20 paths for a full lifecycle — FileSystemWatcher dropped events. Redo the run with Process Monitor filtered to `Process Name is Code.exe` and `Operation is WriteFile`, export to CSV, and use that path list instead.

- [ ] **Step 3: Classify each distinct gap directory**

Create `docs/discovery-findings.md` with one section per distinct gap directory, each classified as exactly one of:

- **project-specific** — contains this project's path or a hash derived from it. Needs a new scanner in `src/VSCodeSources.ps1`.
- **shared/global** — used by all projects. Must never be deleted per-project; record why.

- [ ] **Step 4: Add a scanner for any project-specific gap**

For each `project-specific` finding, add a function to `src/VSCodeSources.ps1` following the exact shape of `Get-HistoryArtifacts` (same four output properties), add it to the `Get-VSCodeProjectArtifacts` orchestrator, and add a Pester test to `tests/VSCodeSources.Tests.ps1` using a new fixture helper in `tests/TestHelpers.ps1`. Put a comment above the function recording where it came from:

```powershell
# Added from discovery run 2026-09-22: <what was found and why it is project-specific>
```

If there are no project-specific findings, skip this step.

- [ ] **Step 5: Run the full test suite**

Run: `Invoke-Pester -Script .\tests`
Expected: 0 failed

- [ ] **Step 6: Commit**

```bash
git add docs/discovery-findings.md src tests
git commit -m "docs: record discovery findings and close resolver gaps"
```

---

## Done

At this point `vscode-cleanup.ps1 -Project <path>` reports every VS Code artifact belonging to a project, `-Delete` purges it behind three guardrails, and `docs/discovery-findings.md` records what was checked and what was deliberately left alone.
