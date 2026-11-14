#Requires -Version 7.0

function Get-AccountPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -ne [IO.Path]::GetPathRoot($full)) { $full = $full.TrimEnd([char[]]@('\', '/')) }
    return $full
}

function Get-AccountItem {
    param([string]$Path)
    return Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-AccountItemDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-AccountItem $Path
    if ($null -eq $item) {
        return [pscustomobject]@{ exists = $false; kind = 'Missing'; link_type = $null; target = $null; text = '不存在' }
    }
    $linkTypeProperty = $item.PSObject.Properties['LinkType']
    $targetProperty = $item.PSObject.Properties['Target']
    $linkType = $null
    if ($null -ne $linkTypeProperty -and -not [string]::IsNullOrWhiteSpace([string]$linkTypeProperty.Value)) { $linkType = [string]$linkTypeProperty.Value }
    $target = $null
    if ($null -ne $targetProperty -and $null -ne $targetProperty.Value) { $target = (@($targetProperty.Value) | ForEach-Object { [string]$_ }) -join '; ' }
    $isReparse = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($isReparse) { $kind = 'Link' }
    elseif ($item.PSIsContainer) { $kind = 'Directory' }
    else { $kind = 'File' }
    if ($isReparse) {
        $linkText = $linkType
        if ($null -eq $linkText) { $linkText = '未知' }
        $targetText = $target
        if ($null -eq $targetText) { $targetText = '未知' }
        $text = '連結（LinkType=' + $linkText + '；Target=' + $targetText + '）'
    }
    elseif ($item.PSIsContainer) { $text = '一般目錄' }
    else { $text = '一般檔案' }
    return [pscustomobject]@{ exists = $true; kind = $kind; link_type = $linkType; target = $target; text = $text }
}

function Get-AccountLinkRepairHint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $escaped = $Path.Replace("'", "''")
    return "若為連結，只刪除連結：(Get-Item -LiteralPath '" + $escaped + "' -Force).Delete()；若為一般目錄或檔案，請人工移走後重跑建立腳本。"
}

function New-AccountException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReasonCode,
        [Parameter(Mandatory)][string]$Message,
        [AllowEmptyString()][string]$Path = '',
        [AllowEmptyString()][string]$Detail = ''
    )

    $exception = New-Object System.InvalidOperationException -ArgumentList @($ReasonCode + '：' + $Message)
    $exception.Data['reasonCode'] = $ReasonCode
    $exception.Data['detail'] = $Detail
    $exception.Data['path'] = $Path
    return $exception
}

function Set-AccountAtomicFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [byte[]]$Bytes, [byte[]]$Original)
    if (-not $PSCmdlet.ShouldProcess($Path, '寫入檔案')) { return }
    $temp = Join-Path (Split-Path -Parent $Path) ('.account-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Bytes)
        if ($null -eq $Original) {
            [IO.File]::Move($temp, $Path)
        } else {
            $current = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            try {
                $sha = [Security.Cryptography.SHA256]::Create()
                try {
                    if ([Convert]::ToBase64String($sha.ComputeHash($current)) -cne [Convert]::ToBase64String($sha.ComputeHash($Original))) {
                        $changedException = New-Object System.InvalidOperationException -ArgumentList @("檔案已由外部修改：$Path")
                        $changedException.Data['reasonCode'] = 'CodexAccountConfigChanged'
                        throw $changedException
                    }
                } finally { $sha.Dispose() }
                [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value)
            } finally { $current.Dispose() }
        }
    } finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Read-AccountTomlValue {
    param([string]$Text, [ref]$Offset)
    while ($Offset.Value -lt $Text.Length -and $Text[$Offset.Value] -in @(' ', "`t")) { $Offset.Value++ }
    if ($Offset.Value -ge $Text.Length) { return $false }
    $remaining = $Text.Substring($Offset.Value)
    $first = $Text[$Offset.Value]
    if ($first -eq '[' -or $first -eq '{') {
        $isTable = $first -eq '{'
        $closing = if ($isTable) { '}' } else { ']' }
        $Offset.Value++
        while ($true) {
            while ($Offset.Value -lt $Text.Length -and $Text[$Offset.Value] -in @(' ', "`t")) { $Offset.Value++ }
            if ($Offset.Value -ge $Text.Length) { return $false }
            if ($Text[$Offset.Value] -eq $closing) { $Offset.Value++; return $true }
            if ($isTable) {
                $keyMatch = [regex]::Match($Text.Substring($Offset.Value), '^[A-Za-z0-9_-]+\s*=\s*')
                if (-not $keyMatch.Success) { return $false }
                $Offset.Value += $keyMatch.Length
            }
            if (-not (Read-AccountTomlValue -Text $Text -Offset $Offset)) { return $false }
            while ($Offset.Value -lt $Text.Length -and $Text[$Offset.Value] -in @(' ', "`t")) { $Offset.Value++ }
            if ($Offset.Value -ge $Text.Length) { return $false }
            if ($Text[$Offset.Value] -eq $closing) { $Offset.Value++; return $true }
            if ($Text[$Offset.Value] -ne ',') { return $false }
            $Offset.Value++
            if ($isTable) {
                $next = $Offset.Value
                while ($next -lt $Text.Length -and $Text[$next] -in @(' ', "`t")) { $next++ }
                if ($next -ge $Text.Length -or $Text[$next] -eq $closing) { return $false }
            }
        }
    }
    $pattern = if ($first -eq '"') { '^"(?:[^"\\\x00-\x1f]|\\(?:["\\btnfr]|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}))*"' }
    elseif ($first -eq "'") { "^'[^'\x00-\x1f]*'" }
    else { '^(?:true|false|0x[0-9a-fA-F](?:_?[0-9a-fA-F])*|0o[0-7](?:_?[0-7])*|0b[01](?:_?[01])*|[+-]?(?:inf|nan|(?:0|[1-9](?:_?[0-9])*)(?:\.[0-9](?:_?[0-9])*)?(?:[eE][+-]?[0-9](?:_?[0-9])*)?))' }
    $match = [regex]::Match($remaining, $pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) { return $false }
    $Offset.Value += $match.Length
    return $true
}

function Test-AccountTomlAssignment {
    param([string]$Line)
    $assignment = [regex]::Match($Line, '^\s*[A-Za-z0-9_-]+\s*=\s*')
    if (-not $assignment.Success) { return $false }
    $offset = $assignment.Length
    if (-not (Read-AccountTomlValue -Text $Line -Offset ([ref]$offset))) { return $false }
    while ($offset -lt $Line.Length -and $Line[$offset] -in @(' ', "`t")) { $offset++ }
    return $offset -eq $Line.Length -or $Line[$offset] -eq '#'
}

function Get-AccountConfigPlan {
    param([string]$Path, [string[]]$Keys)
    $item = Get-AccountItem $Path
    $original = $null
    $text = ''
    if ($null -ne $item) {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $description = Get-AccountItemDescription -Path $Path
            throw (New-AccountException -ReasonCode 'CodexAccountConfigLinked' -Path $Path -Detail $description.text -Message ("config.toml 不是一般檔案：$Path；找到：" + $description.text + '；預期：一般檔案。' + (Get-AccountLinkRepairHint -Path $Path)))
        }
        $original = [IO.File]::ReadAllBytes($Path)
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        try { $text = $utf8.GetString($original) }
        catch [System.Text.DecoderFallbackException] { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail 'config.toml 不是有效的 UTF-8' -Message "config.toml 不是有效的 UTF-8：$Path") }
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    }
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $windowsCount = 0; $sandboxCount = 0; $section = ''; $projects = @{}
    $lineNumber = 0
    foreach ($line in ($text -split '\r?\n')) {
        $lineNumber++
        if ($line.Contains('"""') -or $line.Contains("'''")) { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail "$Path`:$lineNumber" -Message "不支援的 TOML 寫法：$Path`:$lineNumber") }
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -cmatch '^\s*\[windows\]\s*(#.*)?$') { $windowsCount++; $section = 'windows'; continue }
        if ($line -cmatch "^\s*\[projects\.'([^']+)'\]\s*(#.*)?$") {
            $key = $Matches[1].ToLowerInvariant()
            if (-not [IO.Path]::IsPathRooted($key) -or $projects.ContainsKey($key)) { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail "$Path`:$lineNumber" -Message "重複或無效的 project 段落：$Path`:$lineNumber") }
            $projects[$key] = @{ count = 0; trusted = $false; line = $lineNumber }; $section = 'project:' + $key; continue
        }
        if ($line -cmatch '^\s*\[') {
            if ($line -match '^\s*\[\s*projects\b' -or $line -cnotmatch '^\s*\[[A-Za-z0-9_.-]+\]\s*(#.*)?$') { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail "$Path`:$lineNumber" -Message "無法辨識的段落：$Path`:$lineNumber") }
            $section = 'other'; continue
        }
        if ($section -eq '' -and $line -cmatch '^\s*(windows|projects)\s*=') { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail "$Path`:$lineNumber" -Message "不支援的 TOML 寫法：$Path`:$lineNumber") }
        if ($section -eq 'windows' -and $line -cmatch '^\s*sandbox\s*=') {
            $sandboxCount++
            if ($line -cnotmatch '^\s*sandbox\s*=\s*"(mxc|elevated)"\s*(#.*)?$') { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail "$Path`:$lineNumber" -Message "無效 sandbox 設定：$Path`:$lineNumber") }
            continue
        }
        if ($section.StartsWith('project:') -and $line -cmatch '^\s*trust_level\s*=') {
            $entry = $projects[$section.Substring(8)]; $entry.count++
            $entry.trusted = $line -cmatch '^\s*trust_level\s*=\s*"trusted"\s*(#.*)?$'
            if (-not $entry.trusted) { $entry.line = $lineNumber }
            continue
        }
        if (-not (Test-AccountTomlAssignment $line)) { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail "$Path`:$lineNumber" -Message "不支援的 TOML 寫法：$Path`:$lineNumber") }
    }
    if ($windowsCount -gt 1 -or ($windowsCount -eq 1 -and $sandboxCount -ne 1)) { throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail $Path -Message "windows 段落不完整或重複：$Path") }
    foreach ($entry in $projects.Values) {
        if ($entry.count -ne 1 -or -not $entry.trusted) {
            throw (New-AccountException -ReasonCode 'CodexAccountConfigUnsupported' -Path $Path -Detail "$Path`:$($entry.line)" -Message ("project trust 設定不完整或衝突：$Path`:" + $entry.line + '；既有的非 trusted 設定視為使用者的決定，腳本不覆寫，請人工修正。'))
        }
    }
    $append = ''
    $windowsAdded = $false
    if ($windowsCount -eq 0) { $append += "[windows]${newline}sandbox = `"mxc`"${newline}"; $windowsAdded = $true }
    $missing = @($Keys | Where-Object { -not $projects.ContainsKey($_) })
    foreach ($key in $missing) { $append += "${newline}[projects.'$key']${newline}trust_level = `"trusted`"${newline}" }
    if ($append -and $text -and -not $text.EndsWith("`n")) { $append = $newline + $append }
    [byte[]]$base = @()
    if ($null -ne $original) { $base = $original }
    $extra = [Text.Encoding]::UTF8.GetBytes($append)
    $bytes = New-Object byte[] ($base.Length + $extra.Length)
    [Array]::Copy($base, 0, $bytes, 0, $base.Length); [Array]::Copy($extra, 0, $bytes, $base.Length, $extra.Length)
    return @{ Original = $original; Bytes = $bytes; Changed = ($append.Length -gt 0); Missing = $missing; WindowsAdded = $windowsAdded }
}

function Open-CodexAccountLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LockPath,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30
    )

    $lockDirectory = Split-Path -Parent $LockPath
    if (-not [IO.Directory]::Exists($lockDirectory)) {
        throw (New-AccountException -ReasonCode 'CodexAccountTrustLockTimeout' -Path $LockPath -Message "帳號設定鎖所在目錄不存在：$LockPath")
    }
    $started = [DateTime]::UtcNow
    $deadline = $started.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $stream = New-Object System.IO.FileStream -ArgumentList @($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            return [pscustomobject]@{ Stream = $stream; LockPath = $LockPath; WaitMilliseconds = [int]([DateTime]::UtcNow - $started).TotalMilliseconds }
        }
        catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 100
        }
    }
    throw (New-AccountException -ReasonCode 'CodexAccountTrustLockTimeout' -Path $LockPath -Message "等待帳號設定鎖逾時：$LockPath")
}

function Test-AccountTrustReadiness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$TrustKey
    )

    $result = [ordered]@{
        ready = $false
        deferred = $false
        already_trusted = $false
        reason_code = $null
        config_path = $ConfigPath
        detail = $null
    }
    $item = Get-AccountItem $ConfigPath
    if ($null -eq $item) {
        $result.reason_code = 'TrustConfigMissing'
        $result.detail = 'config.toml 不存在'
        return [pscustomobject]$result
    }
    try {
        $plan = Get-AccountConfigPlan -Path $ConfigPath -Keys @($TrustKey)
    }
    catch [System.IO.IOException] {
        $result.ready = $true
        $result.deferred = $true
        $result.detail = $_.Exception.Message
        return [pscustomobject]$result
    }
    catch {
        $exceptionReason = [string]$_.Exception.Data['reasonCode']
        if ($exceptionReason -ceq 'CodexAccountConfigLinked') { $result.reason_code = 'TrustConfigLinked' }
        elseif ($exceptionReason -ceq 'CodexAccountConfigUnsupported') { $result.reason_code = 'TrustConfigUnsupported' }
        else { $result.reason_code = 'TrustConfigUnsupported' }
        $detailValue = [string]$_.Exception.Data['detail']
        if ([string]::IsNullOrWhiteSpace($detailValue)) { $detailValue = $_.Exception.Message }
        $result.detail = $detailValue
        return [pscustomobject]$result
    }
    $result.ready = $true
    $result.already_trusted = -not [bool]$plan.Changed
    return [pscustomobject]$result
}
