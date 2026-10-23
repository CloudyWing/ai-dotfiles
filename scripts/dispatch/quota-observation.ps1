

function Get-OptionalObjectProperty {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) {
            return $null
        }
        Write-Output -NoEnumerate -InputObject $Object[$Name]
        return
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    Write-Output -NoEnumerate -InputObject $property.Value
}

function Get-AdvisorActivationDecision {
    param([Parameter(Mandatory)][ValidateSet('user-explicit')][string]$RequestSource)
    return [ordered]@{
        granted = $true
        activationMode = 'user-authorized'
        authorizationSource = $RequestSource
        reserveBypassed = $false
        minimumUnitOverBudget = $false
        reasonCode = $null
        notice = 'advisor 已由呼叫端提供使用者明確授權。'
        requiredAuthorization = $null
        hardLimitPercent = $null
        remainingPercent = $null
    }
}

function Get-LatestSafePointMessage {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [AllowNull()]
        [string]$TaskType
    )

    $latest = ''
    if (-not (Test-Path -LiteralPath $EventPath -PathType Leaf)) {
        return $latest
    }
    foreach ($line in Get-Content -LiteralPath $EventPath -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        $item = Get-OptionalObjectProperty -Object $event -Name 'item'
        if ($null -eq $item -or (Get-OptionalObjectProperty -Object $item -Name 'type') -ne 'agent_message') {
            continue
        }
        $message = Get-OptionalObjectProperty -Object $item -Name 'text'
        if ($message -is [string] -and (Test-SafePointMessage -Message $message -TaskType $TaskType)) {
            $latest = $message
        }
    }
    return $latest
}

function Test-SafePointMessage {
    param(
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [string]$TaskType
    )

    if ([string]::IsNullOrWhiteSpace($Message) -or -not $Message.Contains('## 中斷保全結論')) {
        return $false
    }
    $sectionMatch = [regex]::Match($Message, '(?ms)^##\s+中斷保全結論\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
    if (-not $sectionMatch.Success -or [string]::IsNullOrWhiteSpace($sectionMatch.Groups['body'].Value)) {
        return $false
    }
    $body = $sectionMatch.Groups['body'].Value
    $requiredPatterns = @(
            '(?m)已確認結論\s*[:：]\s*\S+',
            '(?m)證據位置\s*[:：]\s*\S+',
            '(?m)實際覆蓋範圍\s*[:：]\s*\S+'
        )
    if ($TaskType -eq 'advisor-consult') {
        $requiredPatterns += '(?m)已完成單位\s*[:：]\s*\S+'
    }
    foreach ($requiredPattern in $requiredPatterns) {
        if ($body -notmatch $requiredPattern) {
            return $false
        }
    }
    return $true
}

function Resolve-CodexHomePath {
    param(
        [string]$ConfiguredCodexHome
    )

    $configuredPath = $ConfiguredCodexHome
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        $configuredPath = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        $userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            throw '無法判定使用者 Profile 路徑，請提供 CodexHome 或設定 CODEX_HOME。'
        }
        $configuredPath = Join-Path -Path $userProfile -ChildPath '.codex'
    }

    $path = Resolve-AbsolutePath -Path $configuredPath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "CodexHome 不存在或不是目錄：$path"
    }

    return $path
}

