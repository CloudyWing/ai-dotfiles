#Requires -Version 7.0
# PostToolUse 提醒 hook：Write 或 Edit 寫入進版控的 .md，且本次寫入的文字含磁碟機絕對路徑時，
# 以 additionalContext 提醒改用佔位符或相對路徑。只提醒不阻擋，任何錯誤一律安靜退出 0。
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

# 輸出格式比照 turn-guard-hook.ps1：純 ASCII 位元組、不帶 BOM，非 ASCII 以 \uXXXX 跳脫。
function Write-Reminder([string]$Text) {
    $payload = [ordered]@{hookSpecificOutput=[ordered]@{hookEventName='PostToolUse';additionalContext=$Text}}
    $json = $payload | ConvertTo-Json -Compress -Depth 4
    $ascii = [regex]::Replace($json, '[^\u0000-\u007F]', { param($m) '\u' + ([int][char]$m.Value).ToString('x4') })
    $bytes = [Text.Encoding]::ASCII.GetBytes($ascii)
    $out = [Console]::OpenStandardOutput()
    try { $out.Write($bytes, 0, $bytes.Length); $out.Flush() } finally { $out.Dispose() }
}

try {
    . (Join-Path $PSScriptRoot 'lib\doc-path-check.ps1')
    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $inputText = [Console]::In.ReadToEnd()
    $inputObject = $inputText | ConvertFrom-Json -ErrorAction Stop
    $tool = Get-Value $inputObject 'tool_name'
    if ($tool -ne 'Write' -and $tool -ne 'Edit') { exit 0 }
    $toolInput = Get-Value $inputObject 'tool_input'
    $filePath = Get-Value $toolInput 'file_path'
    if ($filePath -isnot [string] -or [string]::IsNullOrWhiteSpace($filePath)) { exit 0 }
    if ([IO.Path]::GetExtension($filePath) -ine '.md') { exit 0 }
    if (Test-LocalPathExcludedFile -Path $filePath) { exit 0 }
    $text = if ($tool -eq 'Write') { Get-Value $toolInput 'content' } else { Get-Value $toolInput 'new_string' }
    if ($text -isnot [string] -or $text.Length -eq 0) { exit 0 }

    $found = [System.Collections.Generic.List[string]]::new()
    $lines = $text -split "\r?\n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        foreach ($token in @(Find-LocalPathViolation -Text $lines[$i])) {
            $found.Add(('line {0}: {1}' -f ($i + 1), $token))
        }
    }
    if ($found.Count -eq 0) { exit 0 }

    # 只在偵測到違規後才呼叫 git。退出碼 1 才是受控；0（被忽略）、128（非 repo）與找不到 git 皆略過。
    $directory = Split-Path -Parent $filePath
    if ([string]::IsNullOrEmpty($directory) -or -not (Test-Path -LiteralPath $directory -PathType Container)) { exit 0 }
    & git -C $directory check-ignore -q -- $filePath 2>$null | Out-Null
    if ($LASTEXITCODE -ne 1) { exit 0 }

    $message = "doc-placement: $filePath 本次寫入的內容含本機磁碟機絕對路徑（行號相對於本次寫入的文字）：" +
        ($found -join '；') +
        '。進版控的文件不應含本機路徑。請改用佔位符（如 <sourceRoot>、C:\<使用者>\...）或相對路徑；必須記錄實際路徑時寫入 AGENTS.local.md、CONTEXT.local.md 或 .local 目錄。依 doc-placement skill 判定讀者與落點。'
    Write-Reminder $message
} catch { }
exit 0
