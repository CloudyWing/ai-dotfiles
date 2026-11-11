#Requires -Version 5.1

<#
.SYNOPSIS
依執行者登錄表為任務選出派工執行者，唯讀輸出單一 JSON 物件。

.DESCRIPTION
驗證任務標註（類型、旗標、標籤、實作者家族、離線清單），讀取
scripts\dispatch\executor-registry.json，依固定演算法選出執行者並產生 [派工判定] 行。
腳本不寫檔、不呼叫網路、不讀取環境變數，同輸入與同登錄表的輸出完全相同。

結束碼：0 為 selected 或 degraded；10 為 escalation-candidate；20 為 needs-authorization；
21 為 wait-reset；22 為 stopped；2 為標註無效；3 為登錄表不存在或無效。
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
旗標 Deep（大範圍審查），值為 true 或 false，僅該類型要求時提供。

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

$script:RegistrySchema = 'ai-agents.executor-registry.v1'
$script:SelectionSchema = 'ai-agents.executor-selection.v1'
$script:DescribeSchema = 'ai-agents.executor-describe.v1'
$script:CodexProfileNames = @('review', 'deep-review', 'scan', 'advisor')
$script:OfflineActions = @('fallback', 'degrade', 'stop', 'wait-reset')
$script:MaxTagVocabulary = 8

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

function Get-Prop {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ListProp {
    param($Object, [string]$Name)

    $value = Get-Prop -Object $Object -Name $Name
    if ($null -eq $value) { return , @() }
    return , @($value)
}

function Test-StringArray {
    param($Value)

    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) { return $false }
    }
    return $true
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

function Read-ExecutorRegistry {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-SelectorError -Code 'SelectorRegistryNotFound' -Message ('登錄表不存在：{0}' -f $Path) -ExitCode 3)
    }
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw (New-SelectorError -Code 'SelectorRegistryInvalid' -Message ('登錄表為空：{0}' -f $Path) -ExitCode 3)
    }
    try {
        $raw = $text | ConvertFrom-Json
    }
    catch {
        throw (New-SelectorError -Code 'SelectorRegistryInvalid' -Message ('登錄表不是有效的 JSON：{0}' -f $_.Exception.Message) -ExitCode 3)
    }
    return (ConvertTo-ValidatedRegistry -Raw $raw)
}

function ConvertTo-ValidatedRegistry {
    param($Raw)

    $fail = {
        param([string]$Message)
        throw (New-SelectorError -Code 'SelectorRegistryInvalid' -Message $Message -ExitCode 3)
    }

    if ((Get-Prop $Raw 'schema') -ne $script:RegistrySchema) { & $fail ('schema 必須為 {0}' -f $script:RegistrySchema) }

    $tagsNode = Get-Prop $Raw 'tags'
    $hard = Get-ListProp $tagsNode 'hard'
    $constraint = Get-ListProp $tagsNode 'constraint'
    if ($hard.Count -eq 0 -or -not (Test-StringArray $hard)) { & $fail 'tags.hard 必須為非空字串陣列' }
    if ($constraint.Count -eq 0 -or -not (Test-StringArray $constraint)) { & $fail 'tags.constraint 必須為非空字串陣列' }
    $allTags = @($hard) + @($constraint)
    if ($allTags.Count -gt $script:MaxTagVocabulary) { & $fail ('標籤詞彙合計 {0} 個，超過上限 {1}' -f $allTags.Count, $script:MaxTagVocabulary) }
    if (@($allTags | Select-Object -Unique).Count -ne $allTags.Count) { & $fail '標籤詞彙有重複' }

    $flags = Get-ListProp $Raw 'flags'
    if ($flags.Count -eq 0 -or -not (Test-StringArray $flags) -or @($flags | Select-Object -Unique).Count -ne $flags.Count) { & $fail 'flags 必須為非空且不重複的字串陣列' }

    $typesNode = Get-Prop $Raw 'types'
    if ($null -eq $typesNode -or @($typesNode.PSObject.Properties).Count -eq 0) { & $fail 'types 不得為空' }
    $types = [ordered]@{}
    foreach ($property in $typesNode.PSObject.Properties) {
        $name = $property.Name
        $node = $property.Value
        $required = Get-ListProp $node 'requiredFlags'
        $implied = Get-ListProp $node 'impliedTags'
        $forbidden = Get-ListProp $node 'forbiddenTags'
        $degradable = Get-ListProp $node 'degradable'
        foreach ($flag in $required) { if ($flags -notcontains $flag) { & $fail ('types.{0}.requiredFlags 含未知旗標 {1}' -f $name, $flag) } }
        foreach ($tag in $implied) { if ($hard -notcontains $tag) { & $fail ('types.{0}.impliedTags 含未知硬能力 {1}' -f $name, $tag) } }
        foreach ($tag in $forbidden) { if ($hard -notcontains $tag) { & $fail ('types.{0}.forbiddenTags 含未知硬能力 {1}' -f $name, $tag) } }
        foreach ($tag in $degradable) { if ($constraint -notcontains $tag) { & $fail ('types.{0}.degradable 含未知約束 {1}' -f $name, $tag) } }
        $crossFamily = Get-Prop $node 'crossFamily'
        if ($null -ne $crossFamily -and $crossFamily -isnot [bool]) { & $fail ('types.{0}.crossFamily 必須為布林' -f $name) }
        $types[$name] = [pscustomobject]@{
            Name          = $name
            RequiredFlags = $required
            ImpliedTags   = $implied
            ForbiddenTags = $forbidden
            CrossFamily   = ($crossFamily -eq $true)
            Degradable    = $degradable
        }
    }

    $executorNodes = Get-ListProp $Raw 'executors'
    if ($executorNodes.Count -eq 0) { & $fail 'executors 不得為空' }
    $executors = New-Object 'System.Collections.Generic.List[object]'
    $ids = @{}
    $orders = @{}
    foreach ($node in $executorNodes) {
        $id = Get-Prop $node 'id'
        if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) { & $fail 'executors[].id 必須為非空字串' }
        if ($ids.ContainsKey($id)) { & $fail ('執行者 id 重複：{0}' -f $id) }
        $ids[$id] = $true
        $order = Get-Prop $node 'order'
        if ($order -isnot [int] -and $order -isnot [long]) { & $fail ('執行者 {0} 的 order 必須為整數' -f $id) }
        if ($orders.ContainsKey([long]$order)) { & $fail ('排序值重複：{0}' -f $order) }
        $orders[[long]$order] = $true
        $platform = Get-Prop $node 'platform'
        if ($platform -ne 'claude' -and $platform -ne 'codex') { & $fail ('執行者 {0} 的 platform 必須為 claude 或 codex' -f $id) }
        $model = Get-Prop $node 'model'
        $profile = Get-Prop $node 'profile'
        if ($platform -eq 'claude' -and ($model -isnot [string] -or [string]::IsNullOrWhiteSpace($model))) { & $fail ('執行者 {0} 缺少 model' -f $id) }
        if ($platform -eq 'codex') {
            if ($profile -isnot [string] -or [string]::IsNullOrWhiteSpace($profile)) { & $fail ('執行者 {0} 缺少 profile' -f $id) }
            if ($script:CodexProfileNames -cnotcontains $profile) { & $fail ('執行者 {0} 的 profile {1} 不在 Codex 檔位白名單內' -f $id, $profile) }
        }
        $display = Get-Prop $node 'display'
        $family = Get-Prop $node 'family'
        if ($display -isnot [string] -or [string]::IsNullOrWhiteSpace($display)) { & $fail ('執行者 {0} 缺少 display' -f $id) }
        if ($family -isnot [string] -or [string]::IsNullOrWhiteSpace($family)) { & $fail ('執行者 {0} 缺少 family' -f $id) }
        $accepts = Get-ListProp $node 'accepts'
        if ($accepts.Count -eq 0 -or -not (Test-StringArray $accepts)) { & $fail ('執行者 {0} 的 accepts 必須為非空字串陣列' -f $id) }
        foreach ($accept in $accepts) { if (-not $types.Contains($accept)) { & $fail ('執行者 {0} 受理未知類型 {1}' -f $id, $accept) } }
        $tags = Get-ListProp $node 'tags'
        if (-not (Test-StringArray $tags)) { & $fail ('執行者 {0} 的 tags 必須為字串陣列' -f $id) }
        foreach ($tag in $tags) { if ($hard -notcontains $tag) { & $fail ('執行者 {0} 的 tags 含未知硬能力 {1}' -f $id, $tag) } }
        $whenNode = Get-Prop $node 'when'
        $when = [ordered]@{}
        $allowedFlags = @()
        foreach ($accept in $accepts) { $allowedFlags += @($types[$accept].RequiredFlags) }
        if ($null -ne $whenNode) {
            foreach ($property in $whenNode.PSObject.Properties) {
                if ($flags -notcontains $property.Name) { & $fail ('執行者 {0} 的 when 含未知旗標 {1}' -f $id, $property.Name) }
                if ($allowedFlags -notcontains $property.Name) { & $fail ('執行者 {0} 的 when 旗標 {1} 不屬於其受理類型的 requiredFlags' -f $id, $property.Name) }
                if ($property.Value -isnot [bool]) { & $fail ('執行者 {0} 的 when.{1} 必須為布林' -f $id, $property.Name) }
                $when[$property.Name] = $property.Value
            }
        }
        $gated = Get-Prop $node 'gated'
        $escalationOnly = Get-Prop $node 'escalationOnly'
        if ($gated -isnot [bool]) { & $fail ('執行者 {0} 的 gated 必須為布林' -f $id) }
        if ($escalationOnly -isnot [bool]) { & $fail ('執行者 {0} 的 escalationOnly 必須為布林' -f $id) }
        $escalatesTo = Get-Prop $node 'escalatesTo'
        if ($null -ne $escalatesTo -and $escalatesTo -isnot [string]) { & $fail ('執行者 {0} 的 escalatesTo 必須為字串或 null' -f $id) }
        $executors.Add([pscustomobject]@{
                Id             = $id
                Display        = $display
                Platform       = $platform
                Model          = $model
                Profile        = $profile
                Family         = $family
                Accepts        = $accepts
                Tags           = $tags
                When           = $when
                Order          = [long]$order
                Gated          = $gated
                EscalationOnly = $escalationOnly
                EscalatesTo    = $escalatesTo
                OnOfflineNode  = (Get-Prop $node 'onOffline')
                OnOffline      = $null
            })
    }

    $byId = @{}
    foreach ($executor in $executors) { $byId[$executor.Id] = $executor }
    foreach ($executor in $executors) {
        if ($null -ne $executor.EscalatesTo -and -not $byId.ContainsKey($executor.EscalatesTo)) { & $fail ('執行者 {0} 的 escalatesTo 指向不存在的執行者 {1}' -f $executor.Id, $executor.EscalatesTo) }
    }
    foreach ($executor in $executors) {
        $visited = @{ $executor.Id = $true }
        $next = $executor.EscalatesTo
        while ($null -ne $next) {
            if ($visited.ContainsKey($next)) { & $fail ('escalatesTo 成環，涉及執行者 {0}' -f $executor.Id) }
            $visited[$next] = $true
            $next = $byId[$next].EscalatesTo
        }
    }

    foreach ($executor in $executors) {
        if ($executor.Platform -ne 'codex') { continue }
        $node = $executor.OnOfflineNode
        if ($null -eq $node) { & $fail ('Codex 執行者 {0} 缺少 onOffline' -f $executor.Id) }
        $keySet = @($node.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        $acceptSet = @($executor.Accepts | Sort-Object)
        if (($keySet -join '|') -ne ($acceptSet -join '|')) { & $fail ('執行者 {0} 的 onOffline 鍵與 accepts 不相等' -f $executor.Id) }
        $map = [ordered]@{}
        foreach ($property in $node.PSObject.Properties) {
            $action = $property.Value
            if ($script:OfflineActions -cnotcontains $action) { & $fail ('執行者 {0} 的 onOffline.{1} 值無效：{2}' -f $executor.Id, $property.Name, $action) }
            if ($action -eq 'fallback' -or $action -eq 'degrade') {
                $others = @($executors | Where-Object { $_.Id -ne $executor.Id -and -not $_.EscalationOnly -and $_.Accepts -contains $property.Name })
                if ($others.Count -eq 0) { & $fail ('執行者 {0} 的 onOffline.{1} 為 {2}，但同類型沒有其他非僅升級可選的受理者' -f $executor.Id, $property.Name, $action) }
            }
            if ($action -eq 'degrade' -and @($types[$property.Name].Degradable).Count -eq 0) { & $fail ('執行者 {0} 的 onOffline.{1} 為 degrade，但類型沒有 degradable' -f $executor.Id, $property.Name) }
            $map[$property.Name] = $action
        }
        $executor.OnOffline = $map
    }

    return [pscustomobject]@{
        HardTags   = $hard
        Constraint = $constraint
        Flags      = $flags
        Types      = $types
        Executors  = @($executors | Sort-Object -Property Order)
        ById       = $byId
    }
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
        if ($executor.Platform -eq 'claude') { $row['model'] = $executor.Model } else { $row['profile'] = $executor.Profile }
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

    $provided = [ordered]@{ E = $E; T = $T; Deep = $Deep }
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
        if ($selection.Executor.Platform -eq 'claude') { $executorNode['model'] = $selection.Executor.Model } else { $executorNode['profile'] = $selection.Executor.Profile }
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
