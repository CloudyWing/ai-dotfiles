#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Title,

    [Parameter(Mandatory)]
    [string]$Role,

    [AllowNull()]
    [AllowEmptyCollection()]
    [object]$TargetPath,

    [Parameter(Mandatory)]
    [string]$TaskBody,

    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [AllowNull()]
    [string[]]$RequiredRead,

    [Parameter(Mandatory)]
    [hashtable[]]$Acceptance,

    [Parameter(Mandatory)]
    [string]$Boundary,

    [Parameter(Mandatory)]
    [string]$ReportPath,

    [AllowNull()]
    [object]$DispatchSlug,

    [AllowNull()]
    [object]$LineSlug,

    [AllowNull()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'dispatch\dispatch-input-checks.ps1')

function Test-UnsafeSearchLineEndAnchor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CommandText
    )

    $tokens = $null
    $parseErrors = $null
    $scriptAst = [System.Management.Automation.Language.Parser]::ParseInput($CommandText, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        return $false
    }

    $commandAsts = $scriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($commandAst in $commandAsts) {
        $commandName = $commandAst.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) {
            continue
        }
        $commandLeaf = [System.IO.Path]::GetFileNameWithoutExtension($commandName)
        $isRipgrep = [string]::Equals($commandLeaf, 'rg', [System.StringComparison]::OrdinalIgnoreCase)
        $isSelectString = [string]::Equals($commandName, 'Select-String', [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $isRipgrep -and -not $isSelectString) {
            continue
        }

        $elements = @($commandAst.CommandElements)
        $hasSimpleMatch = $false
        $patterns = New-Object 'System.Collections.Generic.List[string]'
        $positionals = New-Object 'System.Collections.Generic.List[string]'
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                $parameterName = [string]$element.ParameterName
                if ($isSelectString -and [string]::Equals($parameterName, 'SimpleMatch', [System.StringComparison]::OrdinalIgnoreCase)) {
                    $hasSimpleMatch = $true
                    continue
                }

                $patternParameterNames = if ($isRipgrep) { @('e', 'regexp') } else { @('Pattern') }
                if ($patternParameterNames -contains $parameterName) {
                    $patternArgument = $null
                    $argumentProperty = $element.PSObject.Properties['Argument']
                    if ($null -ne $argumentProperty -and $null -ne $element.Argument) {
                        $patternArgument = $element.Argument
                    }
                    elseif ($index + 1 -lt $elements.Count) {
                        $index++
                        $patternArgument = $elements[$index]
                    }
                    if ($patternArgument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                        $patterns.Add([string]$patternArgument.Value)
                    }
                    elseif ($patternArgument -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $patternArgument.NestedExpressions.Count -eq 0) {
                        $patterns.Add([string]$patternArgument.Value)
                    }
                    continue
                }

                $valueParameterNames = if ($isRipgrep) {
                    @('g', 'glob', 't', 'type', 'T', 'type-not', 'f', 'file', 'A', 'B', 'C', 'after-context', 'before-context', 'context', 'threads', 'sort', 'sortr', 'max-count', 'encoding', 'engine', 'max-depth', 'max-filesize', 'type-add')
                }
                else {
                    @('Path', 'LiteralPath', 'Encoding', 'Context', 'Culture', 'Include', 'Exclude')
                }
                if ($valueParameterNames -contains $parameterName -and $index + 1 -lt $elements.Count -and $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    $index++
                }
                continue
            }

            if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $positionals.Add([string]$element.Value)
            }
            elseif ($element -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and $element.NestedExpressions.Count -eq 0) {
                $positionals.Add([string]$element.Value)
            }
        }

        if ($hasSimpleMatch) {
            continue
        }
        if ($patterns.Count -eq 0 -and $positionals.Count -gt 0) {
            $patterns.Add([string]$positionals[0])
        }

        foreach ($pattern in $patterns) {
            if ($pattern.Length -eq 0 -or $pattern[$pattern.Length - 1] -ne '$') {
                continue
            }
            $crlfSafeSuffix = [string][char]92 + 'r?$'
            if ($pattern.EndsWith($crlfSafeSuffix, [System.StringComparison]::Ordinal)) {
                continue
            }

            $backslashCount = 0
            for ($patternIndex = $pattern.Length - 2; $patternIndex -ge 0 -and $pattern[$patternIndex] -eq '\'; $patternIndex--) {
                $backslashCount++
            }
            if (($backslashCount % 2) -eq 0) {
                return $true
            }
        }
    }

    return $false
}

function Test-NonBlank {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [string]$Value
    )

    return -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-AbsolutePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    return [System.Text.RegularExpressions.Regex]::IsMatch(
        $Value,
        '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Throw-DispatchOrderValidationFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Classification,

        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string]$Message,

        [AllowNull()]
        [object]$Detail
    )

    $result = [ordered]@{
        operation      = 'NewDispatchOrder'
        schema         = 'ai-sessions.dispatch-order-validation.v1'
        status         = 'failed'
        code           = $Code
        error_code     = $Code
        classification = $Classification
        field          = $Field
        message        = $Message
        detail         = if ($null -eq $Detail) { [ordered]@{} } else { $Detail }
    }
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['operationResult'] = $result
    throw $exception
}

function Get-DefaultDispatchOrderPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReportPath,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $reportPathValue = [System.IO.Path]::GetFullPath($ReportPath)
    $directoryPath = Split-Path -Parent $reportPathValue
    $sourceAiSessionsRoot = $null
    while (-not [string]::IsNullOrWhiteSpace($directoryPath)) {
        $parentPath = Split-Path -Parent $directoryPath
        if ((Split-Path -Leaf $directoryPath) -ieq 'ai-sessions' -and (Split-Path -Leaf $parentPath) -ieq '.local') {
            $sourceAiSessionsRoot = $directoryPath
        }

        if ([string]::Equals($directoryPath, $parentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $directoryPath = $parentPath
    }

    if ([string]::IsNullOrWhiteSpace($sourceAiSessionsRoot)) {
        Throw-DispatchOrderValidationFailure -Code 'DispatchRequestMissingField' -Classification 'MissingField' -Field 'OutputPath' -Message "無法從 ReportPath 找到 .local\ai-sessions 來源根目錄，請明確傳入 OutputPath。" -Detail ([ordered]@{ report_path = $ReportPath })
    }

    $handoffRoot = Join-Path -Path $sourceAiSessionsRoot -ChildPath 'handoff'
    return Join-Path -Path (Join-Path -Path $handoffRoot -ChildPath $LineSlug) -ChildPath ("dispatch-order-{0}.md" -f $DispatchSlug)
}

function ConvertTo-CrLf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $normalizedText = $Text -replace "`r`n", "`n"
    $normalizedText = $normalizedText -replace "`r", "`n"
    return $normalizedText -replace "`n", "`r`n"
}

function ConvertTo-MarkdownCell {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $cellValue = $Value -replace "`r`n", '<br>'
    $cellValue = $cellValue -replace "`r|`n", '<br>'
    return $cellValue.Replace('|', '\|')
}

function New-DispatchOrderContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Role,

        [Parameter(Mandatory)]
        [string[]]$TargetPath,

        [Parameter(Mandatory)]
        [string]$TaskBody,

        [Parameter(Mandatory)]
        [hashtable[]]$Acceptance,

        [Parameter(Mandatory)]
        [string]$Boundary,

        [Parameter(Mandatory)]
        [string]$ReportPath,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $acceptanceRows = for ($index = 0; $index -lt $Acceptance.Count; $index++) {
        $item = $Acceptance[$index]
        $rowNumber = $index + 1
        $capabilities = @()
        if ($item.ContainsKey('Capability') -and $null -ne $item['Capability']) {
            $capabilities = @([string[]]$item['Capability'])
        }

        $category = ConvertTo-MarkdownCell -Value ([string]$item['Category'])
        $conditionValue = [string]$item['Condition']
        if ($capabilities.Count -gt 0) {
            $conditionValue = "[需要:{0}] {1}" -f ($capabilities -join ','), $conditionValue
        }

        $condition = ConvertTo-MarkdownCell -Value $conditionValue
        $commandReference = "見命令 $rowNumber"
        "| $rowNumber | $category | $condition | $commandReference |"
    }

    $commandBlocks = for ($index = 0; $index -lt $Acceptance.Count; $index++) {
        $item = $Acceptance[$index]
        $rowNumber = $index + 1
        $command = [string]$item['Command']
        @(
            "$rowNumber."
            '```powershell'
            $command
            '```'
        ) -join "`r`n"
    }

    $reportDirectory = Split-Path -Parent $ReportPath
    $lineReportRoot = $reportDirectory
    if ((Split-Path -Leaf $reportDirectory) -ne $LineSlug) {
        $lineReportRoot = Join-Path -Path $reportDirectory -ChildPath $LineSlug
    }

    $fixedReportName = switch ($Role.Trim()) {
        'Support Engineer' { 'support-engineer-report.md' }
        '支援工程師' { 'support-engineer-report.md' }
        'Reviewer' { 'review-report.md' }
        'review' { 'review-report.md' }
        '審查' { 'review-report.md' }
        'Frontend Reviewer' { 'frontend-reviewer-report.md' }
        'Contract Auditor' { 'contract-auditor-report.md' }
        default { $null }
    }

    $fixedReportDescription = '執行角色規則檔指定的同線固定報告（位於 ' + $lineReportRoot + '）'
    if ($null -ne $fixedReportName) {
        $fixedReportPath = Join-Path -Path $lineReportRoot -ChildPath $fixedReportName
        $fixedReportDescription = '執行角色規則檔指定的同線固定報告 `' + $fixedReportPath + '`'
    }
    $exceptionsPath = Join-Path -Path $lineReportRoot -ChildPath 'exceptions.md'
    $targetBlock = $TargetPath -join "`n"
    $acceptanceTable = $acceptanceRows -join "`n"
    $commandSource = $commandBlocks -join "`r`n`r`n"

    $content = @"
# 派遣單：$DispatchSlug

## 1. 任務標題

$Title

## 2. 執行角色

ROLE_VALUE

## 3. 目標物件

CODE_FENCEtext
$targetBlock
CODE_FENCE

## 4. 任務內容

$TaskBody

## 5. 驗收條件與 Codex 命令

| # | 類別 | 驗收條件 | Codex 命令 |
| --- | --- | --- | --- |
$acceptanceTable

### 命令原文

$commandSource

## 6. 執行邊界

$Boundary

- 明文寫入例外：第 7 欄報告檔 REPORT_PATH_VALUE。
- 明文寫入例外：FIXED_REPORT_DESCRIPTION_VALUE。
- 明文寫入例外：同線 EXCEPTIONS_LABEL 的絕對路徑 EXCEPTIONS_PATH_VALUE。

## 7. 產出落點

CODE_FENCEtext
$ReportPath
CODE_FENCE

## 8. 回報必備欄位

逐條列出第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間、執行狀態與判定結果，另附每條類別與未修改狀態輸出。執行狀態為已執行、受阻、未執行或已補驗四選一，執行端只可使用前三者；受阻須說明缺少的環境能力與原始錯誤。已補驗只由主 Agent 於回收補驗後填寫。

### Runtime Request 欄位對照

| 派遣單生成輸入 | Request 欄位 | 關係 |
| --- | --- | --- |
| ``LineSlug`` | ``line_slug`` | 同一條需求線識別值。 |
| ``DispatchSlug`` | ``dispatch_slug`` | 同一次派遣識別值。 |
| ``TargetPath`` | ``target_path`` | 同一組絕對目標路徑。 |
| ``Title``、``Role``、``TaskBody``、``Acceptance``、``Boundary`` | 無直接欄位 | 由 Prepare 路徑轉成 Prompt 與執行限制；不得推定為同名或近似名稱的 Request 欄位。 |
| ``ReportPath`` | 無直接對應；``report_path`` 僅供 Cleanup Request 使用 | 派遣單的結案報告落點與 Cleanup 的報告清單用途不同。 |
| ``OutputPath`` | 無對應欄位 | 只指定本工具寫入派遣單檔案的位置。 |
| 無 | ``operation``、``source_root``、``dispatch_root``、``write_mode``、``dispatch_kind``、``prompt_path``、``task_type``、``session_mode``、``unit_kind``、``requested_unit``、``evidence_pack_path``、``advisor_consult_report_path``、``failure_receipt_path``、``result_path`` 等 | 依 runtime operation 與派遣流程提供，不由派遣單生成參數直接設定。 |

結案訊息須含派遣單絕對路徑、DISPATCH_SLUG_VALUE 與 LINE_SLUG_VALUE。

CODE_FENCEtext
OutputPath: $OutputPath
DispatchSlug: $DispatchSlug
LineSlug: $LineSlug
CODE_FENCE
"@

    $content = $content -replace '^[\r\n]+', ''
    $content = $content.Replace('CODE_FENCE', '```')
    $content = $content.Replace('ROLE_VALUE', ('`' + $Role + '`'))
    $content = $content.Replace('EXCEPTIONS_LABEL', '`exceptions.md`')
    $content = $content.Replace('FIXED_REPORT_DESCRIPTION_VALUE', $fixedReportDescription)
    $content = $content.Replace('REPORT_PATH_VALUE', ('`' + $ReportPath + '`'))
    $content = $content.Replace('EXCEPTIONS_PATH_VALUE', ('`' + $exceptionsPath + '`'))
    $content = $content.Replace('DISPATCH_SLUG_VALUE', ('`' + $DispatchSlug + '`'))
    $content = $content.Replace('LINE_SLUG_VALUE', ('`' + $LineSlug + '`'))
    return ConvertTo-CrLf -Text $content
}

try {
    $requiredValues = @{
        Title = $Title
        Role = $Role
        TaskBody = $TaskBody
        Boundary = $Boundary
        ReportPath = $ReportPath
    }

    foreach ($entry in $requiredValues.GetEnumerator()) {
        if (-not (Test-NonBlank -Value $entry.Value)) {
            throw "參數 '$($entry.Key)' 不得為空白。"
        }
    }

    foreach ($identityField in @(
            [pscustomobject]@{ name = 'LineSlug'; value = $LineSlug },
            [pscustomobject]@{ name = 'DispatchSlug'; value = $DispatchSlug })) {
        if (-not $PSBoundParameters.ContainsKey([string]$identityField.name) -or $null -eq $identityField.value) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestMissingField' -Classification 'MissingField' -Field ([string]$identityField.name) -Message ("參數 '{0}' 不可缺少。" -f $identityField.name) -Detail $null
        }
        if ($identityField.value -isnot [string]) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestFieldType' -Classification 'FieldType' -Field ([string]$identityField.name) -Message ("參數 '{0}' 必須是字串。" -f $identityField.name) -Detail ([ordered]@{ expected_type = 'string'; actual_type = $identityField.value.GetType().FullName })
        }
        if ([string]::IsNullOrWhiteSpace([string]$identityField.value) -or -not [regex]::IsMatch([string]$identityField.value, '^[a-z0-9]+(?:-[a-z0-9]+)*$')) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestInvalidValue' -Classification 'InvalidValue' -Field ([string]$identityField.name) -Message ("參數 '{0}' 必須是小寫 slug。" -f $identityField.name) -Detail ([ordered]@{ received = [string]$identityField.value })
        }
    }

    if (-not $PSBoundParameters.ContainsKey('TargetPath') -or $null -eq $TargetPath) {
        Throw-DispatchOrderValidationFailure -Code 'DispatchRequestMissingField' -Classification 'MissingField' -Field 'TargetPath' -Message "參數 'TargetPath' 不可缺少。" -Detail $null
    }
    if ($TargetPath -is [array]) {
        $targetPathItems = @($TargetPath)
    }
    elseif ($TargetPath -is [string]) {
        $targetPathItems = @($TargetPath)
    }
    else {
        Throw-DispatchOrderValidationFailure -Code 'DispatchRequestFieldType' -Classification 'FieldType' -Field 'TargetPath' -Message "參數 'TargetPath' 必須是字串或字串陣列。" -Detail ([ordered]@{ expected_type = 'string[]'; actual_type = $TargetPath.GetType().FullName })
    }
    if ($targetPathItems.Count -eq 0) {
        Throw-DispatchOrderValidationFailure -Code 'DispatchRequestMissingField' -Classification 'MissingField' -Field 'TargetPath' -Message "參數 'TargetPath' 至少需要一項。" -Detail ([ordered]@{ count = 0 })
    }

    $targetPaths = New-Object 'System.Collections.Generic.List[string]'
    for ($index = 0; $index -lt $targetPathItems.Count; $index++) {
        if ($null -eq $targetPathItems[$index]) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestNullArrayElement' -Classification 'FieldType' -Field 'TargetPath' -Message ("參數 'TargetPath' 第 {0} 項不可為 null。" -f $index) -Detail ([ordered]@{ index = $index })
        }
        if ($targetPathItems[$index] -isnot [string]) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestFieldType' -Classification 'FieldType' -Field 'TargetPath' -Message ("參數 'TargetPath' 第 {0} 項必須是字串。" -f $index) -Detail ([ordered]@{ index = $index; expected_type = 'string'; actual_type = $targetPathItems[$index].GetType().FullName })
        }
        $targetPathValue = [string]$targetPathItems[$index]
        if ([string]::IsNullOrWhiteSpace($targetPathValue)) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestInvalidValue' -Classification 'InvalidValue' -Field 'TargetPath' -Message ("參數 'TargetPath' 第 {0} 項不可為空白。" -f $index) -Detail ([ordered]@{ index = $index })
        }

        if (-not (Test-AbsolutePath -Value $targetPathValue)) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'TargetPath' -Message ("參數 'TargetPath' 第 {0} 項必須是完整絕對路徑。" -f $index) -Detail ([ordered]@{ index = $index; expected = 'fully-qualified path'; received = $targetPathValue })
        }
        $targetPaths.Add($targetPathValue)
    }

    $TargetPath = $targetPaths.ToArray()

    if (-not (Test-AbsolutePath -Value $ReportPath)) {
        Throw-DispatchOrderValidationFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'ReportPath' -Message "參數 'ReportPath' 必須是完整絕對路徑。" -Detail ([ordered]@{ expected = 'fully-qualified path'; received = [string]$ReportPath })
    }

    if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Get-DefaultDispatchOrderPath -ReportPath $ReportPath -LineSlug ([string]$LineSlug) -DispatchSlug ([string]$DispatchSlug)
    }

    if (-not (Test-AbsolutePath -Value $OutputPath)) {
        Throw-DispatchOrderValidationFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'OutputPath' -Message "參數 'OutputPath' 必須是完整絕對路徑。" -Detail ([ordered]@{ expected = 'fully-qualified path'; received = [string]$OutputPath })
    }

    if ($null -eq $Acceptance -or $Acceptance.Count -eq 0) {
        throw "參數 'Acceptance' 至少需要一項。"
    }

    $allowedCapabilities = @(
        'process-query'
        'network'
        'desktop'
        'build'
        'container'
        'gpu'
    )

    for ($index = 0; $index -lt $Acceptance.Count; $index++) {
        $item = $Acceptance[$index]
        $rowNumber = $index + 1

        if ($null -eq $item) {
            throw "Acceptance 第 $rowNumber 列不可為空。"
        }

        foreach ($key in @('Category', 'Condition', 'Command')) {
            if (-not $item.ContainsKey($key)) {
                throw "Acceptance 第 $rowNumber 列缺少 $key。"
            }
        }

        $category = [string]$item['Category']
        $condition = [string]$item['Condition']
        $command = [string]$item['Command']

        if ($category -ne '新行為' -and $category -ne '回歸守衛') {
            throw "Acceptance 第 $rowNumber 列 Category 無效，只允許新行為或回歸守衛。"
        }

        if ([string]::IsNullOrWhiteSpace($condition)) {
            throw "Acceptance 第 $rowNumber 列 Condition 不得為空白。"
        }

        if ([string]::IsNullOrWhiteSpace($command)) {
            throw "Acceptance 第 $rowNumber 列 Command 不得為空白。"
        }

        if (Test-UnsafeSearchLineEndAnchor -CommandText $command) {
            Throw-DispatchOrderValidationFailure -Code 'DispatchRequestInvalidValue' -Classification 'InvalidValue' -Field 'Acceptance.Command' -Message ('Acceptance 第 {0} 列命令含 CRLF 不適用的行尾 $ 錨點；請去掉 $ 或改為 \r?$。' -f $rowNumber) -Detail ([ordered]@{ index = $rowNumber - 1; remediation = '移除 $ 或改為 \r?$' })
        }

        if ($item.ContainsKey('Capability') -and $null -ne $item['Capability']) {
            $capabilities = @([string[]]$item['Capability'])
            foreach ($capability in $capabilities) {
                $capabilityValue = [string]$capability
                if ([string]::IsNullOrWhiteSpace($capabilityValue)) {
                    throw "Acceptance 第 $rowNumber 列 Capability 不得包含空白值。"
                }

                if ($allowedCapabilities -notcontains $capabilityValue) {
                    throw "Acceptance 第 $rowNumber 列 Capability 包含非法值 '$capabilityValue'。"
                }
            }
        }
    }

    $absoluteOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $outputParent = Split-Path -Parent $absoluteOutputPath
    $sessionsParent = Split-Path -Parent $outputParent
    $localParent = Split-Path -Parent $sessionsParent
    if ((Split-Path -Leaf $absoluteOutputPath) -ieq ('dispatch-order-' + $DispatchSlug + '.md') -and
        (Split-Path -Leaf $outputParent) -ieq 'handoff' -and
        (Split-Path -Leaf $sessionsParent) -ieq 'ai-sessions' -and
        (Split-Path -Leaf $localParent) -ieq '.local') {
        $correctPath = Join-Path (Join-Path $outputParent $LineSlug) (Split-Path -Leaf $absoluteOutputPath)
        Throw-DispatchOrderValidationFailure -Code 'DispatchInputOrderLocationInvalid' -Classification 'InvalidPath' -Field 'OutputPath' -Message ('請使用線目錄路徑：' + $correctPath) -Detail ([ordered]@{ expected = $correctPath; received = $absoluteOutputPath })
    }
    if ($PSBoundParameters.ContainsKey('RequiredRead')) {
        $buildCandidate = {
            param([string]$Body)
            New-DispatchOrderContent -Title $Title -Role $Role -TargetPath $TargetPath -TaskBody $Body -Acceptance $Acceptance -Boundary $Boundary -ReportPath ([System.IO.Path]::GetFullPath($ReportPath)) -DispatchSlug $DispatchSlug -LineSlug $LineSlug -OutputPath $absoluteOutputPath
        }
        $readCandidateOrder = {
            param([string]$Body)
            $candidate = & $buildCandidate $Body
            $sectionMatch = [regex]::Match($candidate, '(?ms)^##\s+4\.\s+任務內容\s*\r?\n(?<section>.*?)(?=^##\s+5\.)')
            $sectionText = [string]$sectionMatch.Groups['section'].Value
            $startLine = if ($sectionMatch.Success) { ([regex]::Matches($candidate.Substring(0, $sectionMatch.Groups['section'].Index), '\r?\n')).Count + 1 } else { 1 }
            [pscustomobject]@{ Path = $absoluteOutputPath; TaskBody = $sectionText; TaskBodyStartLine = $startLine }
        }
        $existingOrder = & $readCandidateOrder $TaskBody
        $existingBlock = Read-DispatchRequiredReadBlock -Order $existingOrder
        $headingErrors = @($existingBlock.block_errors | Where-Object { $_.code -eq 'DispatchInputRequiredReadHeadingInvalid' })
        if ($existingBlock.present -or $headingErrors.Count -gt 0) {
            $headingLine = if ($existingBlock.present) { $existingBlock.heading_line } else { $headingErrors[0].line }
            $headingRaw = if ($existingBlock.present) { $existingBlock.heading_raw } else { $headingErrors[0].raw }
            $exampleCandidates = @($RequiredRead | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            $examplePath = if ($exampleCandidates.Count -gt 0) { [string]$exampleCandidates[0] } else { '' }
            $finding = New-DispatchRequiredReadFinding -CheckId 'DI-REQREAD' -Severity 'error' -Code 'DispatchInputRequiredReadHeadingInvalid' -Reason 'TaskBody 已含「必讀檔案」標題，使用 -RequiredRead 時請移除 TaskBody 內的標題與清單，必讀檔案只由 -RequiredRead 提供' -Order $existingOrder -Line $headingLine -Raw $headingRaw -Path ([string]$examplePath)
            Throw-DispatchOrderValidationFailure -Code 'DispatchInputRequiredReadHeadingInvalid' -Classification 'InvalidValue' -Field 'TaskBody' -Message $finding.message -Detail ([ordered]@{ expected = $finding.expected; received = $finding.received; source = $finding.source; line = $finding.line; order_field = 4 })
        }
        $requiredItems = @($RequiredRead)
        $bodyTrimmed = $TaskBody.TrimEnd("`r", "`n")
        if ($requiredItems.Count -eq 0) {
            $emptyFinding = New-DispatchRequiredReadFinding -CheckId 'DI-REQREAD' -Severity 'error' -Code 'DispatchInputRequiredReadEmpty' -Reason '-RequiredRead 沒有任何路徑，沒有必讀檔案時請不要提供 -RequiredRead' -Order $existingOrder -Line $existingOrder.TaskBodyStartLine -Raw '（-RequiredRead 為空）' -Path ''
            Throw-DispatchOrderValidationFailure -Code 'DispatchInputRequiredReadEmpty' -Classification 'InvalidValue' -Field 'RequiredRead' -Message $emptyFinding.message -Detail ([ordered]@{ expected = $emptyFinding.expected; received = $emptyFinding.received; source = $emptyFinding.source; line = $emptyFinding.line; order_field = 4 })
        }
        for ($itemIndex = 0; $itemIndex -lt $requiredItems.Count; $itemIndex++) {
            $item = [string]$requiredItems[$itemIndex]
            try { $null = Format-DispatchRequiredReadBlock -Path @($item) }
            catch {
                $code = ([string]$_.Exception.Message -split '：', 2)[0]
                $reason = ([string]$_.Exception.Message -split '：', 2)[1]
                $rawLines = @($requiredItems | ForEach-Object { '- `' + (([string]$_) -replace '\r?\n', ' ') + '`' })
                $failedOrder = & $readCandidateOrder ($bodyTrimmed + "`r`n`r`n必讀檔案：`r`n" + ($rawLines -join "`r`n"))
                $failedBlock = Read-DispatchRequiredReadBlock -Order $failedOrder
                $failedLine = if ($failedBlock.present) { $failedBlock.heading_line + 1 + $itemIndex } else { $failedOrder.TaskBodyStartLine }
                $failedFinding = New-DispatchRequiredReadFinding -CheckId 'DI-REQREAD' -Severity 'error' -Code $code -Reason $reason -Order $failedOrder -Line $failedLine -Raw $rawLines[$itemIndex] -Path $item
                Throw-DispatchOrderValidationFailure -Code $code -Classification 'InvalidValue' -Field 'RequiredRead' -Message $failedFinding.message -Detail ([ordered]@{ index = $itemIndex; expected = $failedFinding.expected; received = $failedFinding.received; source = $failedFinding.source; line = $failedFinding.line; order_field = 4 })
            }
        }
        $requiredBlock = Format-DispatchRequiredReadBlock -Path $requiredItems
        $combinedBody = $bodyTrimmed + "`r`n`r`n" + $requiredBlock
        $combinedOrder = & $readCandidateOrder $combinedBody
        $combinedParsed = Read-DispatchRequiredReadBlock -Order $combinedOrder
        $combinedOk = $combinedParsed.present -and $combinedParsed.block_errors.Count -eq 0 -and $combinedParsed.entries.Count -eq $requiredItems.Count
        if ($combinedOk) {
            for ($itemIndex = 0; $itemIndex -lt $requiredItems.Count; $itemIndex++) {
                if ($combinedParsed.entries[$itemIndex].state -ne 'ok' -or -not [string]::Equals([string]$combinedParsed.entries[$itemIndex].path, [string]$requiredItems[$itemIndex], [StringComparison]::Ordinal)) { $combinedOk = $false; break }
            }
        }
        if (-not $combinedOk) {
            $tailStart = $combinedOrder.TaskBodyStartLine + @($bodyTrimmed -split '\r?\n').Count + 1
            $tailFinding = New-DispatchRequiredReadFinding -CheckId 'DI-REQREAD' -Severity 'error' -Code 'DispatchInputRequiredReadHeadingInvalid' -Reason 'TaskBody 含未閉合的 ``` 程式碼區塊或 <!-- 註解，追加的「必讀檔案：」區塊無法被辨識為區塊，請先閉合 TaskBody 內的 ``` 與 <!-- --> 後再提供 -RequiredRead' -Order $combinedOrder -Line $tailStart -Raw '必讀檔案：' -Path ([string]$requiredItems[0])
            Throw-DispatchOrderValidationFailure -Code 'DispatchInputRequiredReadHeadingInvalid' -Classification 'InvalidValue' -Field 'TaskBody' -Message $tailFinding.message -Detail ([ordered]@{ expected = $tailFinding.expected; received = $tailFinding.received; source = $tailFinding.source; line = $tailFinding.line; order_field = 4 })
        }
        $TaskBody = $combinedBody
    }
    $content = New-DispatchOrderContent `
        -Title $Title `
        -Role $Role `
        -TargetPath $TargetPath `
        -TaskBody $TaskBody `
        -Acceptance $Acceptance `
        -Boundary $Boundary `
        -ReportPath ([System.IO.Path]::GetFullPath($ReportPath)) `
        -DispatchSlug $DispatchSlug `
        -LineSlug $LineSlug `
        -OutputPath $absoluteOutputPath

    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $outputDirectory = Split-Path -Parent $absoluteOutputPath
    [void][System.IO.Directory]::CreateDirectory($outputDirectory)
    [System.IO.File]::WriteAllText($absoluteOutputPath, $content, $utf8WithoutBom)
    Write-Output $absoluteOutputPath
    exit 0
}
catch {
    $operationResult = $_.Exception.Data['operationResult']
    if ($null -ne $operationResult -and $operationResult -is [System.Collections.IDictionary]) {
        [Console]::Error.WriteLine((ConvertTo-Json -InputObject $operationResult -Depth 10 -Compress))
    }
    else {
        [Console]::Error.WriteLine(("New-DispatchOrder.ps1: {0}" -f $_.Exception.Message))
    }
    exit 1
}
