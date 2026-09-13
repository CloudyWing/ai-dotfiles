#Requires -Version 5.1

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

    return [System.IO.Path]::IsPathRooted($Value)
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
    $lineReportRoot = Join-Path -Path $reportDirectory -ChildPath $LineSlug
    $fixedReportPath = Join-Path -Path $lineReportRoot -ChildPath 'support-engineer-report.md'
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
- 明文寫入例外：執行角色規則檔指定的同線固定報告 FIXED_REPORT_PATH_VALUE。
- 明文寫入例外：同線 EXCEPTIONS_LABEL 的絕對路徑 EXCEPTIONS_PATH_VALUE。

## 7. 產出落點

CODE_FENCEtext
$ReportPath
CODE_FENCE

## 8. 回報必備欄位

逐條列出第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間與判定結果，另附每條類別與未修改狀態輸出，以及驗收腳本完整內容與新腳本的行數。

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
    $content = $content.Replace('FIXED_REPORT_PATH_VALUE', ('`' + $fixedReportPath + '`'))
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
        DispatchSlug = $DispatchSlug
        LineSlug = $LineSlug
        OutputPath = $OutputPath
    }

    foreach ($entry in $requiredValues.GetEnumerator()) {
        if (-not (Test-NonBlank -Value $entry.Value)) {
            throw "參數 '$($entry.Key)' 不得為空白。"
        }
    }

    if ($null -eq $TargetPath -or $TargetPath.Count -eq 0) {
        throw "參數 'TargetPath' 至少需要一項。"
    }

    for ($index = 0; $index -lt $TargetPath.Count; $index++) {
        if (-not (Test-NonBlank -Value $TargetPath[$index])) {
            throw "參數 'TargetPath' 第 $($index + 1) 項不得為空白。"
        }

        if (-not (Test-AbsolutePath -Value $TargetPath[$index])) {
            throw "參數 'TargetPath' 第 $($index + 1) 項必須是絕對路徑。"
        }
    }

    foreach ($pathEntry in @{
        ReportPath = $ReportPath
        OutputPath = $OutputPath
    }.GetEnumerator()) {
        if (-not (Test-AbsolutePath -Value $pathEntry.Value)) {
            throw "參數 '$($pathEntry.Key)' 必須是絕對路徑。"
        }
    }

    if (-not [regex]::IsMatch($DispatchSlug, '^[a-z0-9]+(?:-[a-z0-9]+)*$')) {
        throw "參數 'DispatchSlug' 格式無效，必須符合指定識別字規則。"
    }

    if (-not [regex]::IsMatch($LineSlug, '^[a-z0-9]+(?:-[a-z0-9]+)*$')) {
        throw "參數 'LineSlug' 格式無效，必須符合指定識別字規則。"
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
    [System.IO.File]::WriteAllText($absoluteOutputPath, $content, $utf8WithoutBom)
    Write-Output $absoluteOutputPath
    exit 0
}
catch {
    [Console]::Error.WriteLine(("New-DispatchOrder.ps1: {0}" -f $_.Exception.Message))
    exit 1
}
