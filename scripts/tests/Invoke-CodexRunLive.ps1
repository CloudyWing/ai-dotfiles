#Requires -Version 7.0
<#
.SYNOPSIS
以單一命令重跑一筆真實的審查派遣或換帳號派遣（呼叫 Codex 服務端，會消耗額度）。

.DESCRIPTION
review 場景審查本倉庫內一個小檔，並以 scripts\Invoke-CodexRun.ps1 發動。
failover 場景另產生暫存的 machine.json：第一個帳號的 auth.json 為無效字串（review.config.toml 複製自真實帳號的檔位設定），
第二個帳號為主 checkout 的 machine.json 登記的第一個帳號。第一個帳號會被服務端以 401 拒絕，入口改試第二個帳號。
暫存的 machine.json 與其健康狀態檔都在暫存目錄，不改動主 checkout 的 .local。

-DryRun 只列出將產生的派遣檔、machine.json 與將執行的命令，不寫任何檔案、不呼叫服務端。
非 -DryRun 執行前請確認額度並取得使用者同意（真實執行的驗證見設計文件 Phase 9）。
非 -DryRun 時會建立 report\live-verify 目錄與 handoff\live-verify\line.json。

.PARAMETER Scenario
review 或 failover。

.PARAMETER DryRun
只列出內容與命令。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('review', 'failover')]
    [string]$Scenario,

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot
$entryPath = Join-Path $scriptsRoot 'Invoke-CodexRun.ps1'
foreach ($module in @('00-common.ps1', '40-accounts.ps1')) { . (Join-Path $scriptsRoot ('codex-run\' + $module)) }
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$fence = '```'

$lineSlug = 'live-verify'
$dispatchSlug = 'live-' + $Scenario
$orderPath = Join-Path $repoRoot ('.local\ai-sessions\handoff\' + $lineSlug + '\' + $dispatchSlug + '-order.md')
$reportLineRoot = Join-Path $repoRoot ('.local\ai-sessions\report\' + $lineSlug)
$lineJsonPath = Join-Path $repoRoot ('.local\ai-sessions\handoff\' + $lineSlug + '\line.json')
$targetFile = Join-Path $scriptsRoot 'Test-CodexReviewReport.ps1'
$roleFile = Join-Path $repoRoot 'agents\codex\reviewer.toml'

# 派遣檔：審查一個小檔，審查類固定唯讀。
$setting = [ordered]@{
    schema = 'ai-agents.codex-run-order.v1'
    line_slug = $lineSlug
    dispatch_slug = $dispatchSlug
    task_type = 'review'
    profile = 'review'
    role_file = $roleFile
    execution_root = $repoRoot
    report_line_root = $reportLineRoot
    report_name = 'review-report.md'
    targets = @($targetFile)
    required_reads = @()
    cycle = [ordered]@{ id = $lineSlug; round = 1; role = 'review' }
}
$orderText = @(
    '# 派遣檔：' + $dispatchSlug
    ''
    '## 派遣設定'
    ''
    ($fence + 'json')
    (ConvertTo-Json -InputObject $setting -Depth 6)
    $fence
    ''
    '## 任務'
    ''
    '審查目標檔案 `scripts\Test-CodexReviewReport.ps1`，回報發現的問題。這是新入口的實機驗證，內容小，不需要擴大範圍。'
    ''
    '## 驗收條件'
    ''
    '| # | 類別 | 驗收條件 |'
    '| --- | --- | --- |'
    '| 1 | 報告格式 | 報告含 `## 總覽`、`## Finding manifest`（codex-run.review-findings.v1）與 `## 例外回報`。 |'
    '| 2 | 唯讀 | 不修改目標物件，只寫輸出目錄。 |'
    ''
    '## 邊界'
    ''
    '審查類固定唯讀。不得修改目標物件，不得執行建置與測試，不得建立 commit。唯一可寫入的位置是 prompt 指定的輸出目錄。'
    ''
    '## 回報必備欄位'
    ''
    '- `## 總覽`：審查結論（pass 或 fail）。'
    '- `## Finding manifest`：唯一一個 json 區塊，格式為 `codex-run.review-findings.v1`。'
    '- `## 例外回報`：沒有時寫「無」。'
) -join "`r`n"

$entryArguments = @('-NoProfile', '-File', $entryPath, '-DispatchFile', $orderPath)
$machineText = $null
$machinePath = $null
$extraFiles = @()
$temporaryRoot = $null
if ($Scenario -eq 'failover') {
    $realMachinePath = Resolve-RunMachineConfigPath
    $realAccount = @(Read-RunAccount -MachineConfigPath $realMachinePath)[0]
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-run-live-failover-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $badHome = Join-Path $temporaryRoot 'live-bad'
    $machinePath = Join-Path $temporaryRoot 'machine.json'
    $machineText = ConvertTo-Json -Depth 5 -InputObject ([ordered]@{
            schema = 'ai-agents.machine.v1'
            codex_accounts = @(
                [ordered]@{ name = 'live-bad'; codex_home = $badHome },
                [ordered]@{ name = $realAccount.name; codex_home = $realAccount.codex_home }
            )
        })
    $realProfileConfig = Join-Path $realAccount.codex_home 'review.config.toml'
    $extraFiles = @(
        [pscustomobject]@{ Path = (Join-Path $badHome 'auth.json'); Description = '無效字串（使第一個帳號被服務端以 401 拒絕）' },
        [pscustomobject]@{ Path = (Join-Path $badHome 'review.config.toml'); Description = ('複製自 ' + $realProfileConfig) }
    )
    $entryArguments += @('-MachineConfigPath', $machinePath)
}
$commandText = 'pwsh ' + (($entryArguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')

if ($DryRun) {
    Write-Output ('[DryRun] 場景：' + $Scenario + '（不寫任何檔案、不呼叫服務端）')
    Write-Output ('[DryRun] 派遣檔路徑：' + $orderPath)
    Write-Output ('[DryRun] 輸出根目錄（報告與執行紀錄）：' + (Join-Path $reportLineRoot 'runs'))
    Write-Output ('[DryRun] 將建立：' + $reportLineRoot + '；報告目錄（不存在時）')
    Write-Output ('[DryRun] 將建立：' + $lineJsonPath + '；線資料（不存在時）')
    if ($null -ne $machinePath) {
        Write-Output ('[DryRun] 暫存 machine.json 路徑：' + $machinePath)
        Write-Output $machineText
        foreach ($file in $extraFiles) { Write-Output ('[DryRun] 將建立：' + $file.Path + '；' + $file.Description) }
    }
    else {
        Write-Output '[DryRun] machine.json：使用主 checkout 的 .local\machine.json（唯讀）。'
    }
    Write-Output ('[DryRun] 派遣檔內容：')
    Write-Output $orderText
    Write-Output ('[DryRun] 將執行的命令：' + $commandText)
    exit 0
}

try {
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $orderPath))
    [IO.File]::WriteAllText($orderPath, $orderText + "`r`n", $utf8NoBom)
    $null = [IO.Directory]::CreateDirectory($reportLineRoot)
    if (-not [IO.File]::Exists($lineJsonPath)) {
        $lineText = ConvertTo-Json -Depth 3 -InputObject ([ordered]@{
                schema = 'ai-sessions.line.v1'
                'line-slug' = $lineSlug
                'semantic-label' = 'live verify'
                kind = 'adhoc'
                'created-at-utc' = [DateTime]::UtcNow.ToString('o')
            })
        [IO.File]::WriteAllText($lineJsonPath, $lineText + "`n", $utf8NoBom)
    }
    if ($null -ne $machinePath) {
        $null = [IO.Directory]::CreateDirectory($temporaryRoot)
        [IO.File]::WriteAllText($machinePath, $machineText + "`n", $utf8NoBom)
        foreach ($file in $extraFiles) { $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $file.Path)) }
        [IO.File]::WriteAllText($extraFiles[0].Path, 'invalid-auth-for-failover-test', $utf8NoBom)
        Copy-Item -LiteralPath $realProfileConfig -Destination $extraFiles[1].Path
    }
    $worktreesBefore = (& git -C $repoRoot worktree list) -join "`n"
    $statusBefore = (& git -C $repoRoot status --porcelain) -join "`n"
    Write-Output ('[live] 執行：' + $commandText)
    $output = & pwsh @entryArguments
    $exitCode = $LASTEXITCODE
    $worktreesAfter = (& git -C $repoRoot worktree list) -join "`n"
    $statusAfter = (& git -C $repoRoot status --porcelain) -join "`n"
    Write-Output ('[live] 結束碼：' + $exitCode)
    Write-Output ('[live] git worktree list 前後相同：' + ($worktreesBefore -ceq $worktreesAfter))
    Write-Output ('[live] git status --porcelain 前後相同：' + ($statusBefore -ceq $statusAfter))
    Write-Output ('[live] 結果文件：')
    Write-Output (@($output) -join "`n")
    exit $exitCode
}
finally {
    if ($null -ne $temporaryRoot -and [IO.Directory]::Exists($temporaryRoot)) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
