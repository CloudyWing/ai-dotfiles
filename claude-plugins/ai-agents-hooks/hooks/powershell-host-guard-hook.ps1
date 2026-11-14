#Requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# 這是策略提醒，不是安全邊界。偵測採最佳努力，無法涵蓋巢狀 shell（cmd /c powershell.exe）、字串組合執行與別名。
# 任何無法判定的情況（stdin 缺失、JSON 損毀、欄位型別不符、未預期例外）一律放行，不寫入任何檔案。
$allowedScriptName = 'Setup-AIGlobalConfig.ps1'
$optInVariableName = 'AI_AGENTS_ALLOW_POWERSHELL51'
$launcherCommands = @('start-process', 'saps', 'start')
function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
# 取出區段中最後一個 heredoc 的結束標記（<<EOF、<<-EOF、<<'EOF'、<<"EOF"）。$Masked 與 $Real 等長，引號內字元在 $Masked 中以空白取代，用來排除引號內的 <<。
function Get-HeredocDelimiter([string]$Real, [string]$Masked) {
    $delimiter = $null
    foreach ($match in [regex]::Matches($Masked, '(?<!<)<<(?!<)-?\s*')) {
        $rest = $Real.Substring($match.Index + $match.Length)
        $delimiterMatch = [regex]::Match($rest, '^(?:''([^'']+)''|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))')
        if (-not $delimiterMatch.Success) { continue }
        foreach ($groupIndex in 1..3) {
            if ($delimiterMatch.Groups[$groupIndex].Success) { $delimiter = $delimiterMatch.Groups[$groupIndex].Value; break }
        }
    }
    return $delimiter
}
# 以引號感知方式切段。單引號與雙引號內的分隔符不切；雙引號內的跳脫字元（Bash 為反斜線，PowerShell 為反引號）跳脫下一個字元（跳脫的引號不結束引號）；
# 分隔符為 ; | & 與換行（&& 與 || 會切出空段，無害）。heredoc 本文行直到結束標記為止不視為命令區段。
function Split-CommandSegments([string]$Command, [char]$EscapeChar) {
    $segments = New-Object 'System.Collections.Generic.List[string]'
    $builder = New-Object Text.StringBuilder
    $masked = New-Object Text.StringBuilder
    $quote = [char]0
    $pendingDelimiter = $null
    $length = $Command.Length
    $index = 0
    while ($index -lt $length) {
        $char = $Command[$index]
        if ($quote -ne [char]0) {
            if ($quote -eq [char]'"' -and $char -eq $EscapeChar -and $index + 1 -lt $length) {
                [void]$builder.Append($char).Append($Command[$index + 1])
                [void]$masked.Append('  ')
                $index += 2
                continue
            }
            if ($char -eq $quote) { $quote = [char]0; [void]$masked.Append($char) } else { [void]$masked.Append(' ') }
            [void]$builder.Append($char)
            $index++
            continue
        }
        if ($char -eq '"' -or $char -eq "'") {
            $quote = $char
            [void]$builder.Append($char)
            [void]$masked.Append($char)
            $index++
            continue
        }
        if ($char -eq ';' -or $char -eq '|' -or $char -eq '&' -or $char -eq "`n" -or $char -eq "`r") {
            $foundDelimiter = Get-HeredocDelimiter $builder.ToString() $masked.ToString()
            if ($null -ne $foundDelimiter) { $pendingDelimiter = $foundDelimiter }
            $segments.Add($builder.ToString())
            [void]$builder.Clear()
            [void]$masked.Clear()
            $index++
            if ($char -eq "`n" -and $null -ne $pendingDelimiter) {
                $bodyDelimiter = $pendingDelimiter
                $pendingDelimiter = $null
                while ($index -lt $length) {
                    $lineEnd = $Command.IndexOf("`n", $index)
                    if ($lineEnd -lt 0) { $lineEnd = $length }
                    $bodyLine = $Command.Substring($index, $lineEnd - $index).Trim()
                    $index = [Math]::Min($lineEnd + 1, $length)
                    if ($bodyLine -ceq $bodyDelimiter) { break }
                }
            }
            continue
        }
        [void]$builder.Append($char)
        [void]$masked.Append($char)
        $index++
    }
    $segments.Add($builder.ToString())
    return $segments.ToArray()
}
# 以引號感知方式依空白切 token，token 內容不含外層引號字元。
function Split-SegmentTokens([string]$Segment, [char]$EscapeChar) {
    $tokens = New-Object 'System.Collections.Generic.List[string]'
    $builder = New-Object Text.StringBuilder
    $quote = [char]0
    $hasToken = $false
    $escaped = $false
    foreach ($char in $Segment.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($escaped) { [void]$builder.Append($char); $escaped = $false; continue }
            if ($quote -eq [char]'"' -and $char -eq $EscapeChar) { [void]$builder.Append($char); $escaped = $true; continue }
            if ($char -eq $quote) { $quote = [char]0 } else { [void]$builder.Append($char) }
            continue
        }
        if ($char -eq '"' -or $char -eq "'") {
            $quote = $char
            $hasToken = $true
            continue
        }
        if ([char]::IsWhiteSpace($char)) {
            if ($hasToken) { $tokens.Add($builder.ToString()); [void]$builder.Clear(); $hasToken = $false }
            continue
        }
        [void]$builder.Append($char)
        $hasToken = $true
    }
    if ($hasToken) { $tokens.Add($builder.ToString()) }
    return $tokens.ToArray()
}
function Get-TokenFileName([string]$Token) {
    $index = [Math]::Max($Token.LastIndexOf('\'), $Token.LastIndexOf('/'))
    if ($index -ge 0) { return $Token.Substring($index + 1) }
    return $Token
}
function Test-WindowsPowerShellName([string]$Token) {
    $name = (Get-TokenFileName $Token).ToLowerInvariant()
    return $name -eq 'powershell' -or $name -eq 'powershell.exe'
}
function Test-PowerShellExeInvocation([string]$Command, [string]$ToolName) {
    # Bash 以反斜線跳脫雙引號內的字元；PowerShell 以反引號跳脫，反斜線是一般字元（"C:\proj\" 在第二個引號結束）。
    $escapeChar = if ($ToolName -ceq 'PowerShell') { [char]96 } else { [char]92 }
    foreach ($segment in (Split-CommandSegments $Command $escapeChar)) {
        $tokens = @(Split-SegmentTokens $segment $escapeChar)
        $start = 0
        while ($start -lt $tokens.Count -and $tokens[$start] -match '^[A-Za-z_][A-Za-z0-9_]*=') { $start++ }
        if ($start -ge $tokens.Count) { continue }
        $first = $tokens[$start]
        $violation = Test-WindowsPowerShellName $first
        if (-not $violation -and $launcherCommands -contains (Get-TokenFileName $first).ToLowerInvariant()) {
            $target = $null
            for ($i = $start + 1; $i -lt $tokens.Count; $i++) {
                if ($tokens[$i] -ieq '-FilePath') {
                    if ($i + 1 -lt $tokens.Count) { $target = $tokens[$i + 1] }
                    break
                }
                if ($tokens[$i].StartsWith('-')) { continue }
                $target = $tokens[$i]
                break
            }
            $violation = $null -ne $target -and (Test-WindowsPowerShellName $target)
        }
        if (-not $violation) { continue }
        $allowed = $false
        foreach ($token in $tokens) {
            if ((Get-TokenFileName $token) -ieq $allowedScriptName) { $allowed = $true; break }
        }
        if (-not $allowed) { return $true }
    }
    return $false
}
# 拒絕回應以 PreToolUse 的 permissionDecision 輸出。stdout 只輸出 ASCII 位元組、不帶 BOM，
# 非 ASCII 字元以 \uXXXX 跳脫，避免主控台字碼頁影響內容。
function Write-Deny([string]$Reason) {
    $payload = [ordered]@{hookSpecificOutput=[ordered]@{hookEventName='PreToolUse';permissionDecision='deny';permissionDecisionReason=$Reason}}
    $json = $payload | ConvertTo-Json -Compress -Depth 4
    $ascii = [regex]::Replace($json, '[^\u0000-\u007F]', { param($m) '\u' + ([int][char]$m.Value).ToString('x4') })
    $bytes = [Text.Encoding]::ASCII.GetBytes($ascii)
    $out = [Console]::OpenStandardOutput()
    try { $out.Write($bytes, 0, $bytes.Length); $out.Flush() } finally { $out.Dispose() }
}
try {
    if ($env:AI_AGENTS_ALLOW_POWERSHELL51 -eq '1') { exit 0 }
    [Console]::InputEncoding = [Text.Encoding]::UTF8
    $inputText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($inputText)) { exit 0 }
    $inputObject = $inputText | ConvertFrom-Json -ErrorAction Stop
    $toolName = Get-Value $inputObject 'tool_name'
    if ($toolName -isnot [string] -or ($toolName -ne 'Bash' -and $toolName -ne 'PowerShell')) { exit 0 }
    $command = Get-Value (Get-Value $inputObject 'tool_input') 'command'
    if ($command -isnot [string] -or [string]::IsNullOrWhiteSpace($command)) { exit 0 }
    if (-not (Test-PowerShellExeInvocation $command $toolName)) { exit 0 }
    $reason = '禁止直接呼叫 powershell.exe（Windows PowerShell 5.1）。派工與 Claude 端腳本只支援 PowerShell 7，請改用 pwsh：執行腳本檔寫成 pwsh -NoProfile -File <script.ps1>，執行命令寫成 pwsh -NoProfile -Command <command>。唯一的內建例外是 ' + $allowedScriptName + '。其他專案明確要求使用 5.1 時，請在 Claude Code 設定的 env 加入 ' + $optInVariableName + '=1。'
    Write-Deny $reason
    exit 0
}
catch {
    exit 0
}
