#Requires -Version 7.0
# 假 codex。由 New-FakeCodexCmd 包成 codex.cmd，經真實的 cmd.exe 與參數轉手路徑被呼叫。
# 協定：環境變數 FAKE_CODEX_SCENARIO_DIR 指向場景目錄，依 CODEX_HOME 的末段目錄名讀 <名稱>.json。
# 場景欄位：
#   events        事件物件陣列，逐行輸出到 stdout（exec 用）
#   exit_code     結束碼（exec 用，預設 0）
#   last_message  寫入 --output-last-message 指定路徑的文字，null 表示不寫
#   report        寫入 stdin prompt 中「報告檔:」行指定路徑的文字，null 表示不寫，空字串表示建立空檔
#   modify_target 執行中追加內容的檔案路徑
#   mxc           sandbox 子命令的回應，ok 或 fail（預設 ok）
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
    stdin_sha256 = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stdinBytes)).ToLowerInvariant()
}
[IO.File]::AppendAllText((Join-Path $scenarioDir 'calls.jsonl'), (ConvertTo-Json -InputObject $call -Compress -Depth 5) + "`n", $utf8NoBom)

$scenarioPath = Join-Path $scenarioDir ($accountName + '.json')
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

$modifyTarget = Get-ScenarioValue 'modify_target' $null
if ($null -ne $modifyTarget) { [IO.File]::AppendAllText($modifyTarget, "`nmodified-by-fake-codex", $utf8NoBom) }

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

$exitCode = Get-ScenarioValue 'exit_code' 0
exit ([int]$exitCode)
