#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 的 param 預設值取不到 $PSScriptRoot，改在主體補上預設路徑。
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path $PSScriptRoot '..\Get-DispatchProgress.ps1'
}
$failed = 0
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('dispatch-progress-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Test-Case {
    param([string]$Id, [scriptblock]$Check)
    try {
        if (-not (& $Check)) { throw '條件不成立' }
        Write-Output "PASS $Id"
    }
    catch {
        $script:failed++
        Write-Output "FAIL $Id $($_.Exception.Message)"
    }
}

# 以 handle 開著事件流的方式模擬 Codex 執行中持有寫入 handle，$Share 決定共享模式。
# $Lines 以逐行寫入並 Flush；$NoTrailingNewline 讓最後一行不附換行（模擬寫到一半）。
function Invoke-WithOpenEventStream {
    param(
        [string]$Name,
        [string[]]$Lines,
        [IO.FileShare]$Share,
        [scriptblock]$Body,
        [switch]$NoTrailingNewline
    )

    $path = Join-Path $tempRoot ($Name + '.jsonl')
    $stream = $null
    try {
        $stream = New-Object IO.FileStream($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, $Share)
        $content = ($Lines -join "`n")
        if (-not $NoTrailingNewline) {
            $content += "`n"
        }
        $bytes = $utf8NoBom.GetBytes($content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        return (& $Body $path)
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

$agentLine = '{"type":"item.completed","item":{"type":"agent_message","text":"hello"}}'

try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($resolvedScript, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw "腳本剖析失敗：$resolvedScript" }
    $functionNames = @('ConvertTo-DispatchUtcTimestamp', 'Get-DispatchEventTimestamp', 'Get-DispatchObjectProperty', 'Get-DispatchEventStreamSummary')
    $definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $functionNames -contains $node.Name }, $true))
    if ($definitions.Count -ne $functionNames.Count) { throw "無法由 $resolvedScript 取出全部必要函式" }
    foreach ($definition in $definitions) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    Test-Case 'A 寫入 handle 開著時可讀取，且未判定結束' {
        $summary = Invoke-WithOpenEventStream -Name 'a' -Lines @($agentLine) -Share ([IO.FileShare]::ReadWrite) -Body {
            param($path)
            Get-DispatchEventStreamSummary -Path $path
        }
        $summary.last_agent_message -ceq 'hello' -and $summary.terminal_status -ceq ''
    }

    Test-Case 'B1 寫入 handle 開著且含 turn.completed 時判定 completed' {
        $summary = Invoke-WithOpenEventStream -Name 'b1' -Lines @($agentLine, '{"type":"turn.completed","usage":{}}') -Share ([IO.FileShare]::ReadWrite) -Body {
            param($path)
            Get-DispatchEventStreamSummary -Path $path
        }
        $summary.terminal_status -ceq 'completed' -and $summary.last_agent_message -ceq 'hello' -and $summary.error_message -ceq ''
    }

    Test-Case 'B2 寫入 handle 開著且含 turn.failed 時判定 failed 並取得 error_message' {
        $summary = Invoke-WithOpenEventStream -Name 'b2' -Lines @($agentLine, '{"type":"turn.failed","error":{"message":"boom"}}') -Share ([IO.FileShare]::ReadWrite) -Body {
            param($path)
            Get-DispatchEventStreamSummary -Path $path
        }
        $summary.terminal_status -ceq 'failed' -and $summary.error_message -ceq 'boom'
    }

    Test-Case 'C 檔案不存在時回傳空摘要且不丟例外' {
        $missing = Join-Path $tempRoot 'missing.jsonl'
        $summary = Get-DispatchEventStreamSummary -Path $missing
        $nullSummary = Get-DispatchEventStreamSummary -Path $null
        $summary.terminal_status -ceq '' -and $summary.last_agent_message -ceq '' -and $summary.error_message -ceq '' -and
        $null -eq $summary.last_event_utc -and $null -eq $nullSummary.last_event_utc
    }

    Test-Case 'D 最後一行為不完整 JSON 時前面事件仍被摘要' {
        $summary = Invoke-WithOpenEventStream -Name 'd' -Lines @($agentLine, '{"type":"turn.compl') -NoTrailingNewline -Share ([IO.FileShare]::ReadWrite) -Body {
            param($path)
            Get-DispatchEventStreamSummary -Path $path
        }
        $summary.last_agent_message -ceq 'hello' -and $summary.terminal_status -ceq ''
    }

    Test-Case 'E 寫入端獨佔開檔時丟出例外，不回傳空摘要冒充成功' {
        $outcome = Invoke-WithOpenEventStream -Name 'e' -Lines @($agentLine) -Share ([IO.FileShare]::None) -Body {
            param($path)
            $result = [ordered]@{ Threw = $false; Returned = $null; IsIOException = $false }
            try {
                $result.Returned = Get-DispatchEventStreamSummary -Path $path
            }
            catch {
                $result.Threw = $true
                $inner = $_.Exception
                while ($null -ne $inner.InnerException) {
                    $inner = $inner.InnerException
                }
                $result.IsIOException = $inner -is [IO.IOException]
            }
            [pscustomobject]$result
        }
        $outcome.Threw -and $outcome.IsIOException -and $null -eq $outcome.Returned
    }
}
catch {
    $failed++
    Write-Output "FAIL setup $($_.Exception.Message)"
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Output "FAILED: $failed"
if ($failed -gt 0) {
    exit 1
}
exit 0
