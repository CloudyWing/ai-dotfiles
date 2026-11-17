#Requires -Version 7.0

<#
.SYNOPSIS
依執行者登錄表為任務選出派工執行者，唯讀輸出單一 JSON 物件。

.DESCRIPTION
驗證任務標註（類型、旗標、標籤、優先條件、實作者家族、離線清單、未完成次數），讀取
scripts\dispatch\executor-registry.json，依固定演算法選出執行者並產生 [派工] 行。

演算法：受理該類型、硬能力涵蓋有效標籤且條件全部符合的執行者為候選（必要條件）；
候選依優先條件逐項比較，滿足者在前，第一項相同再比下一項，全部相同時排序值小者在前；
依序略過 -Offline 列出者與未完成次數達登錄表 maxIncomplete 者，第一位未被略過者為選中者。

登錄表的讀取與結構驗證載入同目錄 lib\executor-registry.ps1（產生器、Setup、帳號建立與派工前比對共用同一份）。
腳本與該檔都不寫檔、不呼叫網路、不讀取環境變數，同輸入與同登錄表的輸出完全相同。

結束碼：0 為 selected；10 為 needs-user-decision；20 為 needs-authorization；22 為 stopped；
2 為標註無效；3 為登錄表不存在或無效；
1 為內部錯誤，或 lib\executor-registry.ps1 不存在或無法載入（SelectorRegistryLibraryUnavailable）。
標註無效與登錄表無效時，stderr 首段格式為「Code：訊息」。
結束碼 2 的錯誤碼含 SelectorParameterBinding：多值參數以空白分隔時，多餘的值會成為位置參數，
腳本以此錯誤碼回報；-Tags、-Prefer、-Offline 與 -Incomplete 的多個值請以逗號連接且不含空白。

.PARAMETER Type
任務類型，值域由登錄表 types 決定。

.PARAMETER E
旗標 E（範圍已列舉），值為 true 或 false，僅該類型要求時提供。

.PARAMETER T
旗標 T（需要測試循環），值為 true 或 false，僅該類型要求時提供。

.PARAMETER Deep
已移除的旗標。傳入此參數（任何值、任何類型）時以 SelectorFlagRemoved 結束碼 2 拒絕。

.PARAMETER Tags
任務的必要條件：所需的硬能力標籤，可用逗號分隔多個。

.PARAMETER Prefer
任務的優先條件，依重要性由高到低，可用逗號分隔多個。值為硬能力標籤或 family。
接在該類型登錄表 preferred 之後，已出現者不重複。

.PARAMETER ImplementerFamily
實作者家族，claude 或 codex。有效優先條件含 family 時必填。

.PARAMETER Authorized
使用者已授權 gated 執行者。

.PARAMETER Offline
經服務端拒絕且確認不可用的執行者 id，可用逗號分隔多個。

.PARAMETER Incomplete
同一任務內各執行者已累計的未完成次數，格式為 id:次數，可用逗號分隔多個，同一 id 只能出現一次。
次數為 0 至 999 的整數（與登錄表 maxIncomplete 的上限相同），達登錄表 maxIncomplete 的執行者不再被選中。

.PARAMETER EscalateFrom
已移除的參數。傳入時以 SelectorFlagRemoved 結束碼 2 拒絕，改用 -Incomplete。

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
    [string[]]$Prefer,
    [string]$ImplementerFamily,
    [switch]$Authorized,
    [string[]]$Offline,
    [string[]]$Incomplete,
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
$script:EscalateFromProvided = $PSBoundParameters.ContainsKey('EscalateFrom')
# 優先條件 family：執行者家族不等於實作者家族。判定行以白話說明。
$script:FamilyPreference = 'family'
$script:PreferenceCaptions = @{ family = '找不到不同模型家族的執行者，改由同家族審查' }
# 判定行的白話對照（與 executor-selection skill「判定行的白話對照」一致）。登錄表未列的類型與旗標以原名顯示。
$script:TypeVerbs = @{ edit = '改檔'; survey = '盤點取證'; test = '測試取證'; generate = '產生影像'; factcheck = '事實查核'; review = '審查'; advise = '提供顧問意見' }
$script:FlagPhrases = @{ 'E=True' = '範圍已列明'; 'E=False' = '範圍需自行探索'; 'T=True' = '需要建置測試'; 'T=False' = '不需建置測試' }
$script:SkipReasonPhrases = @{ offline = '離線'; 'incomplete-limit' = '未完成次數已達上限' }

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
    param($Executor, [string]$TypeName, $Flags, [string[]]$EffectiveTags)

    # 必要條件：受理類型、硬能力涵蓋有效標籤、when 全部符合。回傳 $null 表示是候選。
    if ($Executor.Accepts -notcontains $TypeName) { return 'type-not-accepted' }
    $missing = @($EffectiveTags | Where-Object { $Executor.Tags -notcontains $_ })
    if ($missing.Count -gt 0) { return ('tag-missing:{0}' -f ($missing -join ',')) }
    foreach ($key in $Executor.When.Keys) {
        if (-not $Flags.ContainsKey($key) -or $Flags[$key] -ne $Executor.When[$key]) { return ('when-mismatch:{0}' -f $key) }
    }
    return $null
}

function Test-PreferenceMet {
    param($Executor, [string]$Preference, [string]$ImplementerFamily)

    if ($Preference -ceq $script:FamilyPreference) { return ($Executor.Family -ne $ImplementerFamily) }
    return ($Executor.Tags -contains $Preference)
}

function Get-ExecutorSelection {
    param($Registry, [string]$TypeName, $Flags, [string[]]$EffectiveTags, [string[]]$Preferences, [string]$ImplementerFamily, [bool]$IsAuthorized, [string[]]$OfflineIds, $IncompleteCounts)

    $reasons = @{}
    $ranked = New-Object 'System.Collections.Generic.List[object]'
    foreach ($executor in @($Registry.Executors)) {
        $excluded = Get-ExclusionReason -Executor $executor -TypeName $TypeName -Flags $Flags -EffectiveTags $EffectiveTags
        if ($null -ne $excluded) { $reasons[$executor.Id] = $excluded; continue }
        # 排序鍵：每個優先條件一位，滿足為 0、未滿足為 1，依重要性由高到低；字串比較即逐項比較。
        $unmet = @($Preferences | Where-Object { -not (Test-PreferenceMet -Executor $executor -Preference $_ -ImplementerFamily $ImplementerFamily) })
        $key = (@($Preferences | ForEach-Object { if ($unmet -ccontains $_) { '1' } else { '0' } }) -join '')
        $ranked.Add([pscustomobject]@{ Executor = $executor; Unmet = $unmet; Key = $key })
    }
    # Registry.Executors 已依 order 排序，Sort-Object -Stable 保留同鍵者的 order 順序。
    $candidates = @($ranked.ToArray() | Sort-Object -Property Key -Stable)

    $chosen = $null
    $skipped = @()
    $hitIncompleteLimit = $false
    foreach ($candidate in $candidates) {
        $id = $candidate.Executor.Id
        if ($null -ne $chosen) { $reasons[$id] = 'eligible-lower-priority'; continue }
        if ($OfflineIds -contains $id) {
            $reasons[$id] = 'offline'
            $skipped += , ([ordered]@{ id = $id; reason = 'offline' })
            continue
        }
        if ($IncompleteCounts.ContainsKey($id) -and $IncompleteCounts[$id] -ge $Registry.MaxIncomplete) {
            $reasons[$id] = 'incomplete-limit'
            $skipped += , ([ordered]@{ id = $id; reason = 'incomplete-limit' })
            $hitIncompleteLimit = $true
            continue
        }
        $chosen = $candidate
        $reasons[$id] = 'selected'
    }

    if ($null -ne $chosen) {
        if ($chosen.Executor.Gated -and -not $IsAuthorized) { $status = 'needs-authorization'; $reason = 'authorization-required' }
        else { $status = 'selected'; $reason = 'best-match' }
    }
    elseif ($candidates.Count -eq 0) { $status = 'stopped'; $reason = 'no-eligible-executor' }
    elseif ($hitIncompleteLimit) { $status = 'needs-user-decision'; $reason = 'all-candidates-exhausted' }
    else { $status = 'stopped'; $reason = 'offline' }

    $considered = @()
    foreach ($executor in @($Registry.Executors)) {
        $considered += , ([ordered]@{ id = $executor.Id; reason = $reasons[$executor.Id] })
    }
    return [pscustomobject]@{
        Status           = $status
        Executor         = $(if ($null -ne $chosen) { $chosen.Executor } else { $null })
        UnmetPreferences = $(if ($null -ne $chosen) { @($chosen.Unmet) } else { @() })
        Candidates       = @($candidates | ForEach-Object { $_.Executor.Id })
        Skipped          = $skipped
        Reason           = $reason
        Considered       = $considered
    }
}

function Format-YesNo {
    param([bool]$Value)

    if ($Value) { return '是' }
    return '否'
}

function Get-DispatchLine {
    param($Selection, [string]$TypeName, $TypeDef, $Flags, [string]$LabelText)

    $verb = $TypeName
    if ($script:TypeVerbs.ContainsKey($TypeName)) { $verb = $script:TypeVerbs[$TypeName] }
    $detail = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($LabelText)) { $detail.Add($LabelText.Trim()) }
    $detail.Add($verb)
    $phrases = New-Object 'System.Collections.Generic.List[string]'
    foreach ($flag in @($TypeDef.RequiredFlags)) {
        $key = '{0}={1}' -f $flag, $Flags[$flag]
        if ($script:FlagPhrases.ContainsKey($key)) { $phrases.Add($script:FlagPhrases[$key]) }
        else { $phrases.Add(('{0}={1}' -f $flag, (Format-YesNo $Flags[$flag]))) }
    }
    if ($phrases.Count -gt 0) { $detail.Add($phrases -join '、') }
    $text = $detail -join '，'

    $name = '無'
    if ($null -ne $Selection.Executor) { $name = $Selection.Executor.Display }
    $head = switch ($Selection.Status) {
        'selected' { '交給 {0}' -f $name }
        'needs-authorization' { '等你授權後交給 {0}' -f $name }
        'needs-user-decision' { '需你決定，目前沒有可交付的執行者' }
        'stopped' { '停止，沒有可用的執行者' }
    }
    $line = '[派工] {0}：{1}' -f $head, $text
    if (@($Selection.UnmetPreferences).Count -gt 0) {
        $names = @($Selection.UnmetPreferences | ForEach-Object {
                if ($script:PreferenceCaptions.ContainsKey($_)) { $script:PreferenceCaptions[$_] } else { '未滿足優先條件 {0}' -f $_ }
            })
        $line += '；' + ($names -join '、')
    }
    if (@($Selection.Skipped).Count -gt 0) {
        $items = @($Selection.Skipped | ForEach-Object {
                $reason = $_.reason
                if ($script:SkipReasonPhrases.ContainsKey($reason)) { $reason = $script:SkipReasonPhrases[$reason] }
                '{0}（{1}）' -f $_.id, $reason
            })
        $line += '；已略過 ' + ($items -join '、')
    }
    return $line
}

function Get-StatusExitCode {
    param([string]$Status)

    switch ($Status) {
        'selected' { return 0 }
        'needs-user-decision' { return 10 }
        'needs-authorization' { return 20 }
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
                preferred     = @($type.Preferred)
            })
    }
    $executorRows = @()
    foreach ($executor in $Registry.Executors) {
        $row = [ordered]@{
            id       = $executor.Id
            display  = $executor.Display
            platform = $executor.Platform
            family   = $executor.Family
            accepts  = @($executor.Accepts)
            tags     = @($executor.Tags)
            when     = $executor.When
            order    = $executor.Order
            gated    = $executor.Gated
        }
        if ($executor.Platform -eq 'claude') { $row['model'] = $executor.Model } else { $row['profile'] = $executor.Profile; $row['entry'] = $executor.Entry; $row['profileSettings'] = $executor.ProfileSettings }
        $executorRows += , $row
    }
    return [ordered]@{
        schema        = $script:DescribeSchema
        tags          = [ordered]@{ hard = @($Registry.HardTags); constraint = @($Registry.Constraint) }
        flags         = @($Registry.Flags)
        maxIncomplete = $Registry.MaxIncomplete
        types         = $typeRows
        executors     = $executorRows
    }
}

function Invoke-Selector {
    if ($script:DeepFlagProvided) {
        throw (New-SelectorError -Code 'SelectorFlagRemoved' -Message '旗標 Deep 已移除，type=review 不再依旗標選擇檔位，請移除 -Deep。' -ExitCode 2)
    }
    if ($script:EscalateFromProvided) {
        throw (New-SelectorError -Code 'SelectorFlagRemoved' -Message '參數 EscalateFrom 已移除，請改以 -Incomplete <執行者 id>:<未完成次數> 傳入，由候選排序決定下一位。' -ExitCode 2)
    }
    if ($null -ne $RemainingArgument -and @($RemainingArgument).Count -gt 0) {
        throw (New-SelectorError -Code 'SelectorParameterBinding' -Message ('偵測到多餘的位置參數：{0}。-Tags、-Prefer、-Offline 與 -Incomplete 的多個值請以逗號連接且不含空白，例如 -Offline codex-scan,codex-review' -f (@($RemainingArgument) -join ' ')) -ExitCode 2)
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

    # 有效優先條件：類型的 preferred 在前，任務以 -Prefer 追加者在後。
    $preferences = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in @($typeDef.Preferred)) { $preferences.Add($item) }
    foreach ($item in (Split-ListArgument -Value $Prefer)) {
        if (@($registry.HardTags) -cnotcontains $item -and -not ($item -ceq $script:FamilyPreference -and @($registry.Constraint) -ccontains $item)) {
            throw (New-SelectorError -Code 'SelectorPreferInvalid' -Message ('未知的優先條件：{0}。可用值：{1}' -f $item, ((@($registry.HardTags) + @($script:FamilyPreference)) -join ', ')) -ExitCode 2)
        }
        if (-not $preferences.Contains($item)) { $preferences.Add($item) }
    }
    $needsFamily = $preferences.Contains($script:FamilyPreference)

    if ($needsFamily -and ($ImplementerFamily -cne 'claude' -and $ImplementerFamily -cne 'codex')) {
        throw (New-SelectorError -Code 'SelectorFamilyRequired' -Message ('類型 {0} 的優先條件含 family，必須提供 -ImplementerFamily（claude 或 codex）' -f $Type) -ExitCode 2)
    }

    $offlineIds = Split-ListArgument -Value $Offline
    foreach ($id in $offlineIds) {
        if (-not $registry.ById.ContainsKey($id)) {
            throw (New-SelectorError -Code 'SelectorExecutorUnknown' -Message ('-Offline 含未知的執行者 id：{0}' -f $id) -ExitCode 2)
        }
    }

    # 不經 Split-ListArgument：它會先去掉完全相同的項目，同一 id 重複時就看不出來。
    $incompleteEntries = @(@($Incomplete) | Where-Object { $null -ne $_ } | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $incompleteCounts = [ordered]@{}
    foreach ($entry in $incompleteEntries) {
        $match = [regex]::Match($entry, '^(?<id>[^:]+):(?<count>[0-9]+)$')
        # 次數上限與登錄表 maxIncomplete 的上限相同；位數先擋下，避免超大數字轉型失敗。
        if (-not $match.Success -or $match.Groups['count'].Value.Length -gt 9 -or [long]$match.Groups['count'].Value -gt $registry.IncompleteLimit) {
            throw (New-SelectorError -Code 'SelectorIncompleteInvalid' -Message ('-Incomplete 的格式必須為 <執行者 id>:<0 至 {0} 的整數>：{1}' -f $registry.IncompleteLimit, $entry) -ExitCode 2)
        }
        $id = $match.Groups['id'].Value
        if (-not $registry.ById.ContainsKey($id)) {
            throw (New-SelectorError -Code 'SelectorExecutorUnknown' -Message ('-Incomplete 含未知的執行者 id：{0}' -f $id) -ExitCode 2)
        }
        if ($incompleteCounts.Contains($id)) {
            throw (New-SelectorError -Code 'SelectorIncompleteInvalid' -Message ('-Incomplete 的執行者 id 重複：{0}' -f $id) -ExitCode 2)
        }
        $incompleteCounts[$id] = [int]$match.Groups['count'].Value
    }
    $incompleteLookup = @{}
    foreach ($id in $incompleteCounts.Keys) { $incompleteLookup[$id] = $incompleteCounts[$id] }

    $selection = Get-ExecutorSelection -Registry $registry -TypeName $Type -Flags $flags -EffectiveTags $effectiveTags -Preferences $preferences.ToArray() -ImplementerFamily $ImplementerFamily -IsAuthorized ([bool]$Authorized) -OfflineIds $offlineIds -IncompleteCounts $incompleteLookup

    $labels = [ordered]@{}
    foreach ($flag in @($registry.Flags)) { if ($flags.ContainsKey($flag)) { $labels[$flag] = $flags[$flag] } }
    $labels['tags'] = @($effectiveTags)
    $labels['prefer'] = @($preferences.ToArray())
    if ($needsFamily) { $labels['implementerFamily'] = $ImplementerFamily } else { $labels['implementerFamily'] = $null }
    $labels['authorized'] = [bool]$Authorized
    $labels['offline'] = @($offlineIds)
    $labels['incomplete'] = $incompleteCounts

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
        unmetPreferences     = @($selection.UnmetPreferences)
        candidates           = @($selection.Candidates)
        skipped              = @($selection.Skipped)
        requiresUserDecision = ($selection.Status -eq 'needs-user-decision')
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
