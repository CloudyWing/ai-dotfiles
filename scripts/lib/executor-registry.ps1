#Requires -Version 7.0
# 執行者登錄表（scripts\dispatch\executor-registry.json）的讀取與結構驗證。登錄表的結構與值驗證規則只存在本檔。
# 由 Select-DispatchExecutor.ps1 與 codex-run\45-profile-sync.ps1 以 dot-source 載入，兩者取得同一份已驗證的物件。
# 本檔只定義函式，載入時不設定任何變數，函式不依賴呼叫端的變數，也不 dot-source 其他檔案。
# 與選派入口相同，只讀登錄表，不寫檔、不呼叫網路、不讀取環境變數（Test-SelectDispatchExecutor.ps1 的 S03 同時掃描本檔）。

function New-ExecutorRegistryError {
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [int]$ExitCode = 3
    )

    # Data 的 Code 與 ExitCode 是選派入口 stderr 首段與結束碼的來源。
    $exception = New-Object -TypeName System.Exception -ArgumentList ('{0}：{1}' -f $Code, $Message)
    $exception.Data['Code'] = $Code
    $exception.Data['ExitCode'] = $ExitCode
    return $exception
}

function Get-ExecutorRegistryProperty {
    param($Object, [string]$Name)

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-ExecutorRegistryList {
    param($Object, [string]$Name)

    $value = Get-ExecutorRegistryProperty -Object $Object -Name $Name
    if ($null -eq $value) { return , @() }
    return , @($value)
}

function Test-ExecutorRegistryStringArray {
    param($Value)

    foreach ($item in @($Value)) {
        if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item)) { return $false }
    }
    return $true
}

function Test-ExecutorRegistryArrayProperty {
    param($Object, [string]$Name)

    # 欄位不存在，或原始 JSON 值為陣列時回傳 $true。單一字串等純量回傳 $false。
    # 須在 Get-ExecutorRegistryList 之前檢查，後者會把純量包成單元素陣列。
    if ($null -eq $Object) { return $true }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $true }
    return ($property.Value -is [array])
}

function Get-ExecutorRegistryIncompleteLimit {
    # 未完成次數的可表示上限。登錄表 maxIncomplete 與選派入口 -Incomplete 的次數共用這個上限，兩者都以 Int32 保存。
    return 999
}

function Read-ExecutorRegistry {
    param([Parameter(Mandatory)][string]$Path)

    # 讀取並驗證登錄表，回傳已驗證的物件（見 ConvertTo-ExecutorRegistry）。
    # 檔案不存在以 SelectorRegistryNotFound、內容為空或不是 JSON 或結構不合法以 SelectorRegistryInvalid 失敗，兩者 ExitCode 皆為 3。
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-ExecutorRegistryError -Code 'SelectorRegistryNotFound' -Message ('登錄表不存在：{0}' -f $Path))
    }
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false)))
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw (New-ExecutorRegistryError -Code 'SelectorRegistryInvalid' -Message ('登錄表為空：{0}' -f $Path))
    }
    try {
        $raw = $text | ConvertFrom-Json
    }
    catch {
        throw (New-ExecutorRegistryError -Code 'SelectorRegistryInvalid' -Message ('登錄表不是有效的 JSON：{0}' -f $_.Exception.Message))
    }
    return (ConvertTo-ExecutorRegistry -Raw $raw)
}

function ConvertTo-ExecutorRegistry {
    param($Raw)

    # 回傳物件：HardTags、Constraint、Flags、CodexEfforts、RetiredProfiles、MaxIncomplete、IncompleteLimit、Types（依登錄表順序的 ordered 字典）、
    # Executors（依 order 排序）、ById。Codex 執行者的 ProfileSettings 是含 model、effort、subagentModel、subagentEffort（字串）
    # 與 fallbackModels（字串陣列，可為空）的 ordered 字典。
    $registrySchema = 'ai-agents.executor-registry.v1'
    $profileSettingKeys = @('model', 'effort', 'subagentModel', 'subagentEffort')
    $profileSettingOptionalKeys = @('fallbackModels')
    $modelPattern = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
    # 已移除的欄位。出現時登錄表無效，避免舊設定被靜默忽略。
    $removedTypeKeys = @('crossFamily', 'degradable')
    $removedExecutorKeys = @('escalationOnly', 'escalatesTo', 'onOffline')
    # 類型的優先條件可用的約束名稱：執行者家族不等於實作者家族。
    $preferenceConstraints = @('family')
    $maxTagVocabulary = 8

    $fail = {
        param([string]$Message)
        throw (New-ExecutorRegistryError -Code 'SelectorRegistryInvalid' -Message $Message)
    }

    if ((Get-ExecutorRegistryProperty $Raw 'schema') -ne $registrySchema) { & $fail ('schema 必須為 {0}' -f $registrySchema) }

    $tagsNode = Get-ExecutorRegistryProperty $Raw 'tags'
    $hard = Get-ExecutorRegistryList $tagsNode 'hard'
    $constraint = Get-ExecutorRegistryList $tagsNode 'constraint'
    if ($hard.Count -eq 0 -or -not (Test-ExecutorRegistryStringArray $hard)) { & $fail 'tags.hard 必須為非空字串陣列' }
    if ($constraint.Count -eq 0 -or -not (Test-ExecutorRegistryStringArray $constraint)) { & $fail 'tags.constraint 必須為非空字串陣列' }
    $allTags = @($hard) + @($constraint)
    if ($allTags.Count -gt $maxTagVocabulary) { & $fail ('標籤詞彙合計 {0} 個，超過上限 {1}' -f $allTags.Count, $maxTagVocabulary) }
    if (@($allTags | Select-Object -Unique).Count -ne $allTags.Count) { & $fail '標籤詞彙有重複' }

    # codexEfforts 是 Codex 檔位 effort 的允許清單（含 max，需 Codex 0.147 以上，見 README §8），retiredProfiles 是已退役的檔位名稱。兩者只放在登錄表。
    $codexEfforts = Get-ExecutorRegistryList $Raw 'codexEfforts'
    if (-not (Test-ExecutorRegistryStringArray $codexEfforts) -or @($codexEfforts | Where-Object { $_ -cnotmatch '^[a-z]+$' }).Count -gt 0) { & $fail 'codexEfforts 必須為小寫英文字串陣列' }
    $retiredProfiles = Get-ExecutorRegistryList $Raw 'retiredProfiles'
    if (-not (Test-ExecutorRegistryStringArray $retiredProfiles) -or @($retiredProfiles | Where-Object { $_ -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' }).Count -gt 0) { & $fail 'retiredProfiles 必須為檔位名稱字串陣列' }

    # maxIncomplete：同一任務內某執行者的未完成次數達到此值即不再選派給它。
    $maxIncomplete = Get-ExecutorRegistryProperty $Raw 'maxIncomplete'
    $incompleteLimit = Get-ExecutorRegistryIncompleteLimit
    if (($maxIncomplete -isnot [int] -and $maxIncomplete -isnot [long]) -or [long]$maxIncomplete -lt 1 -or [long]$maxIncomplete -gt $incompleteLimit) { & $fail ('maxIncomplete 必須為 1 至 {0} 的整數' -f $incompleteLimit) }

    $flags = Get-ExecutorRegistryList $Raw 'flags'
    if ($flags.Count -eq 0 -or -not (Test-ExecutorRegistryStringArray $flags) -or @($flags | Select-Object -Unique).Count -ne $flags.Count) { & $fail 'flags 必須為非空且不重複的字串陣列' }

    $typesNode = Get-ExecutorRegistryProperty $Raw 'types'
    if ($null -eq $typesNode -or @($typesNode.PSObject.Properties).Count -eq 0) { & $fail 'types 不得為空' }
    $types = [ordered]@{}
    foreach ($property in $typesNode.PSObject.Properties) {
        $name = $property.Name
        $node = $property.Value
        $required = Get-ExecutorRegistryList $node 'requiredFlags'
        $implied = Get-ExecutorRegistryList $node 'impliedTags'
        $forbidden = Get-ExecutorRegistryList $node 'forbiddenTags'
        if (-not (Test-ExecutorRegistryArrayProperty $node 'preferred')) { & $fail ('types.{0}.preferred 必須為陣列' -f $name) }
        $preferred = Get-ExecutorRegistryList $node 'preferred'
        foreach ($removedKey in $removedTypeKeys) { if ($null -ne $node.PSObject.Properties[$removedKey]) { & $fail ('types.{0}.{1} 已移除，優先條件請改用 preferred' -f $name, $removedKey) } }
        foreach ($flag in $required) { if ($flags -notcontains $flag) { & $fail ('types.{0}.requiredFlags 含未知旗標 {1}' -f $name, $flag) } }
        foreach ($tag in $implied) { if ($hard -notcontains $tag) { & $fail ('types.{0}.impliedTags 含未知硬能力 {1}' -f $name, $tag) } }
        foreach ($tag in $forbidden) { if ($hard -notcontains $tag) { & $fail ('types.{0}.forbiddenTags 含未知硬能力 {1}' -f $name, $tag) } }
        if (-not (Test-ExecutorRegistryStringArray $preferred)) { & $fail ('types.{0}.preferred 必須為字串陣列' -f $name) }
        foreach ($tag in $preferred) {
            if ($hard -cnotcontains $tag -and -not ($preferenceConstraints -ccontains $tag -and $constraint -ccontains $tag)) { & $fail ('types.{0}.preferred 含未知的優先條件 {1}' -f $name, $tag) }
        }
        if (@($preferred | Select-Object -Unique).Count -ne $preferred.Count) { & $fail ('types.{0}.preferred 有重複' -f $name) }
        $types[$name] = [pscustomobject]@{
            Name          = $name
            RequiredFlags = $required
            ImpliedTags   = $implied
            ForbiddenTags = $forbidden
            Preferred     = $preferred
        }
    }

    $executorNodes = Get-ExecutorRegistryList $Raw 'executors'
    if ($executorNodes.Count -eq 0) { & $fail 'executors 不得為空' }
    $executors = New-Object 'System.Collections.Generic.List[object]'
    $ids = @{}
    $orders = @{}
    $profiles = @{}
    foreach ($node in $executorNodes) {
        $id = Get-ExecutorRegistryProperty $node 'id'
        if ($id -isnot [string] -or $id -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { & $fail 'executors[].id 必須為符合 ^[a-z0-9]+(?:-[a-z0-9]+)*$ 的字串' }
        if ($ids.ContainsKey($id)) { & $fail ('執行者 id 重複：{0}' -f $id) }
        foreach ($removedKey in $removedExecutorKeys) { if ($null -ne $node.PSObject.Properties[$removedKey]) { & $fail ('執行者 {0} 的 {1} 已移除；下一位執行者由候選排序決定' -f $id, $removedKey) } }
        $ids[$id] = $true
        $order = Get-ExecutorRegistryProperty $node 'order'
        if ($order -isnot [int] -and $order -isnot [long]) { & $fail ('執行者 {0} 的 order 必須為整數' -f $id) }
        if ($orders.ContainsKey([long]$order)) { & $fail ('排序值重複：{0}' -f $order) }
        $orders[[long]$order] = $true
        $platform = Get-ExecutorRegistryProperty $node 'platform'
        if ($platform -cne 'claude' -and $platform -cne 'codex') { & $fail ('執行者 {0} 的 platform 必須為 claude 或 codex' -f $id) }
        $model = Get-ExecutorRegistryProperty $node 'model'
        $profile = Get-ExecutorRegistryProperty $node 'profile'
        $entry = Get-ExecutorRegistryProperty $node 'entry'
        $profileSettings = $null
        if ($platform -ceq 'claude' -and ($model -isnot [string] -or [string]::IsNullOrWhiteSpace($model))) { & $fail ('執行者 {0} 缺少 model' -f $id) }
        if ($platform -ceq 'codex') {
            if ($profile -isnot [string] -or [string]::IsNullOrWhiteSpace($profile)) { & $fail ('執行者 {0} 缺少 profile' -f $id) }
            if ($profile -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { & $fail ('執行者 {0} 的 profile {1} 必須符合 ^[a-z0-9]+(?:-[a-z0-9]+)*$' -f $id, $profile) }
            if ($retiredProfiles -ccontains $profile) { & $fail ('執行者 {0} 的 profile {1} 是已退役的檔位名稱' -f $id, $profile) }
            if ($profiles.ContainsKey($profile)) { & $fail ('檔位 {0} 被多個執行者使用（{1}、{2}）' -f $profile, $profiles[$profile], $id) }
            $profiles[$profile] = $id
            $settingsNode = Get-ExecutorRegistryProperty $node 'profileSettings'
            if ($settingsNode -isnot [pscustomobject]) { & $fail ('執行者 {0} 缺少 profileSettings 物件' -f $id) }
            foreach ($property in $settingsNode.PSObject.Properties) {
                if ($profileSettingKeys -cnotcontains $property.Name -and $profileSettingOptionalKeys -cnotcontains $property.Name) { & $fail ('執行者 {0} 的 profileSettings 含未知欄位 {1}' -f $id, $property.Name) }
            }
            $profileSettings = [ordered]@{}
            foreach ($key in $profileSettingKeys) {
                $settingValue = Get-ExecutorRegistryProperty $settingsNode $key
                if ($settingValue -isnot [string] -or $settingValue -cnotmatch $modelPattern) { & $fail ('執行者 {0} 的 profileSettings.{1} 缺少或不是 {2} 的字串' -f $id, $key, $modelPattern) }
                if (($key -ceq 'effort' -or $key -ceq 'subagentEffort') -and $codexEfforts -cnotcontains $settingValue) { & $fail ('執行者 {0} 的 profileSettings.{1} 的值 {2} 不在 codexEfforts（{3}）內' -f $id, $key, $settingValue, ($codexEfforts -join ', ')) }
                $profileSettings[$key] = $settingValue
            }
            # fallbackModels：主要 model 在某帳號不被支援時依序改用的 model。選填，不得重複，不得含主要 model。
            if (-not (Test-ExecutorRegistryArrayProperty $settingsNode 'fallbackModels')) { & $fail ('執行者 {0} 的 profileSettings.fallbackModels 必須為陣列' -f $id) }
            $fallbackModels = Get-ExecutorRegistryList $settingsNode 'fallbackModels'
            foreach ($fallbackModel in $fallbackModels) {
                if ($fallbackModel -isnot [string] -or $fallbackModel -cnotmatch $modelPattern) { & $fail ('執行者 {0} 的 profileSettings.fallbackModels 必須為符合 {1} 的字串陣列' -f $id, $modelPattern) }
                if ($fallbackModel -ceq $profileSettings['model']) { & $fail ('執行者 {0} 的 profileSettings.fallbackModels 不得含主要 model {1}' -f $id, $fallbackModel) }
            }
            if (@($fallbackModels | Select-Object -Unique).Count -ne $fallbackModels.Count) { & $fail ('執行者 {0} 的 profileSettings.fallbackModels 有重複' -f $id) }
            $profileSettings['fallbackModels'] = [string[]]@($fallbackModels)
            if ($entry -isnot [string] -or $entry -cnotmatch '^scripts/[A-Za-z0-9._-]+\.ps1$') { & $fail ('執行者 {0} 缺少 entry，或 entry 不符合 ^scripts/[A-Za-z0-9._-]+\.ps1$' -f $id) }
        }
        elseif ($null -ne $node.PSObject.Properties['entry']) {
            & $fail ('Claude 執行者 {0} 不得有 entry 欄位' -f $id)
        }
        elseif ($null -ne $node.PSObject.Properties['profileSettings']) {
            & $fail ('Claude 執行者 {0} 不得有 profileSettings 欄位' -f $id)
        }
        $display = Get-ExecutorRegistryProperty $node 'display'
        $family = Get-ExecutorRegistryProperty $node 'family'
        if ($display -isnot [string] -or [string]::IsNullOrWhiteSpace($display)) { & $fail ('執行者 {0} 缺少 display' -f $id) }
        if ($family -isnot [string] -or [string]::IsNullOrWhiteSpace($family)) { & $fail ('執行者 {0} 缺少 family' -f $id) }
        $accepts = Get-ExecutorRegistryList $node 'accepts'
        if ($accepts.Count -eq 0 -or -not (Test-ExecutorRegistryStringArray $accepts)) { & $fail ('執行者 {0} 的 accepts 必須為非空字串陣列' -f $id) }
        foreach ($accept in $accepts) { if (-not $types.Contains($accept)) { & $fail ('執行者 {0} 受理未知類型 {1}' -f $id, $accept) } }
        $tags = Get-ExecutorRegistryList $node 'tags'
        if (-not (Test-ExecutorRegistryStringArray $tags)) { & $fail ('執行者 {0} 的 tags 必須為字串陣列' -f $id) }
        foreach ($tag in $tags) { if ($hard -notcontains $tag) { & $fail ('執行者 {0} 的 tags 含未知硬能力 {1}' -f $id, $tag) } }
        $whenNode = Get-ExecutorRegistryProperty $node 'when'
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
        $gated = Get-ExecutorRegistryProperty $node 'gated'
        if ($gated -isnot [bool]) { & $fail ('執行者 {0} 的 gated 必須為布林' -f $id) }
        $executors.Add([pscustomobject]@{
                Id              = $id
                Display         = $display
                Platform        = $platform
                Model           = $model
                Profile         = $profile
                ProfileSettings = $profileSettings
                Entry           = $entry
                Family          = $family
                Accepts         = $accepts
                Tags            = $tags
                When            = $when
                Order           = [long]$order
                Gated           = $gated
            })
    }

    $byId = @{}
    foreach ($executor in $executors) { $byId[$executor.Id] = $executor }
    foreach ($typeName in $types.Keys) {
        if (@($executors | Where-Object { $_.Accepts -contains $typeName }).Count -eq 0) { & $fail ('類型 {0} 沒有任何執行者受理' -f $typeName) }
    }

    return [pscustomobject]@{
        HardTags        = $hard
        Constraint      = $constraint
        Flags           = $flags
        CodexEfforts    = $codexEfforts
        RetiredProfiles = $retiredProfiles
        MaxIncomplete   = [int]$maxIncomplete
        IncompleteLimit = [int]$incompleteLimit
        Types           = $types
        Executors       = @($executors | Sort-Object -Property Order)
        ById            = $byId
    }
}
