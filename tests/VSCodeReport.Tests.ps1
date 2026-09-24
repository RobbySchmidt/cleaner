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
