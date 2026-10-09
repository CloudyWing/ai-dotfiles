function New-ParentOptionsModel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [Parameter(Mandatory)]
        [string]$Sandbox,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [AllowEmptyCollection()]
        [string[]]$AddDirectory,

        [bool]$Search,

        [AllowEmptyCollection()]
        [string[]]$CodexParentOption
    )

    $normalizedDirectories = New-Object 'System.Collections.Generic.List[string]'
    $directoryValues = if ($null -eq $AddDirectory) { @() } else { @($AddDirectory) }
    foreach ($directory in $directoryValues) {
        if ([string]::IsNullOrWhiteSpace($directory)) {
            throw 'parent_options.add_directory 不可包含空白項目。'
        }
        $normalizedDirectories.Add((Resolve-AbsolutePath -Path $directory))
    }

    $parentOptions = New-Object 'System.Collections.Generic.List[string]'
    $optionValues = if ($null -eq $CodexParentOption) { @() } else { @($CodexParentOption) }
    foreach ($option in $optionValues) {
        if ([string]::IsNullOrWhiteSpace($option)) {
            throw 'parent_options.codex_parent_option 不可包含空白項目。'
        }
        $parentOptions.Add([string]$option)
    }

    $model = [ordered]@{
        profile              = $Profile
        sandbox              = $Sandbox
        add_directory        = @($normalizedDirectories.ToArray())
        search               = [bool]$Search
        codex_parent_option  = @($parentOptions.ToArray())
        working_directory    = Resolve-AbsolutePath -Path $WorkingDirectory
    }
    $model.fingerprint = Get-JsonSha256 -Value $model
    return $model
}

function Compare-ParentOptions {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Current,

        [AllowNull()]
        [object]$Anchor
    )

    if ($null -eq $Anchor) {
        return [ordered]@{
            matches     = $false
            code        = 'ParentOptionsUnknown'
            differences = @('anchor.parent_options')
        }
    }
    if ($null -eq $Current) {
        return [ordered]@{
            matches     = $false
            code        = 'ParentOptionsUnknown'
            differences = @('current.parent_options')
        }
    }

    $differences = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @('profile', 'sandbox', 'search', 'working_directory')) {
        $currentValue = Get-DispatchJsonProperty -Object $Current -Name $name
        $anchorValue = Get-DispatchJsonProperty -Object $Anchor -Name $name
        $equal = if ($name -eq 'working_directory') {
            [string]::Equals([string]$currentValue, [string]$anchorValue, [System.StringComparison]::OrdinalIgnoreCase)
        }
        else {
            [string]::Equals([string]$currentValue, [string]$anchorValue, [System.StringComparison]::Ordinal)
        }
        if (-not $equal) {
            $differences.Add($name)
        }
    }
    $currentDirectories = @((Get-DispatchJsonProperty -Object $Current -Name 'add_directory'))
    $anchorDirectories = @((Get-DispatchJsonProperty -Object $Anchor -Name 'add_directory'))
    if (-not (Compare-DispatchStringArrays -Left $currentDirectories -Right $anchorDirectories -OrdinalIgnoreCase)) {
        $differences.Add('add_directory')
    }
    $currentOptions = @((Get-DispatchJsonProperty -Object $Current -Name 'codex_parent_option'))
    $anchorOptions = @((Get-DispatchJsonProperty -Object $Anchor -Name 'codex_parent_option'))
    if (-not (Compare-DispatchStringArrays -Left $currentOptions -Right $anchorOptions)) {
        $differences.Add('codex_parent_option')
    }
    $anchorFingerprint = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'fingerprint')
    if ([string]::IsNullOrWhiteSpace($anchorFingerprint)) {
        $differences.Add('fingerprint')
    }
    return [ordered]@{
        matches     = $differences.Count -eq 0
        code        = if ($differences.Count -eq 0) { $null } else { 'ParentOptionsMismatch' }
        differences = @($differences.ToArray())
    }
}

function Resolve-ParentOptionsForStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [bool]$ProfileProvided,

        [Parameter(Mandatory)]
        [string]$Sandbox,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [AllowEmptyCollection()]
        [string[]]$AddDirectory,

        [bool]$Search,

        [bool]$AddDirectoryProvided,

        [bool]$SearchProvided,

        [AllowEmptyCollection()]
        [string[]]$CodexParentOption,

        [bool]$CodexParentOptionProvided,

        [AllowNull()]
        [object]$Anchor
    )

    if ($null -eq $Anchor) {
        $model = New-ParentOptionsModel -Profile $Profile -Sandbox $Sandbox -WorkingDirectory $WorkingDirectory -AddDirectory $AddDirectory -Search $Search -CodexParentOption $CodexParentOption
        return [ordered]@{
            model = $model
            differences = @()
            code = $null
            restored = $false
        }
    }

    $anchorProfile = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'profile')
    $anchorSandbox = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'sandbox')
    $anchorWorkingDirectory = [string](Get-DispatchJsonProperty -Object $Anchor -Name 'working_directory')
    $anchorDirectories = @((Get-DispatchJsonProperty -Object $Anchor -Name 'add_directory'))
    $anchorSearch = [bool](Get-DispatchJsonProperty -Object $Anchor -Name 'search')
    $anchorOptions = @((Get-DispatchJsonProperty -Object $Anchor -Name 'codex_parent_option'))
    $differences = New-Object 'System.Collections.Generic.List[string]'

    $effectiveProfile = $anchorProfile
    if ($ProfileProvided) {
        if ($Profile -ne $anchorProfile) {
            $differences.Add('profile')
        }
        $effectiveProfile = $Profile
    }
    if ($Sandbox -ne $anchorSandbox) {
        $differences.Add('sandbox')
    }
    $resolvedWorkingDirectory = Resolve-AbsolutePath -Path $WorkingDirectory
    if (-not [string]::Equals($resolvedWorkingDirectory, $anchorWorkingDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        $differences.Add('working_directory')
    }

    $effectiveDirectories = $anchorDirectories
    if ($AddDirectoryProvided) {
        $currentDirectoriesModel = New-ParentOptionsModel -Profile $effectiveProfile -Sandbox $Sandbox -WorkingDirectory $WorkingDirectory -AddDirectory $AddDirectory -Search $Search -CodexParentOption @()
        $currentDirectories = @((Get-DispatchJsonProperty -Object $currentDirectoriesModel -Name 'add_directory'))
        if (-not (Compare-DispatchStringArrays -Left $currentDirectories -Right $anchorDirectories -OrdinalIgnoreCase)) {
            $differences.Add('add_directory')
        }
        $effectiveDirectories = $currentDirectories
    }

    $effectiveSearch = $anchorSearch
    if ($SearchProvided) {
        if ($Search -ne $anchorSearch) {
            $differences.Add('search')
        }
        $effectiveSearch = $Search
    }

    $effectiveParentOptions = $anchorOptions
    if ($CodexParentOptionProvided) {
        if (-not (Compare-DispatchStringArrays -Left $CodexParentOption -Right $anchorOptions)) {
            $differences.Add('codex_parent_option')
        }
        $effectiveParentOptions = @($CodexParentOption)
    }

    $model = New-ParentOptionsModel -Profile $effectiveProfile -Sandbox $Sandbox -WorkingDirectory $WorkingDirectory -AddDirectory $effectiveDirectories -Search $effectiveSearch -CodexParentOption $effectiveParentOptions
    return [ordered]@{
        model = $model
        differences = @($differences.ToArray())
        code = if ($differences.Count -eq 0) { $null } else { 'ParentOptionsMismatch' }
        restored = $true
    }
}

function New-UnknownDispatchEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string]$Reason,

        [string]$Source = 'unknown',

        [string]$Path,

        [Nullable[int]]$Line,

        [string]$Sha256
    )

    return [ordered]@{
        value = $null
        status = 'unknown'
        source = if ([string]::IsNullOrWhiteSpace($Source)) { 'unknown' } else { $Source }
        field = $Field
        path = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
        line = $Line
        reason = $Reason
        captured_at_utc = [datetime]::UtcNow.ToString('o')
        sha256 = if ([string]::IsNullOrWhiteSpace($Sha256)) { $null } else { $Sha256 }
    }
}

function New-ConfirmedDispatchEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Field,

        [string]$Path,

        [Nullable[int]]$Line,

        [string]$Sha256
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return New-UnknownDispatchEvidence -Field $Field -Reason '證據值為空。' -Source 'unknown' -Path $Path -Line $Line -Sha256 $Sha256
    }
    return [ordered]@{
        value = $Value
        status = 'confirmed'
        source = $Source
        field = $Field
        path = if ([string]::IsNullOrWhiteSpace($Path)) { $null } else { $Path }
        line = $Line
        reason = $null
        captured_at_utc = [datetime]::UtcNow.ToString('o')
        sha256 = if ([string]::IsNullOrWhiteSpace($Sha256)) { $null } else { $Sha256 }
    }
}

function ConvertTo-DispatchEvidence {
    param(
        [AllowNull()]
        [object]$Evidence,

        [Parameter(Mandatory)]
        [string]$Field,

        [string]$UnknownReason = '缺少證據。'
    )

    if ($null -eq $Evidence) {
        return New-UnknownDispatchEvidence -Field $Field -Reason $UnknownReason
    }
    $value = Get-DispatchJsonProperty -Object $Evidence -Name 'value'
    $status = Get-DispatchJsonProperty -Object $Evidence -Name 'status'
    if ($null -eq $value -or $null -eq $status) {
        return New-UnknownDispatchEvidence -Field $Field -Reason $UnknownReason
    }
    $value = [string]$value
    $status = [string]$status
    if ($status -ne 'confirmed' -or [string]::IsNullOrWhiteSpace($value)) {
        $reasonValue = Get-DispatchJsonProperty -Object $Evidence -Name 'reason'
        $reason = if ($null -ne $reasonValue -and -not [string]::IsNullOrWhiteSpace([string]$reasonValue)) { [string]$reasonValue } else { $UnknownReason }
        $sourceValue = Get-DispatchJsonProperty -Object $Evidence -Name 'source'
        $source = if ($null -ne $sourceValue) { [string]$sourceValue } else { 'unknown' }
        $pathValue = Get-DispatchJsonProperty -Object $Evidence -Name 'path'
        $path = if ($null -ne $pathValue) { [string]$pathValue } else { $null }
        $lineValue = Get-DispatchJsonProperty -Object $Evidence -Name 'line'
        $line = if ($null -ne $lineValue) { [int]$lineValue } else { $null }
        $shaValue = Get-DispatchJsonProperty -Object $Evidence -Name 'sha256'
        $sha = if ($null -ne $shaValue) { [string]$shaValue } else { $null }
        return New-UnknownDispatchEvidence -Field $Field -Reason $reason -Source $source -Path $path -Line $line -Sha256 $sha
    }
    $sourceValue = Get-DispatchJsonProperty -Object $Evidence -Name 'source'
    $source = if ($null -ne $sourceValue) { [string]$sourceValue } else { 'unknown' }
    $pathValue = Get-DispatchJsonProperty -Object $Evidence -Name 'path'
    $path = if ($null -ne $pathValue) { [string]$pathValue } else { $null }
    $lineValue = Get-DispatchJsonProperty -Object $Evidence -Name 'line'
    $line = if ($null -ne $lineValue) { [int]$lineValue } else { $null }
    $shaValue = Get-DispatchJsonProperty -Object $Evidence -Name 'sha256'
    $sha = if ($null -ne $shaValue) { [string]$shaValue } else { $null }
    return New-ConfirmedDispatchEvidence -Value $value -Source $source -Field $Field -Path $path -Line $line -Sha256 $sha
}

function New-ModelEvidence {
    param(
        [AllowNull()]
        [object]$RequestedModel,

        [AllowNull()]
        [object]$ResolvedModel,

        [AllowNull()]
        [object]$RuntimeModel,

        [AllowNull()]
        [object]$RequestedReasoningEffort,

        [AllowNull()]
        [object]$ResolvedReasoningEffort,

        [AllowNull()]
        [object]$RuntimeReasoningEffort
    )

    return [ordered]@{
        evidence_contract = 'codex-dispatch.model-evidence.v1'
        model = [ordered]@{
            requested = ConvertTo-DispatchEvidence -Evidence $RequestedModel -Field 'Model'
            resolved = ConvertTo-DispatchEvidence -Evidence $ResolvedModel -Field 'model'
            runtime_verifiable = if ($null -eq $RuntimeModel) { New-UnknownDispatchEvidence -Field 'payload.model' -Reason '沒有公開可驗證的實際 model 證據。' -Source 'public-actual-unavailable' } else { ConvertTo-DispatchEvidence -Evidence $RuntimeModel -Field 'payload.model' }
        }
        reasoning_effort = [ordered]@{
            requested = ConvertTo-DispatchEvidence -Evidence $RequestedReasoningEffort -Field 'ReasoningEffort'
            resolved = ConvertTo-DispatchEvidence -Evidence $ResolvedReasoningEffort -Field 'model_reasoning_effort'
            runtime_verifiable = if ($null -eq $RuntimeReasoningEffort) { New-UnknownDispatchEvidence -Field 'payload.effort' -Reason '沒有公開可驗證的實際 reasoning effort 證據。' -Source 'public-actual-unavailable' } else { ConvertTo-DispatchEvidence -Evidence $RuntimeReasoningEffort -Field 'payload.effort' }
        }
    }
}

function ConvertTo-DispatchEvidenceGroup {
    param(
        [AllowNull()]
        [object]$Evidence,

        [Parameter(Mandatory)]
        [string]$Field,

        [string]$CompatibilityValue
    )

    $requested = $null
    $resolved = $null
    $runtime = $null
    if ($null -ne $Evidence) {
        $requested = Get-DispatchJsonProperty -Object $Evidence -Name 'requested'
        $resolved = Get-DispatchJsonProperty -Object $Evidence -Name 'resolved'
        $runtime = Get-DispatchJsonProperty -Object $Evidence -Name 'runtime_verifiable'
    }
    if ($null -eq $requested -and $null -eq $resolved -and $null -eq $runtime) {
        if ([string]::IsNullOrWhiteSpace($CompatibilityValue)) {
            $single = ConvertTo-DispatchEvidence -Evidence $Evidence -Field $Field
            $requested = New-UnknownDispatchEvidence -Field $Field -Reason '校準缺少 requested evidence。' -Source 'evidence-missing'
            $resolved = $single
            $runtime = New-UnknownDispatchEvidence -Field $Field -Reason '校準缺少 runtime_verifiable evidence。' -Source 'evidence-missing'
        }
        else {
            $requested = New-ConfirmedDispatchEvidence -Value $CompatibilityValue -Source 'compatibility-parameter' -Field $Field
            $resolved = New-ConfirmedDispatchEvidence -Value $CompatibilityValue -Source 'compatibility-parameter' -Field $Field
            $runtime = New-ConfirmedDispatchEvidence -Value $CompatibilityValue -Source 'compatibility-parameter' -Field $Field
        }
    }
    return [ordered]@{
        requested = ConvertTo-DispatchEvidence -Evidence $requested -Field $Field -UnknownReason 'requested evidence 無法正規化。'
        resolved = ConvertTo-DispatchEvidence -Evidence $resolved -Field $Field -UnknownReason 'resolved evidence 無法正規化。'
        runtime_verifiable = ConvertTo-DispatchEvidence -Evidence $runtime -Field $Field -UnknownReason 'runtime_verifiable evidence 無法正規化。'
    }
}

function Test-DispatchEvidencePair {
    param(
        [Parameter(Mandatory)]
        [psobject]$EvidenceGroup
    )

    $resolvedEvidence = Get-DispatchJsonProperty -Object $EvidenceGroup -Name 'resolved'
    $runtimeEvidence = Get-DispatchJsonProperty -Object $EvidenceGroup -Name 'runtime_verifiable'
    $resolved = Get-DispatchEvidenceValue -Evidence $resolvedEvidence
    $runtime = Get-DispatchEvidenceValue -Evidence $runtimeEvidence
    $matches = $null -ne $resolved -and $null -ne $runtime -and [string]::Equals($resolved, $runtime, [StringComparison]::Ordinal)
    return [ordered]@{
        eligible = $matches
        resolved = $resolved
        runtime = $runtime
        reason = if ($matches) { $null } elseif ($null -eq $resolved -or $null -eq $runtime) { 'resolved 或 runtime_verifiable evidence unknown。' } else { 'resolved 與 runtime_verifiable evidence 不一致。' }
    }
}

function Get-DispatchEvidenceValue {
    param(
        [AllowNull()]
        [object]$Evidence
    )

    if ($null -eq $Evidence) {
        return $null
    }
    $status = Get-DispatchJsonProperty -Object $Evidence -Name 'status'
    $value = Get-DispatchJsonProperty -Object $Evidence -Name 'value'
    if ($null -eq $status -or $null -eq $value -or [string]$status -ne 'confirmed') {
        return $null
    }
    return [string]$value
}

function New-RequestedDispatchEvidence {
    param(
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Field
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return New-UnknownDispatchEvidence -Field $Field -Reason '呼叫端沒有明確提供參數。' -Source 'parameter-omitted'
    }
    return New-ConfirmedDispatchEvidence -Value $Value -Source 'parameter' -Field $Field
}

function Resolve-CodexHomeForEvidence {
    param(
        [string]$CodexHomePath
    )

    $configured = $CodexHomePath
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $configured = $env:CODEX_HOME
    }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
            $configured = Join-Path -Path $userProfile -ChildPath '.codex'
        }
    }
    if ([string]::IsNullOrWhiteSpace($configured)) {
        return $null
    }
    return Resolve-AbsolutePath -Path $configured
}

function Resolve-ProfileConfigPath {
    param(
        [string]$CodexHome,

        [string]$Profile
    )

    if ([string]::IsNullOrWhiteSpace($CodexHome) -or $Profile -notin @('default', 'advisor')) {
        return $null
    }
    $homePath = Resolve-AbsolutePath -Path $CodexHome
    $fileName = if ($Profile -eq 'advisor') { 'advisor.config.toml' } else { 'default.config.toml' }
    $configPath = Join-Path -Path $homePath -ChildPath $fileName
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        return $null
    }
    return Resolve-AbsolutePath -Path $configPath
}

function Read-ProfileModelEvidence {
    param(
        [string]$ConfigPath,

        [string]$Profile
    )

    $modelField = 'model'
    $effortField = 'model_reasoning_effort'
    $unknownPath = if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $null } else { Resolve-AbsolutePath -Path $ConfigPath }
    if ([string]::IsNullOrWhiteSpace($unknownPath) -or -not (Test-Path -LiteralPath $unknownPath -PathType Leaf)) {
        return [ordered]@{
            config_path = $unknownPath
            config_sha256 = $null
            model = New-UnknownDispatchEvidence -Field $modelField -Reason 'Profile 設定檔不存在。' -Source 'profile-config-missing' -Path $unknownPath
            reasoning_effort = New-UnknownDispatchEvidence -Field $effortField -Reason 'Profile 設定檔不存在。' -Source 'profile-config-missing' -Path $unknownPath
        }
    }

    $hash = $null
    $content = $null
    try {
        $hash = Get-FileSha256 -Path $unknownPath
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $content = $utf8.GetString([IO.File]::ReadAllBytes($unknownPath))
    }
    catch {
        $reason = 'Profile 設定檔讀取失敗：' + $_.Exception.Message
        return [ordered]@{
            config_path = $unknownPath
            config_sha256 = $hash
            model = New-UnknownDispatchEvidence -Field $modelField -Reason $reason -Source 'profile-config-read-failed' -Path $unknownPath -Sha256 $hash
            reasoning_effort = New-UnknownDispatchEvidence -Field $effortField -Reason $reason -Source 'profile-config-read-failed' -Path $unknownPath -Sha256 $hash
        }
    }

    $assignments = @{
        model = New-Object System.Collections.Generic.List[object]
        model_reasoning_effort = New-Object System.Collections.Generic.List[object]
    }
    $invalidFields = @{}
    $lines = [regex]::Split($content, '\r?\n')
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = [string]$lines[$index]
        if ($index -eq 0 -and $line.Length -gt 0 -and $line[0] -eq [char]0xFEFF) {
            $line = $line.Substring(1)
        }
        if ($line -match '^\s*\[\[?') {
            break
        }
        if ($line -match '^\s*(?<field>model|model_reasoning_effort)\s*=\s*(?<value>.*?)(?:\s+#.*)?$') {
            $field = $Matches['field']
            $rawValue = $Matches['value'].Trim()
            $value = $null
            if ($rawValue -match '^"(?<quoted>(?:[^"\\]|\\.)*)"$') {
                $value = $Matches['quoted']
                $value = $value.Replace('\\"', '"').Replace('\\\\', '\\')
            }
            elseif ($rawValue -match "^'(?<quoted>[^']*)'$") {
                $value = $Matches['quoted']
            }
            else {
                $invalidFields[$field] = '格式不是字串 assignment'
            }
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $assignments[$field].Add([pscustomobject]@{ Value = $value; Line = $index + 1 })
            }
            elseif (-not $invalidFields.ContainsKey($field)) {
                $invalidFields[$field] = '值為空'
            }
        }
    }

    $buildEvidence = {
        param($Field, $Items, $InvalidFields)
        if ($InvalidFields.ContainsKey($Field)) {
            return New-UnknownDispatchEvidence -Field $Field -Reason ('Profile top-level assignment 無法解析：' + $InvalidFields[$Field]) -Source 'profile-config-invalid' -Path $unknownPath -Sha256 $hash
        }
        if ($Items.Count -eq 0) {
            return New-UnknownDispatchEvidence -Field $Field -Reason 'Profile 設定檔缺少 top-level assignment。' -Source 'profile-config-missing-field' -Path $unknownPath -Sha256 $hash
        }
        $first = $Items[0]
        foreach ($item in $Items) {
            if ($item.Value -cne $first.Value) {
                return New-UnknownDispatchEvidence -Field $Field -Reason 'Profile top-level assignment 重複且值衝突。' -Source 'profile-config-conflict' -Path $unknownPath -Line $first.Line -Sha256 $hash
            }
        }
        return New-ConfirmedDispatchEvidence -Value $first.Value -Source 'profile-config' -Field $Field -Path $unknownPath -Line ([int]$first.Line) -Sha256 $hash
    }
    $modelEvidence = & $buildEvidence 'model' $assignments.model $invalidFields
    $effortEvidence = & $buildEvidence 'model_reasoning_effort' $assignments.model_reasoning_effort $invalidFields
    return [ordered]@{
        config_path = $unknownPath
        config_sha256 = $hash
        model = $modelEvidence
        reasoning_effort = $effortEvidence
    }
}

function Get-ModelRolloutDiagnosticFiles {
    param(
        [Parameter(Mandatory)]
        [string]$CodexHomePath
    )

    if ([string]::IsNullOrWhiteSpace($CodexHomePath)) {
        throw '模型診斷缺少 CodexHome。'
    }

    $sessionsPath = Join-Path -Path $CodexHomePath -ChildPath 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsPath -PathType Container)) {
        return @()
    }

    return @(
        Get-ChildItem -LiteralPath $sessionsPath -Recurse -File -Filter 'rollout-*.jsonl' |
            ForEach-Object {
                [pscustomobject]@{
                    Path             = $_.FullName
                    Length           = [int64]$_.Length
                    LastWriteTimeUtc = $_.LastWriteTimeUtc
                }
            }
    )
}

function Get-ModelRolloutDiagnosticEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$CodexHomePath,

        [Parameter(Mandatory)]
        [string]$ThreadId,

        [AllowEmptyString()]
        [string]$StartedAtUtc
    )

    $modelUnknown = New-UnknownDispatchEvidence -Field 'payload.model' -Reason '尚未找到與此 thread 對應的 rollout turn_context。' -Source 'rollout-not-observed'
    $effortUnknown = New-UnknownDispatchEvidence -Field 'payload.effort' -Reason '尚未找到與此 thread 對應的 rollout turn_context。' -Source 'rollout-not-observed'
    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        return [ordered]@{ model = $modelUnknown; reasoning_effort = $effortUnknown; rollout_paths = @() }
    }
    $started = ConvertTo-DispatchTimestamp -Value $StartedAtUtc
    if ($null -eq $started) {
        $reason = 'started_at_utc 缺失或無法解析，無法判定 turn_context 時間範圍。'
        return [ordered]@{
            model = New-UnknownDispatchEvidence -Field 'payload.model' -Reason $reason -Source 'rollout-time-unknown'
            reasoning_effort = New-UnknownDispatchEvidence -Field 'payload.effort' -Reason $reason -Source 'rollout-time-unknown'
            rollout_paths = @()
        }
    }

    $matchedFiles = New-Object System.Collections.Generic.List[object]
    $modelValues = New-Object System.Collections.Generic.List[object]
    $effortValues = New-Object System.Collections.Generic.List[object]
    $modelMissing = $false
    $effortMissing = $false
    $turnContextFound = $false
    $timeUnknown = $false
    try {
        $rolloutFiles = @(Get-ModelRolloutDiagnosticFiles -CodexHomePath (Resolve-AbsolutePath -Path $CodexHomePath))
    }
    catch {
        $reason = 'rollout 掃描失敗：' + $_.Exception.Message
        return [ordered]@{
            model = New-UnknownDispatchEvidence -Field 'payload.model' -Reason $reason -Source 'rollout-scan-failed'
            reasoning_effort = New-UnknownDispatchEvidence -Field 'payload.effort' -Reason $reason -Source 'rollout-scan-failed'
            rollout_paths = @()
        }
    }

    foreach ($file in $rolloutFiles) {
        $sessionMatched = $false
        $fileEvents = New-Object System.Collections.Generic.List[object]
        $lineNumber = 0
        try {
            foreach ($rawLine in Get-Content -LiteralPath $file.Path -Encoding UTF8 -ErrorAction Stop) {
                $lineNumber++
                if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
                try { $event = ConvertFrom-DispatchJson -Content $rawLine } catch { continue }
                $fileEvents.Add([pscustomobject]@{ Event = $event; Line = $lineNumber })
                $type = [string](Get-DispatchJsonProperty -Object $event -Name 'type')
                if ($type -eq 'session_meta') {
                    $payload = Get-DispatchJsonProperty -Object $event -Name 'payload'
                    $sessionId = [string](Get-DispatchJsonProperty -Object $payload -Name 'session_id')
                    if ([string]::IsNullOrWhiteSpace($sessionId)) {
                        $sessionId = [string](Get-DispatchJsonProperty -Object $payload -Name 'id')
                    }
                    if ($sessionId -ceq $ThreadId) { $sessionMatched = $true }
                }
            }
        }
        catch {
            continue
        }
        if (-not $sessionMatched) { continue }
        $matchedFiles.Add($file)
        foreach ($entry in $fileEvents) {
            $type = [string](Get-DispatchJsonProperty -Object $entry.Event -Name 'type')
            if ($type -ne 'turn_context') { continue }
            $timestampValue = Get-DispatchJsonProperty -Object $entry.Event -Name 'timestamp'
            if ($null -eq $timestampValue) { $timestampValue = Get-DispatchJsonProperty -Object $entry.Event -Name 'created_at_utc' }
            if ($null -eq $timestampValue) { $timestampValue = Get-DispatchJsonProperty -Object $entry.Event -Name 'created_at' }
            $turnTime = ConvertTo-DispatchTimestamp -Value $timestampValue
            if ($null -eq $turnTime) { $timeUnknown = $true; continue }
            if ($turnTime -le $started) { continue }
            $turnContextFound = $true
            $payload = Get-DispatchJsonProperty -Object $entry.Event -Name 'payload'
            $modelValue = [string](Get-DispatchJsonProperty -Object $payload -Name 'model')
            $effortValue = [string](Get-DispatchJsonProperty -Object $payload -Name 'effort')
            if ([string]::IsNullOrWhiteSpace($modelValue)) { $modelMissing = $true } else { $modelValues.Add([pscustomobject]@{ Value = $modelValue; File = $file.Path; Line = $entry.Line }) }
            if ([string]::IsNullOrWhiteSpace($effortValue)) { $effortMissing = $true } else { $effortValues.Add([pscustomobject]@{ Value = $effortValue; File = $file.Path; Line = $entry.Line }) }
        }
    }

    $rolloutPaths = @($matchedFiles | ForEach-Object { $_.Path } | Sort-Object -Unique)
    $firstFile = if ($matchedFiles.Count -gt 0) { $matchedFiles[0] } else { $null }
    $firstHash = if ($null -ne $firstFile) { Get-FileSha256 -Path $firstFile.Path } else { $null }
    $createValueEvidence = {
        param($Values, $Missing, $PayloadField)
        if ($matchedFiles.Count -eq 0) {
            return New-UnknownDispatchEvidence -Field $PayloadField -Reason '沒有 rollout 的 exact session ID。' -Source 'rollout-session-not-found'
        }
        if (-not $turnContextFound -or $timeUnknown) {
            return New-UnknownDispatchEvidence -Field $PayloadField -Reason 'rollout 缺少可判定時間範圍的 turn_context。' -Source 'rollout-time-unknown' -Path (if ($null -eq $firstFile) { $null } else { $firstFile.Path }) -Sha256 $firstHash
        }
        if ($Missing -or $Values.Count -eq 0) {
            return New-UnknownDispatchEvidence -Field $PayloadField -Reason 'turn_context 欄位缺失。' -Source 'rollout-field-missing' -Path (if ($null -eq $firstFile) { $null } else { $firstFile.Path }) -Sha256 $firstHash
        }
        $first = $Values[0]
        foreach ($valueEntry in $Values) {
            if ($valueEntry.Value -cne $first.Value) {
                return New-UnknownDispatchEvidence -Field $PayloadField -Reason '多筆 turn_context 值衝突。' -Source 'rollout-values-conflict' -Path $first.File -Line ([int]$first.Line) -Sha256 (Get-FileSha256 -Path $first.File)
            }
        }
        $evidence = New-ConfirmedDispatchEvidence -Value $first.Value -Source 'rollout' -Field $PayloadField -Path $first.File -Line ([int]$first.Line) -Sha256 (Get-FileSha256 -Path $first.File)
        $evidence.source_paths = @($rolloutPaths)
        return $evidence
    }
    return [ordered]@{
        model = & $createValueEvidence $modelValues $modelMissing 'payload.model'
        reasoning_effort = & $createValueEvidence $effortValues $effortMissing 'payload.effort'
        rollout_paths = $rolloutPaths
    }
}

function Invoke-ModelEnvironmentDiagnostic {
    if ([string]::IsNullOrWhiteSpace($ThreadId)) {
        throw 'DiagnoseModelEnvironment 必須提供 ThreadId。'
    }
    if ([string]::IsNullOrWhiteSpace($StartedAtUtc)) {
        throw 'DiagnoseModelEnvironment 必須提供 StartedAtUtc。'
    }
    $codexHomePath = Resolve-CodexHomePath -ConfiguredCodexHome $CodexHome
    $profileConfigPath = Resolve-ProfileConfigPath -CodexHome $codexHomePath -Profile $Profile
    $profileEvidence = Read-ProfileModelEvidence -ConfigPath $profileConfigPath -Profile $Profile
    $actualEvidence = Get-ModelRolloutDiagnosticEvidence -CodexHomePath $codexHomePath -ThreadId $ThreadId -StartedAtUtc $StartedAtUtc
    return [ordered]@{
        operation = 'DiagnoseModelEnvironment'
        profile = $Profile
        codex_home_path = $codexHomePath
        profile_config_path = $profileEvidence.config_path
        profile_config_sha256 = $profileEvidence.config_sha256
        profile_model = $profileEvidence.model
        profile_reasoning_effort = $profileEvidence.reasoning_effort
        actual_model = $actualEvidence.model
        actual_reasoning_effort = $actualEvidence.reasoning_effort
        rollout_paths = @($actualEvidence.rollout_paths)
        thread_id = $ThreadId
        started_at_utc = $StartedAtUtc
    }
}

function Get-DispatchJsonProperty {
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
    return
}

function Get-DispatchByteArraySha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Invoke-DispatchRawGitEvidenceCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $gitPath = Get-GitPath
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $gitPath
    $startInfo.WorkingDirectory = $ExecutionRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Add-ProcessArguments -StartInfo $startInfo -Arguments $Arguments
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    if ($null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) {
        $startInfo.StandardInputEncoding = $utf8NoBom
    }
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $stdoutBuffer = New-Object System.IO.MemoryStream
    $startedAt = [DateTimeOffset]::UtcNow
    try {
        if (-not $process.Start()) {
            throw 'Git evidence Process.Start() 回傳 false。'
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($stdoutBuffer)
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $null = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $bytes = $stdoutBuffer.ToArray()
        return [pscustomobject]@{
            command = $gitPath + ' ' + ($Arguments -join ' ')
            exit_code = $process.ExitCode
            stdout_bytes = $bytes
            stdout_text = ([Text.Encoding]::UTF8.GetString($bytes))
            stderr = $stderr
            start_utc = $startedAt.ToString('o')
            finish_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    finally {
        $stdoutBuffer.Dispose()
        $process.Dispose()
    }
}

function New-DispatchEvidenceBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$EvidencePosition
    )

    $binding = [ordered]@{
        schema = 'ai-sessions.dispatch-evidence-binding.v1'
        evidence_kind = 'fixture'
        execution_root = $ExecutionRoot
        head = $null
        tracked_diff_sha256 = $null
        untracked_files = @()
        uncommitted_content_fingerprint = $null
        serialization_version = 'dispatch-content-fingerprint-v1'
        commands = [ordered]@{}
        evidence_position = $EvidencePosition
        captured_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        capture_status = 'not-attempted'
        capture_error = $null
    }
    $capturePath = $ExecutionRoot
    try {
        $headResult = Invoke-DispatchRawGitEvidenceCommand -ExecutionRoot $ExecutionRoot -Arguments @('rev-parse', '--verify', 'HEAD')
        $binding.commands.head = $headResult.command
        $binding.commands.tracked_diff = $null
        $binding.commands.untracked = $null
        if ([int]$headResult.exit_code -ne 0) {
            $binding.capture_status = 'fixture-no-git'
            $binding.capture_error = [string]$headResult.stderr
            return $binding
        }
        $head = ([string]$headResult.stdout_text).Trim()
        if ($head -notmatch '^[0-9a-fA-F]{40}$') {
            throw ('Git HEAD 不是完整 SHA-1：' + $head)
        }
        $diffResult = Invoke-DispatchRawGitEvidenceCommand -ExecutionRoot $ExecutionRoot -Arguments @('diff', '--binary', '--no-ext-diff', 'HEAD', '--')
        $untrackedResult = Invoke-DispatchRawGitEvidenceCommand -ExecutionRoot $ExecutionRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
        $binding.commands.tracked_diff = $diffResult.command
        $binding.commands.untracked = $untrackedResult.command
        if ([int]$diffResult.exit_code -ne 0 -or [int]$untrackedResult.exit_code -ne 0) {
            throw ('Git content evidence 命令失敗：diff=' + [string]$diffResult.stderr + '; untracked=' + [string]$untrackedResult.stderr)
        }
        $untrackedText = [Text.Encoding]::UTF8.GetString([byte[]]$untrackedResult.stdout_bytes)
        $untrackedEntries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($rawPath in @($untrackedText -split [char]0 | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
            $relativePath = ([string]$rawPath).Replace('\', '/')
            if ([IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|/)\.\.(/|$)') {
                throw ('untracked path 不合法：' + $relativePath)
            }
            $candidatePath = Resolve-AbsolutePath -Path (Join-Path $ExecutionRoot ($relativePath.Replace('/', '\')))
            $capturePath = $candidatePath
            if (-not (Test-PathWithinRoot -Path $candidatePath -Root $ExecutionRoot)) {
                throw ('untracked path 超出 execution root：' + $relativePath)
            }
            if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
                throw ('untracked path 不存在：' + $relativePath)
            }
            $bytes = [IO.File]::ReadAllBytes((ConvertTo-FileSystemApiPath -Path $candidatePath))
            $untrackedEntries.Add([ordered]@{
                    path = $relativePath
                    byte_length = $bytes.Length
                    sha256 = Get-DispatchByteArraySha256 -Bytes $bytes
                })
        }
        $sortedEntries = @($untrackedEntries.ToArray() | Sort-Object -Property path)
        $capturePath = $ExecutionRoot
        $trackedDiffSha256 = Get-DispatchByteArraySha256 -Bytes ([byte[]]$diffResult.stdout_bytes)
        $canonical = [ordered]@{
            serialization_version = 'dispatch-content-fingerprint-v1'
            head = $head.ToLowerInvariant()
            tracked_diff_sha256 = $trackedDiffSha256
            untracked_files = $sortedEntries
        }
        $canonicalJson = ConvertTo-Json -InputObject $canonical -Depth 50 -Compress
        $binding.evidence_kind = 'real-dispatch'
        $binding.head = $head.ToLowerInvariant()
        $binding.tracked_diff_sha256 = $trackedDiffSha256
        $binding.untracked_files = $sortedEntries
        $binding.uncommitted_content_fingerprint = Get-DispatchByteArraySha256 -Bytes ([Text.Encoding]::UTF8.GetBytes($canonicalJson))
        $binding.capture_status = 'completed'
        return $binding
    }
    catch {
        $binding.capture_status = 'capture-failed'
        $binding.capture_error = 'Evidence binding 失敗。path=' + $capturePath + '; ' + $_.Exception.Message
        return $binding
    }
}

function Get-DispatchStringArraySha256 {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Values
    )

    $valueList = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in @($Values)) {
        $valueList.Add([string]$value)
    }
    [object]$arrayValue = $valueList.ToArray()
    $json = ConvertTo-Json -InputObject $arrayValue -Depth 10 -Compress
    return Get-DispatchByteArraySha256 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))
}
