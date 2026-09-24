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
    It "throws on a UNC path" {
        { ConvertTo-VSCodeUri -Path '\\server\share\proj' } | Should Throw 'Only rooted drive paths'
    }
    It "throws on a relative path" {
        { ConvertTo-VSCodeUri -Path 'rel\proj' } | Should Throw 'Only rooted drive paths'
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
    It "throws on a drive-relative path" {
        { ConvertTo-VSCodeUri -Path 'C:foo' } | Should Throw 'Only rooted drive paths'
    }
}

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
