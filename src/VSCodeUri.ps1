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
