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

    $lineHandoffRoot = Join-Path -Path $sourceAiSessionsRoot -ChildPath (Join-Path -Path 'handoff' -ChildPath $LineSlug)
    return Join-Path -Path $lineHandoffRoot -ChildPath ("dispatch-order-{0}.md" -f $DispatchSlug)
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
