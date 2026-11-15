#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
foreach ($module in @('00-common.ps1', '35-review-check.ps1')) { . (Join-Path $moduleRoot $module) }
$wrapperPath = Join-Path $scriptsRoot 'Test-CodexReviewReport.ps1'

try {
    $root = New-TestDirectory -Name 'reviewcheck'
    $fence = '```'
    function New-ReportFile {
        param([string]$Name, [string]$ManifestJson, [string]$Body = '')
        $text = "# 審查報告`n`n## 總覽`n`n結論：fail`n`n## Finding manifest`n`n${fence}json`n$ManifestJson`n$fence`n`n## 例外回報`n`n無`n$Body"
        $path = Join-Path $root ($Name + '.md')
        Write-TestUtf8 -Path $path -Text $text
        return $path
    }
    function New-ManifestJson {
        param([object[]]$Finding, [string]$Schema = 'codex-run.review-findings.v1')
        return (ConvertTo-Json -InputObject ([ordered]@{ schema = $Schema; findings = @($Finding) }) -Depth 6)
    }
    function New-Finding {
        param([string]$Id = 'F-001', [string]$Severity = 'Major', [string]$Status = 'open', [string]$Summary = '一句話說明')
        $finding = [ordered]@{}
        if ($Id) { $finding['id'] = $Id }
        $finding['severity'] = $Severity
        $finding['status'] = $Status
        $finding['summary'] = $Summary
        return $finding
    }
    function Invoke-Wrapper {
        param([string]$ReportPath)
        $output = & ([Environment]::ProcessPath) -NoProfile -File $wrapperPath -ReportPath $ReportPath 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Json = (ConvertFrom-Json -InputObject (@($output | ForEach-Object { [string]$_ }) -join "`n")) }
    }

    Test-Case 'REVIEW-VALID 合格報告 valid=true，保留 findings' {
        $path = New-ReportFile -Name 'valid' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-001'), (New-Finding -Id 'F-002' -Severity 'Minor' -Status 'closed'), (New-Finding -Id 'T012B' -Severity 'Critical' -Status 'accepted')))
        $result = Test-RunReviewReport -ReportPath $path
        Assert-Equal $true $result.valid
        Assert-Equal 0 (@($result.errors).Count)
        Assert-Equal @('F-001', 'F-002', 'T012B') @($result.findings | ForEach-Object { $_.id })
    }
    Test-Case 'REVIEW-EMPTY 無 finding 的報告 valid=true' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'empty' -ManifestJson (New-ManifestJson -Finding @()))
        Assert-Equal $true $result.valid
        Assert-Equal 0 (@($result.findings).Count)
    }
    Test-Case 'REVIEW-DUPLICATE 重複編號' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'dup' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-003'), (New-Finding -Id 'F-003'))))
        Assert-Equal $false $result.valid
        Assert-Equal @('F-003 id: duplicate') @($result.errors)
    }
    Test-Case 'REVIEW-SEVERITY severity 為 High 時指出 finding 與欄位' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'sev' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-003' -Severity 'High'))))
        Assert-Equal @("F-003 severity: invalid value 'High'") @($result.errors)
    }
    Test-Case 'REVIEW-STATUS status 為 fixed 時指出 finding 與欄位' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'status' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-001'), (New-Finding -Id 'F-004' -Status 'fixed'))))
        Assert-Equal @("F-004 status: invalid value 'fixed'") @($result.errors)
    }
    Test-Case 'REVIEW-MISSING-ID 缺 id 時以 findings[索引] 指出（索引從 0 起算）' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'noid' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-001'), (New-Finding -Id 'F-002'), (New-Finding -Id ''))))
        Assert-Equal @('findings[2] id: missing') @($result.errors)
    }
    Test-Case 'REVIEW-ID-FORMAT 編號格式不合法' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'idformat' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'finding-1'))))
        Assert-Equal @("finding-1 id: invalid value 'finding-1'") @($result.errors)
    }
    Test-Case 'REVIEW-SUMMARY summary 為空' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'summary' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-004' -Summary ' '))))
        Assert-Equal @('F-004 summary: empty') @($result.errors)
    }
    Test-Case 'REVIEW-THREE-ERRORS 同一份報告含 3 個錯誤時 errors 恰 3 筆' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'three' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-001'), (New-Finding -Id 'F-001'), (New-Finding -Id 'F-002' -Severity 'High'), (New-Finding -Id 'F-004' -Status 'fixed'))))
        Assert-Equal 3 (@($result.errors).Count)
        Assert-Equal @('F-001 id: duplicate', "F-002 severity: invalid value 'High'", "F-004 status: invalid value 'fixed'") @($result.errors)
    }
    Test-Case 'REVIEW-HEADINGS 兩個 Finding manifest 標題與兩個 json 區塊各自報錯' {
        $twoHeadings = New-ReportFile -Name 'two-headings' -ManifestJson (New-ManifestJson -Finding @()) -Body "`n## Finding manifest`n`n${fence}json`n{}`n$fence`n"
        $result = Test-RunReviewReport -ReportPath $twoHeadings
        Assert-Equal $false $result.valid
        Assert-Equal @('manifest: heading count 2') @($result.errors)
        $twoBlocks = Join-Path $root 'two-blocks.md'
        Write-TestUtf8 -Path $twoBlocks -Text "# r`n`n## Finding manifest`n`n${fence}json`n{}`n$fence`n`n${fence}json`n{}`n$fence`n"
        $result = Test-RunReviewReport -ReportPath $twoBlocks
        Assert-Equal @('manifest: json block count 2') @($result.errors)
        $noHeading = Join-Path $root 'no-heading.md'
        Write-TestUtf8 -Path $noHeading -Text "# r`n`n## 總覽`n"
        Assert-Equal @('manifest: heading not found') @((Test-RunReviewReport -ReportPath $noHeading).errors)
        $noBlock = Join-Path $root 'no-block.md'
        Write-TestUtf8 -Path $noBlock -Text "# r`n`n## Finding manifest`n`n沒有區塊`n"
        Assert-Equal @('manifest: json block count 0') @((Test-RunReviewReport -ReportPath $noBlock).errors)
    }
    Test-Case 'REVIEW-SCHEMA schema 不符、JSON 無法解析與 findings 不是陣列' {
        $result = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'schema' -ManifestJson (New-ManifestJson -Finding @() -Schema 'codex-run.review-findings.v2'))
        Assert-Equal @('manifest: schema invalid') @($result.errors)
        $broken = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'broken' -ManifestJson '{ not json')
        Assert-True ($broken.errors[0].StartsWith('manifest: json invalid:', [StringComparison]::Ordinal))
        $notArray = Test-RunReviewReport -ReportPath (New-ReportFile -Name 'notarray' -ManifestJson '{"schema":"codex-run.review-findings.v1","findings":{"id":"F-001"}}')
        Assert-Equal @('manifest: findings must be an array') @($notArray.errors)
    }
    Test-Case 'REVIEW-MISSING-FILE 報告不存在時回報 report file not found' {
        $result = Test-RunReviewReport -ReportPath (Join-Path $root 'absent.md')
        Assert-Equal $false $result.valid
        Assert-Equal @('manifest: report file not found') @($result.errors)
    }
    Test-Case 'WRAPPER-EXIT 命令列包裝：合格報告結束碼 0，不合格與不存在結束碼 1，輸出為 ASCII JSON' {
        $valid = Invoke-Wrapper -ReportPath (New-ReportFile -Name 'wrap-valid' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-001' -Summary '中文摘要'))))
        Assert-Equal 0 $valid.ExitCode
        Assert-Equal $true $valid.Json.valid
        Assert-Equal '中文摘要' $valid.Json.findings[0].summary
        $rawOutput = (& ([Environment]::ProcessPath) -NoProfile -File $wrapperPath -ReportPath (Join-Path $root 'wrap-valid.md') 2>&1) -join "`n"
        Assert-True (-not [regex]::IsMatch($rawOutput, '[^\x00-\x7F]')) '輸出含非 ASCII 字元'
        $invalid = Invoke-Wrapper -ReportPath (New-ReportFile -Name 'wrap-invalid' -ManifestJson (New-ManifestJson -Finding @((New-Finding -Id 'F-003' -Severity 'High'))))
        Assert-Equal 1 $invalid.ExitCode
        Assert-Equal $false $invalid.Json.valid
        Assert-Equal "F-003 severity: invalid value 'High'" $invalid.Json.errors[0]
        $absent = Invoke-Wrapper -ReportPath (Join-Path $root 'wrap-absent.md')
        Assert-Equal 1 $absent.ExitCode
        Assert-Equal 'manifest: report file not found' $absent.Json.errors[0]
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
