#Requires -Version 7.0
# 假 codex。由 New-FakeCodexCmd 包成 codex.cmd，經真實的 cmd.exe 與參數轉手路徑被呼叫。
# 協定：環境變數 FAKE_CODEX_SCENARIO_DIR 指向場景目錄，依 CODEX_HOME 的末段目錄名讀 <名稱>.json。
# 引數含 -c model=<model> 覆寫且 <名稱>@<model>.json 存在時改讀該檔，供同一帳號不同 model 得到不同結果。
# 場景欄位：
#   events        事件物件陣列，逐行輸出到 stdout（exec 用）
#   exit_code     結束碼（exec 用，預設 0）
#   last_message  寫入 --output-last-message 指定路徑的文字，null 表示不寫
#   report        寫入 stdin prompt 中「報告檔:」行指定路徑的文字，null 表示不寫，空字串表示建立空檔
#   modify_target 執行中追加內容的檔案路徑
#   delete_target 執行中刪除的檔案路徑
#   hang_seconds  輸出與檔案都寫完後不結束，睡這麼多秒再以 exit_code 結束（exec 用；本行程的 PID 寫到場景目錄 pid-<名稱>.txt）
#   output_files  依 stdin prompt 的「輸出目錄:」行建立在輸出目錄內的檔案（相對路徑到內容的物件），模擬 MCP 工具把截圖存進輸出目錄
#   stray_files   建立在 --cd 工作目錄之下的檔案（相對路徑到內容的物件），模擬 MCP 工具把明確檔名的截圖寫到工作目錄根下
#   mxc           sandbox 子命令的回應，ok 或 fail（預設 ok）
# exec 時若 stdin prompt 的「輸出目錄:」行對應的執行紀錄（<輸出目錄>.record.json）已存在，複製為場景目錄的
# record-draft-<名稱>.json，供測試檢查入口在 Codex 結束前寫出的紀錄初稿。
# 每次呼叫把子命令、引數、環境變數名稱、stdin 位元組的 SHA-256 追加到 FAKE_CODEX_SCENARIO_DIR\calls.jsonl。
$utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scenarioDir = $env:FAKE_CODEX_SCENARIO_DIR
$codexHome = $env:CODEX_HOME
$accountName = Split-Path -Leaf $codexHome
$subcommand = if ($args -contains 'sandbox') { 'sandbox' } elseif ($args -contains 'exec') { 'exec' } else { 'unknown' }

$stdinBytes = [byte[]]@()
if ($subcommand -eq 'exec') {
    $buffer = New-Object System.IO.MemoryStream
    [Console]::OpenStandardInput().CopyTo($buffer)
    $stdinBytes = $buffer.ToArray()
}
$stdinText = $utf8NoBom.GetString($stdinBytes)
if ($subcommand -eq 'exec') { [IO.File]::WriteAllText((Join-Path $scenarioDir ('stdin-' + $accountName + '.txt')), $stdinText, $utf8NoBom) }
$call = [ordered]@{
    subcommand = $subcommand
    account = $accountName
    codex_home = $codexHome
    args = @($args)
    env_names = @(Get-ChildItem Env: | ForEach-Object { $_.Name })
    playwright_output_dir = $env:PLAYWRIGHT_MCP_OUTPUT_DIR
    stdin_sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stdinBytes)).ToLowerInvariant()
}
[IO.File]::AppendAllText((Join-Path $scenarioDir 'calls.jsonl'), (ConvertTo-Json -InputObject $call -Compress -Depth 5) + "`n", $utf8NoBom)

$scenarioPath = Join-Path $scenarioDir ($accountName + '.json')
foreach ($argument in @($args)) {
    $modelMatch = [regex]::Match([string]$argument, '^model="?(?<model>[A-Za-z0-9._-]+)"?$')
    if (-not $modelMatch.Success) { continue }
    $modelScenarioPath = Join-Path $scenarioDir ($accountName + '@' + $modelMatch.Groups['model'].Value + '.json')
    if ([IO.File]::Exists($modelScenarioPath)) { $scenarioPath = $modelScenarioPath }
}
$scenario = $null
if ([IO.File]::Exists($scenarioPath)) { $scenario = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($scenarioPath, $utf8NoBom)) }
function Get-ScenarioValue([string]$Name, $Default) {
    if ($null -eq $scenario) { return $Default }
    $property = $scenario.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return , $property.Value
}

if ($subcommand -eq 'sandbox') {
    $mxc = Get-ScenarioValue 'mxc' 'ok'
    if ($mxc -eq 'fail') { [Console]::Error.WriteLine('fake codex: mxc unavailable'); exit 1 }
    [Console]::Out.WriteLine('MXC_OK')
    exit 0
}
if ($subcommand -ne 'exec' -or $null -eq $scenario) {
    [Console]::Error.WriteLine('fake codex: no scenario for account ' + $accountName)
    exit 9
}

[IO.File]::WriteAllText((Join-Path $scenarioDir ('pid-' + $accountName + '.txt')), [string]$PID, $utf8NoBom)
$outputDirectoryMatch = [regex]::Match($stdinText, '(?m)^輸出目錄: (?<path>.+?)\r?$')
if ($outputDirectoryMatch.Success) {
    $draftRecordPath = $outputDirectoryMatch.Groups['path'].Value.TrimEnd('\', '/') + '.record.json'
    if ([IO.File]::Exists($draftRecordPath)) { [IO.File]::Copy($draftRecordPath, (Join-Path $scenarioDir ('record-draft-' + $accountName + '.json')), $true) }
}
$outputFiles = Get-ScenarioValue 'output_files' $null
if ($null -ne $outputFiles -and $outputDirectoryMatch.Success) {
    foreach ($property in $outputFiles.PSObject.Properties) {
        $target = Join-Path $outputDirectoryMatch.Groups['path'].Value.TrimEnd('\', '/') $property.Name
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::WriteAllText($target, [string]$property.Value, $utf8NoBom)
    }
}
$strayFiles = Get-ScenarioValue 'stray_files' $null
$cdIndex = [array]::IndexOf(@($args), '--cd')
if ($null -ne $strayFiles -and $cdIndex -ge 0) {
    foreach ($property in $strayFiles.PSObject.Properties) {
        $target = Join-Path @($args)[$cdIndex + 1] $property.Name
        $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        [IO.File]::WriteAllText($target, [string]$property.Value, $utf8NoBom)
    }
}
$modifyTarget = Get-ScenarioValue 'modify_target' $null
if ($null -ne $modifyTarget) { [IO.File]::AppendAllText($modifyTarget, "`nmodified-by-fake-codex", $utf8NoBom) }

$deleteTarget = Get-ScenarioValue 'delete_target' $null
if ($null -ne $deleteTarget) { Remove-Item -LiteralPath $deleteTarget -Force }

$stdout = [Console]::OpenStandardOutput()
$eventList = Get-ScenarioValue 'events' @()
foreach ($eventObject in @($eventList)) {
    $bytes = $utf8NoBom.GetBytes((ConvertTo-Json -InputObject $eventObject -Compress -Depth 10) + "`n")
    $stdout.Write($bytes, 0, $bytes.Length)
}
$stdout.Flush()

$lastMessage = Get-ScenarioValue 'last_message' $null
$lastMessageIndex = [array]::IndexOf(@($args), '--output-last-message')
if ($null -ne $lastMessage -and $lastMessageIndex -ge 0) { [IO.File]::WriteAllText(@($args)[$lastMessageIndex + 1], [string]$lastMessage, $utf8NoBom) }

$report = Get-ScenarioValue 'report' $null
$reportMatch = [regex]::Match($stdinText, '(?m)^報告檔: (?<path>.+?)\r?$')
if ($null -ne $report -and $reportMatch.Success) { [IO.File]::WriteAllText($reportMatch.Groups['path'].Value, [string]$report, $utf8NoBom) }

$hangSeconds = [int](Get-ScenarioValue 'hang_seconds' 0)
if ($hangSeconds -gt 0) { Start-Sleep -Seconds $hangSeconds }
$exitCode = Get-ScenarioValue 'exit_code' 0
exit ([int]$exitCode)
