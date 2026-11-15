#Requires -Version 7.0

<#
.SYNOPSIS
依執行者登錄表為任務選出派工執行者，唯讀輸出單一 JSON 物件。

.DESCRIPTION
驗證任務標註（類型、旗標、標籤、實作者家族、離線清單），讀取
scripts\dispatch\executor-registry.json，依固定演算法選出執行者並產生 [派工判定] 行。
登錄表的讀取與結構驗證載入同目錄 lib\executor-registry.ps1（產生器、Setup、帳號建立與派工前比對共用同一份）。
腳本與該檔都不寫檔、不呼叫網路、不讀取環境變數，同輸入與同登錄表的輸出完全相同。

結束碼：0 為 selected 或 degraded；10 為 escalation-candidate；20 為 needs-authorization；
21 為 wait-reset；22 為 stopped；2 為標註無效；3 為登錄表不存在或無效；
1 為內部錯誤，或 lib\executor-registry.ps1 不存在或無法載入（SelectorRegistryLibraryUnavailable）。
標註無效與登錄表無效時，stderr 首段格式為「Code：訊息」。
結束碼 2 的錯誤碼含 SelectorParameterBinding：多值參數以空白分隔時，多餘的值會成為位置參數，
腳本以此錯誤碼回報；-Tags 與 -Offline 的多個值請以逗號連接且不含空白。

.PARAMETER Type
任務類型，值域由登錄表 types 決定。

.PARAMETER E
旗標 E（範圍已列舉），值為 true 或 false，僅該類型要求時提供。

.PARAMETER T
旗標 T（需要測試循環），值為 true 或 false，僅該類型要求時提供。

.PARAMETER Deep
已移除的旗標。type=review 不再依旗標選擇檔位，傳入此參數（任何值、任何類型）時以 SelectorFlagRemoved 結束碼 2 拒絕。

.PARAMETER Tags
任務所需的硬能力標籤，可用逗號分隔多個。

.PARAMETER ImplementerFamily
實作者家族，claude 或 codex。types 設定 crossFamily 的類型必填。

.PARAMETER Authorized
使用者已授權 gated 執行者。

.PARAMETER Offline
經服務端拒絕且確認的離線執行者 id，可用逗號分隔多個。

.PARAMETER EscalateFrom
失敗升級的原執行者 id。提供時改走升級路徑。

.PARAMETER Label
附在 dispatchLine 的任務說明。

.PARAMETER RegistryPath
登錄表路徑，預設為 scripts\dispatch\executor-registry.json。

.PARAMETER Describe
輸出登錄表的標籤詞彙、類型、旗標需求與執行者摘要，不做選擇。
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Type,
    [string]$E,
    [string]$T,
    [string]$Deep,
    [string[]]$Tags,
    [string]$ImplementerFamily,
    [switch]$Authorized,
    [string[]]$Offline,
    [string]$EscalateFrom,
    [string]$Label,
    [string]$RegistryPath,
    [switch]$Describe,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgument
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SelectionSchema = 'ai-agents.executor-selection.v1'
$script:DescribeSchema = 'ai-agents.executor-describe.v1'
$script:DeepFlagProvided = $PSBoundParameters.ContainsKey('Deep')

# 登錄表的讀取與結構驗證在 lib\executor-registry.ps1，這是本腳本唯一載入的檔案，以本腳本所在位置為基準，
# 不受呼叫端工作目錄影響。檔案不存在或無法解析時以 SelectorRegistryLibraryUnavailable 結束碼 1 結束。
$script:RegistryLibraryPath = Join-Path -Path $PSScriptRoot -ChildPath 'lib\executor-registry.ps1'
try {
    if (-not (Test-Path -LiteralPath $script:RegistryLibraryPath -PathType Leaf)) { throw ('檔案不存在：{0}' -f $script:RegistryLibraryPath) }
    . $script:RegistryLibraryPath
}
catch {
    $loadMessage = 'SelectorRegistryLibraryUnavailable：無法載入登錄表共用函式檔 {0}：{1}' -f $script:RegistryLibraryPath, $_.Exception.Message
    if ($MyInvocation.InvocationName -eq '.') { throw $loadMessage }
    [Console]::Error.WriteLine($loadMessage)
    exit 1
}

function New-SelectorError {
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    $exception = New-Object -TypeName System.Exception -ArgumentList ('{0}：{1}' -f $Code, $Message)
    $exception.Data['Code'] = $Code
    $exception.Data['ExitCode'] = $ExitCode
    return $exception
}

function Split-ListArgument {
    param([string[]]$Value)

    $result = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        foreach ($part in ($item -split '[,;\s]+')) {
            if (-not [string]::IsNullOrWhiteSpace($part) -and -not $result.Contains($part)) { $result.Add($part) }
        }
    }
    return , $result.ToArray()
}

function ConvertTo-AsciiJson {
    param([string]$Json)

    return [regex]::Replace($Json, '[^\u0000-\u007F]', [System.Text.RegularExpressions.MatchEvaluator] { param($match) '\u{0:x4}' -f [int][char]$match.Value[0] })
}

function ConvertTo-FlagValue {
    param([string]$Name, [string]$Value)

    if ($Value -ieq 'true') { return $true }
    if ($Value -ieq 'false') { return $false }
    throw (New-SelectorError -Code 'SelectorFlagMissing' -Message ('旗標 {0} 的值必須為 true 或 false：{1}' -f $Name, $Value) -ExitCode 2)
}

function Get-ExclusionReason {
    param($Executor, $TypeDef, [string]$TypeName, $Flags, [string[]]$EffectiveTags, [string]$ImplementerFamily, [bool]$CheckFamily, [bool]$AllowEscalationOnly)

    if ($Executor.EscalationOnly -and -not $AllowEscalationOnly) { return 'escalation-only' }
    if ($Executor.Accepts -notcontains $TypeName) { return 'type-not-accepted' }
    $missing = @($EffectiveTags | Where-Object { $Executor.Tags -notcontains $_ })
    if ($missing.Count -gt 0) { return ('tag-missing:{0}' -f ($missing -join ',')) }
    foreach ($key in $Executor.When.Keys) {
        if (-not $Flags.ContainsKey($key) -or $Flags[$key] -ne $Executor.When[$key]) { return ('when-mismatch:{0}' -f $key) }
    }
    if ($CheckFamily -and $TypeDef.CrossFamily -and $Executor.Family -eq $ImplementerFamily) { return 'same-family' }
    return $null
}

function Get-ExecutorSelection {
    param($Registry, [string]$TypeName, $Flags, [string[]]$EffectiveTags, [string]$ImplementerFamily, [bool]$IsAuthorized, [string[]]$OfflineIds, [string]$EscalateFromId)

    $typeDef = $Registry.Types[$TypeName]
    $executors = @($Registry.Executors)
    $relaxFamily = ($typeDef.Degradable -contains 'family')
    $reasons = @{}
    $chosen = $null
    $status = $null
    $reason = $null
    $degradations = @()

    if (-not [string]::IsNullOrWhiteSpace($EscalateFromId)) {
        $chain = New-Object 'System.Collections.Generic.List[string]'
        $next = $Registry.ById[$EscalateFromId].EscalatesTo
        while ($null -ne $next) {
            $chain.Add($next)
            $next = $Registry.ById[$next].EscalatesTo
        }
        foreach ($executor in $executors) {
            if (-not $chain.Contains($executor.Id)) { $reasons[$executor.Id] = 'not-in-escalation-chain'; continue }
            $excluded = Get-ExclusionReason -Executor $executor -TypeDef $typeDef -TypeName $TypeName -Flags $Flags -EffectiveTags $EffectiveTags -ImplementerFamily $ImplementerFamily -CheckFamily $false -AllowEscalationOnly $true
            if ($null -eq $excluded -and $OfflineIds -contains $executor.Id) { $excluded = 'offline' }
            if ($null -ne $excluded) { $reasons[$executor.Id] = $excluded } else { $reasons[$executor.Id] = 'eligible-lower-priority' }
        }
        foreach ($id in $chain) {
            if ($reasons[$id] -eq 'eligible-lower-priority') { $chosen = $Registry.ById[$id]; break }
        }
        if ($null -ne $chosen) {
            $status = 'escalation-candidate'
            $reason = 'escalation-chain'
            $reasons[$chosen.Id] = 'escalation-candidate'
            if ($typeDef.CrossFamily -and $chosen.Family -eq $ImplementerFamily) { $degradations = @('同家族審查') }
        }
        else {
            $status = 'stopped'
            $reason = 'no-escalation'
        }
    }
    else {
        $strict = @{}
        $relaxed = @{}
        foreach ($executor in $executors) {
            $strict[$executor.Id] = Get-ExclusionReason -Executor $executor -TypeDef $typeDef -TypeName $TypeName -Flags $Flags -EffectiveTags $EffectiveTags -ImplementerFamily $ImplementerFamily -CheckFamily $true -AllowEscalationOnly $false
            $relaxed[$executor.Id] = Get-ExclusionReason -Executor $executor -TypeDef $typeDef -TypeName $TypeName -Flags $Flags -EffectiveTags $EffectiveTags -ImplementerFamily $ImplementerFamily -CheckFamily (-not $relaxFamily) -AllowEscalationOnly $false
        }
        $c0Online = @($executors | Where-Object { $null -eq $strict[$_.Id] -and $OfflineIds -notcontains $_.Id })
        if ($c0Online.Count -gt 0) {
            $chosen = $c0Online[0]
            if ($chosen.Gated -and -not $IsAuthorized) { $status = 'needs-authorization'; $reason = 'authorization-required' }
            else { $status = 'selected'; $reason = 'lowest-order-eligible' }
        }
        elseif (@($typeDef.Degradable).Count -gt 0) {
            $c1 = @($executors | Where-Object { $null -eq $relaxed[$_.Id] -and $OfflineIds -notcontains $_.Id })
            if ($c1.Count -gt 0) {
                $chosen = $c1[0]
                $status = 'degraded'
                $reason = 'family-relaxed'
                $degradations = @('同家族審查')
            }
        }
        if ($null -eq $chosen) {
            $q = @($executors | Where-Object { $null -eq $relaxed[$_.Id] })
            if ($q.Count -eq 0) {
                $status = 'stopped'
                $reason = 'no-eligible-executor'
            }
            else {
                $action = 'stop'
                if ($null -ne $q[0].OnOffline -and $q[0].OnOffline.Contains($TypeName)) { $action = $q[0].OnOffline[$TypeName] }
                if ($action -eq 'wait-reset') { $status = 'wait-reset' } else { $status = 'stopped' }
                $reason = 'offline'
            }
        }
        foreach ($executor in $executors) {
            if ($null -ne $chosen -and $executor.Id -eq $chosen.Id) {
                if ($status -eq 'degraded') { $reasons[$executor.Id] = 'degraded' } else { $reasons[$executor.Id] = 'selected' }
                continue
            }
            $base = $strict[$executor.Id]
            if ($status -eq 'degraded') { $base = $relaxed[$executor.Id] }
            if ($null -ne $base) { $reasons[$executor.Id] = $base }
            elseif ($OfflineIds -contains $executor.Id) { $reasons[$executor.Id] = 'offline' }
            else { $reasons[$executor.Id] = 'eligible-lower-priority' }
        }
    }

    $considered = @()
    foreach ($executor in $executors) {
        $considered += , ([ordered]@{ id = $executor.Id; reason = $reasons[$executor.Id] })
    }
    return [pscustomobject]@{
        Status       = $status
        Executor     = $chosen
        Degradations = $degradations
        Reason       = $reason
        Considered   = $considered
    }
}

function Format-YesNo {
    param([bool]$Value)

    if ($Value) { return '是' }
    return '否'
}

function Get-DispatchLine {
    param($Selection, [string]$TypeName, $TypeDef, $Flags, [string]$LabelText)

    $judgement = switch ($Selection.Status) {
        'selected' { '登錄表→{0}' -f $Selection.Executor.Id }
        'degraded' { '登錄表→{0}' -f $Selection.Executor.Id }
        'needs-authorization' { '登錄表→待授權' }
        'wait-reset' { '登錄表→等待重設' }
        'stopped' { '登錄表→停止' }
        'escalation-candidate' { '登錄表→升級候選 {0}' -f $Selection.Executor.Id }
    }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($LabelText)) { $parts.Add($LabelText.Trim()) }
    $parts.Add(('type={0}' -f $TypeName))
    foreach ($flag in @($TypeDef.RequiredFlags)) { $parts.Add(('{0}={1}' -f $flag, (Format-YesNo $Flags[$flag]))) }
    if ($null -ne $Selection.Executor) { $parts.Add(('執行者={0}' -f $Selection.Executor.Display)) }
    else { $parts.Add('執行者=無') }
    $line = '[派工判定: {0}] {1}' -f $judgement, ($parts -join ' ')
    if ($Selection.Status -eq 'degraded' -or ($Selection.Status -eq 'escalation-candidate' -and @($Selection.Degradations).Count -gt 0)) { $line += ' 降級=同家族審查' }
    return $line
}

function Get-StatusExitCode {
    param([string]$Status)

    switch ($Status) {
        'selected' { return 0 }
        'degraded' { return 0 }
        'escalation-candidate' { return 10 }
        'needs-authorization' { return 20 }
        'wait-reset' { return 21 }
        'stopped' { return 22 }
    }
    return 1
}

function Get-DescribeDocument {
    param($Registry)

    $typeRows = @()
    foreach ($type in $Registry.Types.Values) {
        $typeRows += , ([ordered]@{
                name          = $type.Name
                requiredFlags = @($type.RequiredFlags)
                impliedTags   = @($type.ImpliedTags)
                forbiddenTags = @($type.ForbiddenTags)
                crossFamily   = $type.CrossFamily
                degradable    = @($type.Degradable)
            })
    }
    $executorRows = @()
    foreach ($executor in $Registry.Executors) {
        $row = [ordered]@{
            id             = $executor.Id
            display        = $executor.Display
            platform       = $executor.Platform
            accepts        = @($executor.Accepts)
            tags           = @($executor.Tags)
            when           = $executor.When
            order          = $executor.Order
            gated          = $executor.Gated
            escalationOnly = $executor.EscalationOnly
            escalatesTo    = $executor.EscalatesTo
        }
        if ($executor.Platform -eq 'claude') { $row['model'] = $executor.Model } else { $row['profile'] = $executor.Profile; $row['entry'] = $executor.Entry; $row['profileSettings'] = $executor.ProfileSettings }
        $executorRows += , $row
    }
    return [ordered]@{
        schema    = $script:DescribeSchema
        tags      = [ordered]@{ hard = @($Registry.HardTags); constraint = @($Registry.Constraint) }
        flags     = @($Registry.Flags)
        types     = $typeRows
        executors = $executorRows
    }
}

function Invoke-Selector {
    if ($script:DeepFlagProvided) {
        throw (New-SelectorError -Code 'SelectorFlagRemoved' -Message '旗標 Deep 已移除，type=review 不再依旗標選擇檔位，請移除 -Deep。' -ExitCode 2)
    }
    if ($null -ne $RemainingArgument -and @($RemainingArgument).Count -gt 0) {
        throw (New-SelectorError -Code 'SelectorParameterBinding' -Message ('偵測到多餘的位置參數：{0}。-Tags 與 -Offline 的多個值請以逗號連接且不含空白，例如 -Offline codex-scan,codex-review' -f (@($RemainingArgument) -join ' ')) -ExitCode 2)
    }
    $path = $RegistryPath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path -Path $PSScriptRoot -ChildPath 'dispatch\executor-registry.json' }
    $registry = Read-ExecutorRegistry -Path $path

    if ($Describe) {
        return [pscustomobject]@{ Json = (ConvertTo-AsciiJson -Json ((Get-DescribeDocument -Registry $registry) | ConvertTo-Json -Depth 6)); ExitCode = 0 }
    }

    if ([string]::IsNullOrWhiteSpace($Type) -or -not $registry.Types.Contains($Type)) {
        throw (New-SelectorError -Code 'SelectorTypeInvalid' -Message ('未知的任務類型：{0}。可用類型：{1}' -f $Type, (@($registry.Types.Keys) -join ', ')) -ExitCode 2)
    }
    $typeDef = $registry.Types[$Type]

    $provided = [ordered]@{ E = $E; T = $T }
    $flags = @{}
    foreach ($flag in @($registry.Flags)) {
        $value = $null
        if ($provided.Contains($flag)) { $value = $provided[$flag] }
        $isRequired = ($typeDef.RequiredFlags -contains $flag)
        $isProvided = -not [string]::IsNullOrWhiteSpace($value)
        if ($isRequired -and -not $isProvided) {
            throw (New-SelectorError -Code 'SelectorFlagMissing' -Message ('類型 {0} 必須提供旗標 {1}' -f $Type, $flag) -ExitCode 2)
        }
        if (-not $isRequired -and $isProvided) {
            throw (New-SelectorError -Code 'SelectorFlagNotAllowed' -Message ('類型 {0} 不接受旗標 {1}' -f $Type, $flag) -ExitCode 2)
        }
        if ($isProvided) { $flags[$flag] = ConvertTo-FlagValue -Name $flag -Value $value }
    }

    $requestedTags = Split-ListArgument -Value $Tags
    foreach ($tag in $requestedTags) {
        if (@($registry.HardTags) -cnotcontains $tag) {
            throw (New-SelectorError -Code 'SelectorTagInvalid' -Message ('未知的硬能力標籤：{0}。可用標籤：{1}' -f $tag, (@($registry.HardTags) -join ', ')) -ExitCode 2)
        }
        if ($typeDef.ForbiddenTags -contains $tag) {
            throw (New-SelectorError -Code 'SelectorTagNotAllowed' -Message ('類型 {0} 不得使用標籤 {1}' -f $Type, $tag) -ExitCode 2)
        }
    }
    $effectiveTags = @($registry.HardTags | Where-Object { $requestedTags -contains $_ -or $typeDef.ImpliedTags -contains $_ })

    if ($typeDef.CrossFamily -and ($ImplementerFamily -cne 'claude' -and $ImplementerFamily -cne 'codex')) {
        throw (New-SelectorError -Code 'SelectorFamilyRequired' -Message ('類型 {0} 必須提供 -ImplementerFamily（claude 或 codex）' -f $Type) -ExitCode 2)
    }

    $offlineIds = Split-ListArgument -Value $Offline
    foreach ($id in $offlineIds) {
        if (-not $registry.ById.ContainsKey($id)) {
            throw (New-SelectorError -Code 'SelectorExecutorUnknown' -Message ('-Offline 含未知的執行者 id：{0}' -f $id) -ExitCode 2)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($EscalateFrom) -and -not $registry.ById.ContainsKey($EscalateFrom)) {
        throw (New-SelectorError -Code 'SelectorExecutorUnknown' -Message ('-EscalateFrom 為未知的執行者 id：{0}' -f $EscalateFrom) -ExitCode 2)
    }

    $selection = Get-ExecutorSelection -Registry $registry -TypeName $Type -Flags $flags -EffectiveTags $effectiveTags -ImplementerFamily $ImplementerFamily -IsAuthorized ([bool]$Authorized) -OfflineIds $offlineIds -EscalateFromId $EscalateFrom

    $labels = [ordered]@{}
    foreach ($flag in @($registry.Flags)) { if ($flags.ContainsKey($flag)) { $labels[$flag] = $flags[$flag] } }
    $labels['tags'] = @($effectiveTags)
    if ($typeDef.CrossFamily) { $labels['implementerFamily'] = $ImplementerFamily } else { $labels['implementerFamily'] = $null }
    $labels['authorized'] = [bool]$Authorized
    $labels['offline'] = @($offlineIds)
    if ([string]::IsNullOrWhiteSpace($EscalateFrom)) { $labels['escalateFrom'] = $null } else { $labels['escalateFrom'] = $EscalateFrom }

    $executorNode = $null
    if ($null -ne $selection.Executor) {
        $executorNode = [ordered]@{ id = $selection.Executor.Id; display = $selection.Executor.Display; platform = $selection.Executor.Platform }
        if ($selection.Executor.Platform -eq 'claude') { $executorNode['model'] = $selection.Executor.Model } else { $executorNode['profile'] = $selection.Executor.Profile; $executorNode['entry'] = $selection.Executor.Entry }
        $executorNode['order'] = $selection.Executor.Order
    }
    $document = [ordered]@{
        schema               = $script:SelectionSchema
        status               = $selection.Status
        type                 = $Type
        labels               = $labels
        executor             = $executorNode
        degradations         = @($selection.Degradations)
        requiresUserDecision = ($selection.Status -eq 'escalation-candidate')
        reason               = $selection.Reason
        considered           = @($selection.Considered)
        dispatchLine         = (Get-DispatchLine -Selection $selection -TypeName $Type -TypeDef $typeDef -Flags $flags -LabelText $Label)
    }
    return [pscustomobject]@{ Json = (ConvertTo-AsciiJson -Json ($document | ConvertTo-Json -Depth 6)); ExitCode = (Get-StatusExitCode -Status $selection.Status) }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $result = Invoke-Selector
        Write-Output $result.Json
        exit $result.ExitCode
    }
    catch {
        if (-not $_.Exception.Data.Contains('Code')) {
            [Console]::Error.WriteLine(('SelectorInternalError：{0}' -f $_.Exception.Message))
            exit 1
        }
        [Console]::Error.WriteLine($_.Exception.Message)
        exit $_.Exception.Data['ExitCode']
    }
}
