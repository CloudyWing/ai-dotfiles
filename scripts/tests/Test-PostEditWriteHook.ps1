#Requires -Version 7.0
# post-edit-write 檢查的測試：Markdown 排版候選與 BOM 規範。判定在 hooks\core\post-edit-write.ts，
# 由 tests\run-hook.ts 以命令型 hook 的 stdin 形式執行，診斷行輸出到 stdout。
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$runHook = Join-Path $repoRoot 'claude-plugins\ai-agents-hooks\tests\run-hook.ts'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
$passed = 0
$failed = 0

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        & $Check
        $script:passed++
        Write-Output "PASS $Id"
    }
    catch {
        $script:failed++
        Write-Output "FAIL $Id $($_.Exception.Message)"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Check {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$StdinText)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new('node')
    foreach ($argument in @('--no-warnings', $runHook, 'post-edit-write')) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.UseShellExecute = $false
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdinBytes = $utf8NoBom.GetBytes($StdinText)
        $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
        $process.StandardInput.Close()
        $output = $process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or $errorText.Length -ne 0) { throw "exit=$($process.ExitCode) stderr=$errorText" }
        return @($output -split '\r?\n' | Where-Object { $_ -ne '' })
    }
    finally {
        $process.Dispose()
    }
}

function New-Input {
    param([string]$Tool, [string]$FilePath)
    return ([ordered]@{ tool_name = $Tool; tool_input = [ordered]@{ file_path = $FilePath } } | ConvertTo-Json -Compress -Depth 4)
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('post-edit-write-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $dash = [string][char]0x2014 + [char]0x2014
    $mdPath = Join-Path $root 'doc.md'
    $writtenLine = "[post-edit-write hook] $mdPath was written. Please run check-markdown skill to verify Markdown formatting."

    Test-Case 'E01 乾淨的 .md 只輸出 check-markdown 提示' {
        [System.IO.File]::WriteAllText($mdPath, "# 標題`n`n一般段落。`n", $utf8NoBom)
        $lines = @(Invoke-Check (New-Input 'Write' $mdPath))
        Assert-True ($lines.Count -eq 1 -and $lines[0] -ceq $writtenLine) ('輸出不符：' + ($lines -join ' / '))
    }

    Test-Case 'E02 Edit 與 Write 同樣檢查，tool_name 不分大小寫' {
        $lines = @(Invoke-Check (New-Input 'edit' $mdPath))
        Assert-True ($lines.Count -eq 1 -and $lines[0] -ceq $writtenLine) ('輸出不符：' + ($lines -join ' / '))
    }

    Test-Case 'E03 全形破折號列出行號，圍欄區塊與行內 code 內的不算' {
        $text = "第一行`n這裡${dash}轉折`n``````text`n區塊內${dash}不算`n```````n行內 ``a${dash}b`` 不算`n"
        [System.IO.File]::WriteAllText($mdPath, $text, $utf8NoBom)
        $lines = @(Invoke-Check (New-Input 'Write' $mdPath))
        $expected = @(
            $writtenLine,
            "[post-edit-write hook] WARNING: $mdPath contains forbidden full-width dash (two consecutive U+2014). Replace with comma/semicolon or split into separate sentences:",
            "  line 2: 這裡${dash}轉折"
        )
        Assert-True (($lines -join "`n") -ceq ($expected -join "`n")) ('輸出不符：' + ($lines -join ' / '))
    }

    Test-Case 'E04 散文式冒號候選列出，白名單引言與非句尾結尾不列' {
        $text = "這是重點：所有請求都會驗證。`n設定如下：所有請求都會驗證。`n標籤：值`n"
        [System.IO.File]::WriteAllText($mdPath, $text, $utf8NoBom)
        $lines = @(Invoke-Check (New-Input 'Write' $mdPath))
        Assert-True ($lines.Count -eq 3) ('行數不符：' + ($lines -join ' / '))
        Assert-True ($lines[1].StartsWith("[post-edit-write hook] REVIEW: $mdPath has candidate prose-colon lines", [StringComparison]::Ordinal)) ('REVIEW 行不符：' + $lines[1])
        Assert-True ($lines[2] -ceq '  line 1: 這是重點：所有請求都會驗證。') ('候選行不符：' + $lines[2])
    }

    Test-Case 'E05 破折號與冒號同時出現時先列破折號' {
        [System.IO.File]::WriteAllText($mdPath, "這是重點：所有請求${dash}都會驗證。`n", $utf8NoBom)
        $lines = @(Invoke-Check (New-Input 'Write' $mdPath))
        Assert-True ($lines.Count -eq 5 -and $lines[1].Contains('forbidden full-width dash') -and $lines[3].Contains('candidate prose-colon')) ('輸出不符：' + ($lines -join ' / '))
    }

    Test-Case 'E06 .md 帶 BOM 時提示不應有 BOM' {
        [System.IO.File]::WriteAllText($mdPath, "內容`n", $utf8Bom)
        $lines = @(Invoke-Check (New-Input 'Write' $mdPath))
        Assert-True ($lines.Count -eq 2 -and $lines[1] -ceq "[post-edit-write hook] WARNING: $mdPath has unexpected UTF-8 BOM. '.md' files should not have BOM. Please rewrite without BOM or run /fix-file-encoding.") ('輸出不符：' + ($lines -join ' / '))
    }

    Test-Case 'E07 .ps1 與 .csv 缺 BOM 時提示，帶 BOM 時不輸出' {
        foreach ($extension in @('.ps1', '.csv')) {
            $path = Join-Path $root ('a' + $extension)
            [System.IO.File]::WriteAllText($path, "x`n", $utf8NoBom)
            $lines = @(Invoke-Check (New-Input 'Write' $path))
            Assert-True ($lines.Count -eq 1 -and $lines[0] -ceq "[post-edit-write hook] WARNING: $path is missing UTF-8 BOM. '$extension' files require BOM. Please rewrite with BOM or run /fix-file-encoding.") ("$extension 缺 BOM 的輸出不符：" + ($lines -join ' / '))
            [System.IO.File]::WriteAllText($path, "x`n", $utf8Bom)
            $lines = @(Invoke-Check (New-Input 'Write' $path))
            Assert-True ($lines.Count -eq 0) ("$extension 帶 BOM 不應輸出：" + ($lines -join ' / '))
        }
    }

    Test-Case 'E08 不應有 BOM 的副檔名帶 BOM 時提示，副檔名不分大小寫' {
        foreach ($extension in @('.json', '.xml', '.yaml', '.yml', '.sh', '.TXT')) {
            $path = Join-Path $root ('b' + $extension)
            [System.IO.File]::WriteAllText($path, "x`n", $utf8Bom)
            $lines = @(Invoke-Check (New-Input 'Write' $path))
            $lower = $extension.ToLowerInvariant()
            Assert-True ($lines.Count -eq 1 -and $lines[0] -ceq "[post-edit-write hook] WARNING: $path has unexpected UTF-8 BOM. '$lower' files should not have BOM. Please rewrite without BOM or run /fix-file-encoding.") ("$extension 的輸出不符：" + ($lines -join ' / '))
        }
    }

    Test-Case 'E09 其他副檔名不輸出' {
        $path = Join-Path $root 'c.cs'
        [System.IO.File]::WriteAllText($path, "x`n", $utf8Bom)
        $lines = @(Invoke-Check (New-Input 'Write' $path))
        Assert-True ($lines.Count -eq 0) ('不應輸出：' + ($lines -join ' / '))
    }

    Test-Case 'E10 .md 檔案不存在時只輸出 check-markdown 提示' {
        $path = Join-Path $root 'missing.md'
        $lines = @(Invoke-Check (New-Input 'Write' $path))
        Assert-True ($lines.Count -eq 1 -and $lines[0] -ceq "[post-edit-write hook] $path was written. Please run check-markdown skill to verify Markdown formatting.") ('輸出不符：' + ($lines -join ' / '))
    }

    Test-Case 'E11 非 Edit 或 Write、缺 file_path 與非 JSON 的輸入不輸出' {
        foreach ($inputText in @((New-Input 'Read' $mdPath), '{"tool_name":"Write","tool_input":{}}', 'not json', '')) {
            $lines = @(Invoke-Check $inputText)
            Assert-True ($lines.Count -eq 0) ("不應輸出：$inputText → " + ($lines -join ' / '))
        }
    }
}
finally {
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop } catch { Write-Warning "temp cleanup failed: $root" }
}

Write-Output ("PASSED {0} FAILED {1}" -f $passed, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
