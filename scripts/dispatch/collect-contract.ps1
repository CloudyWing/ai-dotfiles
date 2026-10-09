function Get-NameOnlyList {
    param(
        [Parameter(Mandatory)]
        [psobject]$Result
    )

    if ($Result.ExitCode -ne 0) {
        throw "Git 差異蒐集失敗，exit code $($Result.ExitCode)：$($Result.StdErr.Trim())"
    }

    return @(Get-GitOutputLines -Text $Result.StdOut | Sort-Object -Unique)
}

function Convert-ReportPathForComparison {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $normalized = $Path.Trim().Trim('`', '"', "'").Replace('\', '/')
    if ([System.IO.Path]::IsPathRooted($normalized) -and (Test-PathWithinRoot -Path $normalized -Root $DispatchRoot)) {
        return (Get-RelativePathFromRoot -Path $normalized -Root $DispatchRoot).Replace('\', '/')
    }
    return $normalized
}

function Convert-ComparisonPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalized = $Path.Trim().Trim('`', '"', "'").Replace('\', '/')
    while ($normalized.StartsWith('./', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }
    return $normalized
}

function Split-MarkdownTableRow {
    param(
        [Parameter(Mandatory)]
        [string]$Line
    )

    $cells = New-Object 'System.Collections.Generic.List[string]'
    $current = ''
    $characters = $Line.ToCharArray()
    for ($index = 0; $index -lt $characters.Length; $index++) {
        $character = [string]$characters[$index]
        if ($character -eq '\' -and $index + 1 -lt $characters.Length -and [string]$characters[$index + 1] -eq '|') {
            $current += '|'
            $index++
            continue
        }
        if ($character -eq '|') {
            $cells.Add($current)
            $current = ''
            continue
        }
        $current += $character
    }
    $cells.Add($current)

    $trimmedLine = $Line.Trim()
    if ($trimmedLine.StartsWith('|') -and $cells.Count -gt 0 -and $cells[0] -eq '') {
        $cells.RemoveAt(0)
    }
    if ($trimmedLine.EndsWith('|') -and $cells.Count -gt 0 -and $cells[$cells.Count - 1] -eq '') {
        $cells.RemoveAt($cells.Count - 1)
    }

    return @($cells | ForEach-Object { $_.Trim() })
}

function Get-TrimmedSectionLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Section
    )

    $rawLines = [regex]::Split($Section, '\r?\n')
    $firstIndex = 0
    while ($firstIndex -lt $rawLines.Count -and [string]::IsNullOrWhiteSpace($rawLines[$firstIndex])) {
        $firstIndex++
    }

    $lastIndex = $rawLines.Count - 1
    while ($lastIndex -ge $firstIndex -and [string]::IsNullOrWhiteSpace($rawLines[$lastIndex])) {
        $lastIndex--
    }

    $lines = New-Object 'System.Collections.Generic.List[object]'
    for ($index = $firstIndex; $index -le $lastIndex; $index++) {
        $lines.Add([pscustomobject]@{
                Text       = [string]$rawLines[$index]
                LineNumber = $index + 1
            })
    }

    return @($lines.ToArray())
}

function Add-InvalidSectionContent {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidSectionContent,

        [Parameter(Mandatory)]
        [string]$Heading,

        [Parameter(Mandatory)]
        [string]$LineNumber,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Line
    )

    $sectionPrefix = $Heading + '#'
    foreach ($existing in $InvalidSectionContent) {
        if ($existing.StartsWith($sectionPrefix, [System.StringComparison]::Ordinal)) {
            return
        }
    }

    $displayLine = if ($Line.Length -gt 80) { $Line.Substring(0, 80) } else { $Line }
    $InvalidSectionContent.Add(('{0}#{1}={2}' -f $Heading, $LineNumber, $displayLine))
}

function Get-RequirementIdsFromSummary {
    param(
        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter(Mandatory)]
        [string]$SummaryPath
    )

    $summaryIds = New-Object 'System.Collections.Generic.List[int]'
    $missingSections = New-Object 'System.Collections.Generic.List[string]'
    $invalidSummaryHeaders = New-Object 'System.Collections.Generic.List[string]'
    $invalidSummaryRows = New-Object 'System.Collections.Generic.List[string]'
    $emptySummaryFieldIds = New-Object 'System.Collections.Generic.List[string]'
    $invalidSectionContent = New-Object 'System.Collections.Generic.List[string]'
    $duplicateSummarySections = New-Object 'System.Collections.Generic.List[string]'
    $emptySectionCount = 0
    $expectedHeaders = @('#', '項目', '內容')
    $fieldNames = @('#', '項目', '內容')

    foreach ($heading in @('程式面項目', '功能面項目')) {
        $headingPattern = '(?m)^##[ \t]+' + [regex]::Escape($heading) + '[ \t]*\r?$'
        $headingMatches = [regex]::Matches($Content, $headingPattern)
        if ($headingMatches.Count -eq 0) {
            $missingSections.Add($heading)
            continue
        }

        if ($headingMatches.Count -gt 1) {
            $duplicateSummarySections.Add(('{0}:{1}={2}' -f [System.IO.Path]::GetFileName($SummaryPath), $heading, $headingMatches.Count))
        }

        $sectionPattern = '(?ms)^##[ \t]+' + [regex]::Escape($heading) + '[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)'
        $sectionMatches = [regex]::Matches($Content, $sectionPattern)
        foreach ($sectionMatch in $sectionMatches) {
            $sectionLabel = '{0}:{1}' -f [System.IO.Path]::GetFileName($SummaryPath), $heading
            $sectionLines = @(Get-TrimmedSectionLines -Section $sectionMatch.Groups['section'].Value)
            if ($sectionLines.Count -eq 1 -and [string]::Equals($sectionLines[0].Text.Trim(), '無', [System.StringComparison]::Ordinal)) {
                $emptySectionCount++
                continue
            }

            if ($sectionLines.Count -eq 0) {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少表格資料列'
                continue
            }

            $headerLine = $sectionLines[0]
            $headerCells = @(Split-MarkdownTableRow -Line $headerLine.Text)
            $headerValid = $headerCells.Count -eq $expectedHeaders.Count
            if ($headerValid) {
                for ($headerIndex = 0; $headerIndex -lt $expectedHeaders.Count; $headerIndex++) {
                    if (-not [string]::Equals($headerCells[$headerIndex], $expectedHeaders[$headerIndex], [System.StringComparison]::Ordinal)) {
                        $headerValid = $false
                        break
                    }
                }
            }
            if (-not $headerValid) {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$headerLine.LineNumber) -Line $headerLine.Text
            }

            $separatorValid = $false
            if ($sectionLines.Count -gt 1) {
                $separatorLine = $sectionLines[1]
                $separatorCells = @(Split-MarkdownTableRow -Line $separatorLine.Text)
                $separatorValid = $separatorCells.Count -eq $expectedHeaders.Count
                if ($separatorValid) {
                    foreach ($separatorCell in $separatorCells) {
                        if ($separatorCell -notmatch '^:?-{3,}:?$') {
                            $separatorValid = $false
                            break
                        }
                    }
                }
                if (-not $separatorValid) {
                    $invalidSummaryHeaders.Add($heading)
                    Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$separatorLine.LineNumber) -Line $separatorLine.Text
                }
            }
            else {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少表格分隔列'
            }

            $dataRowIndex = 0
            if ($separatorValid) {
                for ($lineIndex = 2; $lineIndex -lt $sectionLines.Count; $lineIndex++) {
                    $dataLine = $sectionLines[$lineIndex]
                    if ([string]::IsNullOrWhiteSpace($dataLine.Text)) {
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                        continue
                    }

                    $dataRowIndex++
                    $dataCells = @(Split-MarkdownTableRow -Line $dataLine.Text)
                    if ($dataCells.Count -le 1 -or $dataLine.Text.IndexOf('|') -lt 0) {
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                        continue
                    }

                    if ($dataCells.Count -ne $expectedHeaders.Count) {
                        $invalidSummaryRows.Add(('{0}#{1}' -f $heading, $dataRowIndex))
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                        continue
                    }

                    $idCell = $dataCells[0]
                    $rowLabel = if ($idCell -match '^\d+$') { $idCell } else { 'row' + $dataRowIndex }
                    $rowValid = $true
                    for ($fieldIndex = 0; $fieldIndex -lt $dataCells.Count; $fieldIndex++) {
                        if ([string]::IsNullOrWhiteSpace($dataCells[$fieldIndex])) {
                            $emptySummaryFieldIds.Add(('{0}#{1}:{2}' -f $heading, $rowLabel, $fieldNames[$fieldIndex]))
                            $rowValid = $false
                        }
                    }

                    if ($idCell -match '^\d+$') {
                        $summaryIds.Add([int]$idCell)
                    }
                    else {
                        $invalidSummaryRows.Add(('{0}#{1}' -f $heading, $dataRowIndex))
                        $rowValid = $false
                    }

                    if (-not $rowValid) {
                        Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber ([string]$dataLine.LineNumber) -Line $dataLine.Text
                    }
                }
            }

            if ($dataRowIndex -eq 0) {
                $invalidSummaryHeaders.Add($heading)
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少表格資料列'
            }
        }
    }

    if ($missingSections.Count -gt 0) {
        throw "需求摘要缺少必要節。missingSections=$($missingSections -join ','); summaryPath=$SummaryPath"
    }

    $duplicateSummaryIds = @($summaryIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { [int]$_.Name } | Sort-Object -Unique)
    $invalidSummaryHeaders = @($invalidSummaryHeaders | Sort-Object -Unique)
    $invalidSummaryRows = @($invalidSummaryRows | Sort-Object -Unique)
    $emptySummaryFieldIds = @($emptySummaryFieldIds | Sort-Object -Unique)
    $invalidSectionContent = @($invalidSectionContent | Sort-Object -Unique)
    $duplicateSummarySections = @($duplicateSummarySections | Sort-Object -Unique)
    if ($duplicateSummarySections.Count -gt 0 -or
        $invalidSectionContent.Count -gt 0 -or
        $invalidSummaryHeaders.Count -gt 0 -or
        $invalidSummaryRows.Count -gt 0 -or
        $emptySummaryFieldIds.Count -gt 0) {
        throw "需求摘要結構不一致。duplicateSummarySections=$($duplicateSummarySections -join ','); invalidSectionContent=$($invalidSectionContent -join ','); invalidSummaryHeader=$($invalidSummaryHeaders -join ','); invalidSummaryRows=$($invalidSummaryRows -join ','); emptySummaryFieldIds=$($emptySummaryFieldIds -join ','); duplicateSummaryIds=$($duplicateSummaryIds -join ','); summaryPath=$SummaryPath"
    }
    if ($summaryIds.Count -eq 0) {
        throw "需求摘要未解析到任何需求編號：$SummaryPath"
    }
    if ($duplicateSummaryIds.Count -gt 0) {
        throw "需求摘要編號重複。duplicateSummaryIds=$($duplicateSummaryIds -join ','); summaryPath=$SummaryPath"
    }

    return @($summaryIds | Sort-Object -Unique)
}

function Get-RequirementTableRows {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Section,

        [Parameter(Mandatory)]
        [string]$ReportName,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidColumnCountRows,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$EmptyFieldIds,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidRequirementCells,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidHeader

        ,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$InvalidSectionContent

        ,

        [AllowNull()]
        [System.Collections.Generic.List[string]]$InvalidStatusFields,

        [AllowEmptyString()]
        [string]$SelectedRequirement
    )

    $expectedHeaders = @('需求', '驗收方向', 'T-code', '實際行為', '證據', '狀態')
    $fieldNames = @('需求', '驗收方向', 'T-code', '實際行為', '證據', '狀態')
    $sectionLabel = '{0}:需求對照' -f $ReportName
    $sectionLines = @(Get-TrimmedSectionLines -Section $Section)
    if ($sectionLines.Count -lt 2) {
        $InvalidHeader.Add($ReportName + ':header-or-separator')
        if ($sectionLines.Count -eq 1) {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$sectionLines[0].LineNumber) -Line $sectionLines[0].Text
        }
        else {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少需求對照表格'
        }
        return [pscustomobject]@{ rows = @(); outOfScopeIds = @(); scopeLineCount = 0 }
    }

    $headerLine = $sectionLines[0]
    $headerCells = @(Split-MarkdownTableRow -Line $headerLine.Text)
    $headerValid = $headerCells.Count -eq $expectedHeaders.Count
    if ($headerValid) {
        for ($index = 0; $index -lt $expectedHeaders.Count; $index++) {
            if (-not [string]::Equals($headerCells[$index], $expectedHeaders[$index], [System.StringComparison]::Ordinal)) {
                $headerValid = $false
                break
            }
        }
    }
    if (-not $headerValid) {
        $InvalidHeader.Add($ReportName + ':header')
        Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$headerLine.LineNumber) -Line $headerLine.Text
    }

    $separatorLine = $sectionLines[1]
    $separatorCells = @(Split-MarkdownTableRow -Line $separatorLine.Text)
    $separatorValid = $separatorCells.Count -eq $expectedHeaders.Count
    if ($separatorValid) {
        foreach ($separatorCell in $separatorCells) {
            if ($separatorCell -notmatch '^:?-{3,}:?$') {
                $separatorValid = $false
                break
            }
        }
    }
    if (-not $separatorValid) {
        $InvalidHeader.Add($ReportName + ':separator')
        Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$separatorLine.LineNumber) -Line $separatorLine.Text
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $outOfScopeIds = New-Object 'System.Collections.Generic.List[int]'
    $scopeLineCount = 0
    $scopeLineSeen = $false
    $dataRowIndex = 0
    for ($lineIndex = 2; $lineIndex -lt $sectionLines.Count; $lineIndex++) {
        $line = $sectionLines[$lineIndex]
        if ([string]::IsNullOrWhiteSpace($line.Text)) {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line $line.Text
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($SelectedRequirement) -and $line.Text.StartsWith('範圍外（本輪不要求交付）：', [System.StringComparison]::Ordinal)) {
            $scopeLineCount++
            if ($scopeLineCount -gt 1) {
                Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line '範圍外需求行重複'
            }
            if ($dataRowIndex -eq 0) {
                Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line '範圍外需求行必須緊接需求對照表格'
            }
            $scopeLineSeen = $true
            $scopeMatch = [regex]::Match($line.Text, '^範圍外（本輪不要求交付）：(?<ids>無|#[1-9][0-9]*(?:、#[1-9][0-9]*)*)$')
            if (-not $scopeMatch.Success) {
                Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line $line.Text
                continue
            }
            if ($scopeMatch.Groups['ids'].Value -cne '無') {
                foreach ($scopeId in $scopeMatch.Groups['ids'].Value.Split('、')) {
                    $scopeIdValue = [int]$scopeId.Substring(1)
                    if ($outOfScopeIds.Contains($scopeIdValue)) {
                        Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line ('範圍外需求編號重複：' + $scopeId)
                    }
                    else {
                        $outOfScopeIds.Add($scopeIdValue)
                    }
                }
            }
            continue
        }
        if ($scopeLineSeen) {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line '需求對照表格後只能接一行範圍外需求清單'
            continue
        }

        $dataRowIndex++
        $cells = @(Split-MarkdownTableRow -Line $line.Text)
        if ($cells.Count -ne $expectedHeaders.Count) {
            $InvalidColumnCountRows.Add(('{0}#{1}' -f $ReportName, $dataRowIndex))
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line $line.Text
            continue
        }

        $requirementCell = $cells[0]
        $requirementLabel = if ($requirementCell -match '^#\d+$') { $requirementCell } else { 'row' + $dataRowIndex }
        $rowValid = $true
        for ($index = 0; $index -lt $cells.Count; $index++) {
            if ([string]::IsNullOrWhiteSpace($cells[$index])) {
                $EmptyFieldIds.Add(('{0}:{1}' -f $requirementLabel, $fieldNames[$index]))
                $rowValid = $false
            }
        }

        if ($requirementCell -notmatch '^#\d+$') {
            $InvalidRequirementCells.Add(('{0}#{1}:{2}' -f $ReportName, $dataRowIndex, $requirementCell))
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber ([string]$line.LineNumber) -Line $line.Text
            continue
        }

        $id = [int]$requirementCell.Substring(1)
        $status = $cells[5]
        if ($status -notin @('已交付', '部分交付', '未交付', '排除（design.md §8）')) {
            $rowValid = $false
            if ($null -ne $InvalidStatusFields) {
                $InvalidStatusFields.Add(('{0}#{1}:狀態={2}' -f $ReportName, $dataRowIndex, $status))
            }
        }
        if (-not $rowValid) {
            Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading '需求對照' -LineNumber ([string]$line.LineNumber) -Line $line.Text
        }
        $rows.Add([pscustomobject]@{
                Id       = $id
                Evidence = $cells[4]
                Status   = $status
            })
    }

    if ($dataRowIndex -eq 0) {
        Add-InvalidSectionContent -InvalidSectionContent $InvalidSectionContent -Heading $sectionLabel -LineNumber 'EOF' -Line '缺少需求對照資料列'
    }

    return [pscustomobject]@{
        rows = @($rows.ToArray())
        outOfScopeIds = @($outOfScopeIds.ToArray())
        scopeLineCount = $scopeLineCount
    }
}

function Get-RequirementMap {
    param(
        [AllowEmptyString()]
        [string]$RequirementSummaryPath,

        [Parameter(Mandatory)]
        [string[]]$ReportPath,

        [AllowEmptyString()]
        [string]$SelectedRequirement
    )

    $summaryDisplayPath = if ([string]::IsNullOrWhiteSpace($RequirementSummaryPath)) { '<empty>' } else { $RequirementSummaryPath }
    if ([string]::IsNullOrWhiteSpace($RequirementSummaryPath)) {
        throw "workflow Collect 必須提供 RequirementSummaryPath：$summaryDisplayPath"
    }

    $summaryFullPath = Resolve-AbsolutePath -Path $RequirementSummaryPath
    if (-not (Test-Path -LiteralPath $summaryFullPath -PathType Leaf)) {
        throw "找不到需求摘要：$summaryFullPath"
    }

    $summarySha256Before = Get-FileSha256 -Path $summaryFullPath
    $summaryContent = Get-Content -LiteralPath $summaryFullPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($summaryContent)) {
        throw "需求摘要為空：$summaryFullPath"
    }

    $requirementIds = @(Get-RequirementIdsFromSummary -Content $summaryContent -SummaryPath $summaryFullPath)
    $selectedRequirementIds = @()
    $expectedReportIds = @($requirementIds)
    $expectedOutOfScopeIds = @()
    if (-not [string]::IsNullOrWhiteSpace($SelectedRequirement)) {
        if ($SelectedRequirement -notmatch '^#[1-9][0-9]*(?:,#[1-9][0-9]*)*$') {
            throw 'SelectedRequirement 必須是以逗號分隔的 # 加正整數。'
        }
        $selectedRequirementIds = @($SelectedRequirement.Split(',') | ForEach-Object { [int]$_.Substring(1) })
        if (@($selectedRequirementIds | Sort-Object -Unique).Count -ne $selectedRequirementIds.Count) {
            throw 'SelectedRequirement 包含重複編號。'
        }
        foreach ($selectedId in $selectedRequirementIds) {
            if ($requirementIds -notcontains $selectedId) {
                throw ('SelectedRequirement 不存在於 requirement-summary.md：#' + $selectedId)
            }
        }
        $expectedReportIds = @($selectedRequirementIds)
        $expectedOutOfScopeIds = @($requirementIds | Where-Object { $selectedRequirementIds -notcontains $_ } | Sort-Object)
    }
    $summarySha256After = Get-FileSha256 -Path $summaryFullPath
    if (-not [string]::Equals($summarySha256Before, $summarySha256After, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "需求摘要在 Collect 解析期間變更。contractVersion=$script:WorkflowCollectContractVersion; summaryPath=$summaryFullPath; beforeSha256=$summarySha256Before; afterSha256=$summarySha256After"
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $invalidColumnCountRows = New-Object 'System.Collections.Generic.List[string]'
    $emptyFieldIds = New-Object 'System.Collections.Generic.List[string]'
    $invalidRequirementCells = New-Object 'System.Collections.Generic.List[string]'
    $invalidStatusFields = New-Object 'System.Collections.Generic.List[string]'
    $invalidHeader = New-Object 'System.Collections.Generic.List[string]'
    $invalidSectionContent = New-Object 'System.Collections.Generic.List[string]'
    $duplicateRequirementSections = New-Object 'System.Collections.Generic.List[string]'
    $reportEvidence = New-Object 'System.Collections.Generic.List[object]'
    $perReportMissingRequirementIds = New-Object 'System.Collections.Generic.List[int]'
    $perReportDuplicateRequirementIds = New-Object 'System.Collections.Generic.List[int]'
    $perReportUnknownRequirementIds = New-Object 'System.Collections.Generic.List[int]'
    $statusCounts = [ordered]@{
        '已交付'          = 0
        '部分交付'        = 0
        '未交付'          = 0
        '排除（design.md §8）' = 0
    }
    $validStatuses = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($status in $statusCounts.Keys) {
        [void]$validStatuses.Add([string]$status)
    }

    foreach ($report in @($ReportPath)) {
        $reportFullPath = Resolve-AbsolutePath -Path $report
        if (-not (Test-Path -LiteralPath $reportFullPath -PathType Leaf)) {
            throw "找不到結案報告：$reportFullPath"
        }

        $reportSha256Before = Get-FileSha256 -Path $reportFullPath
        $reportContent = Get-Content -LiteralPath $reportFullPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($reportContent)) {
            throw "結案報告為空：$reportFullPath"
        }

        $reportName = [System.IO.Path]::GetFileName($reportFullPath)
        $requirementHeadingMatches = [regex]::Matches($reportContent, '(?m)^##[ \t]+需求對照[ \t]*\r?$')
        if ($requirementHeadingMatches.Count -eq 0) {
            throw "結案報告缺少需求對照節：$reportFullPath"
        }

        if ($requirementHeadingMatches.Count -gt 1) {
            $duplicateRequirementSections.Add(('{0}={1}' -f $reportName, $requirementHeadingMatches.Count))
            $reportSha256After = Get-FileSha256 -Path $reportFullPath
            if (-not [string]::Equals($reportSha256Before, $reportSha256After, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "結案報告在 Collect 解析期間變更。contractVersion=$script:WorkflowCollectContractVersion; reportPath=$reportFullPath; beforeSha256=$reportSha256Before; afterSha256=$reportSha256After"
            }
            $reportEvidence.Add([ordered]@{ path = $reportFullPath; sha256 = $reportSha256After; row_count = 0 })
            continue
        }

        $requirementMatch = [regex]::Match($reportContent, '(?ms)^##[ \t]+需求對照[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
        if (-not $requirementMatch.Success) {
            throw "結案報告缺少需求對照節：$reportFullPath"
        }

        $tableResult = Get-RequirementTableRows -Section $requirementMatch.Groups['section'].Value -ReportName $reportName -InvalidColumnCountRows $invalidColumnCountRows -EmptyFieldIds $emptyFieldIds -InvalidRequirementCells $invalidRequirementCells -InvalidHeader $invalidHeader -InvalidSectionContent $invalidSectionContent -InvalidStatusFields $invalidStatusFields -SelectedRequirement $SelectedRequirement
        $reportRows = @($tableResult.rows)
        if (-not [string]::IsNullOrWhiteSpace($SelectedRequirement)) {
            $reportReportedIds = @($reportRows | ForEach-Object { $_.Id } | Sort-Object -Unique)
            $reportMissingIds = @($expectedReportIds | Where-Object { $reportReportedIds -notcontains $_ } | Sort-Object)
            $reportDuplicateIds = @($reportRows | Group-Object -Property Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { [int]$_.Name } | Sort-Object -Unique)
            $reportUnknownIds = @($reportReportedIds | Where-Object { $expectedReportIds -notcontains $_ } | Sort-Object)
            foreach ($id in $reportMissingIds) { $perReportMissingRequirementIds.Add([int]$id) }
            foreach ($id in $reportDuplicateIds) { $perReportDuplicateRequirementIds.Add([int]$id) }
            foreach ($id in $reportUnknownIds) { $perReportUnknownRequirementIds.Add([int]$id) }
            if ($reportMissingIds.Count -gt 0 -or $reportDuplicateIds.Count -gt 0 -or $reportUnknownIds.Count -gt 0) {
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading ($reportName + ':需求對照') -LineNumber 'table' -Line ('選定需求資料列不符：missing=' + ($reportMissingIds -join ',') + '; duplicate=' + ($reportDuplicateIds -join ',') + '; unknown=' + ($reportUnknownIds -join ','))
            }
            if ($tableResult.scopeLineCount -ne 1) {
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading ($reportName + ':需求對照') -LineNumber 'EOF' -Line '必須在表格正下方提供一行範圍外需求清單'
            }
            $declaredOutOfScopeIds = @($tableResult.outOfScopeIds | Sort-Object -Unique)
            $missingScopeIds = @($expectedOutOfScopeIds | Where-Object { $declaredOutOfScopeIds -notcontains $_ })
            $unexpectedScopeIds = @($declaredOutOfScopeIds | Where-Object { $expectedOutOfScopeIds -notcontains $_ })
            if ($missingScopeIds.Count -gt 0 -or $unexpectedScopeIds.Count -gt 0) {
                Add-InvalidSectionContent -InvalidSectionContent $invalidSectionContent -Heading ($reportName + ':需求對照') -LineNumber 'scope' -Line ('範圍外需求清單不符：missing=' + ($missingScopeIds -join ',') + '; unexpected=' + ($unexpectedScopeIds -join ','))
            }
        }
        foreach ($row in $reportRows) {
            $status = $row.Status
            if ($validStatuses.Contains($status)) {
                $statusCounts[$status] = [int]$statusCounts[$status] + 1
            }
            $rows.Add($row)
        }
        $reportSha256After = Get-FileSha256 -Path $reportFullPath
        if (-not [string]::Equals($reportSha256Before, $reportSha256After, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "結案報告在 Collect 解析期間變更。contractVersion=$script:WorkflowCollectContractVersion; reportPath=$reportFullPath; beforeSha256=$reportSha256Before; afterSha256=$reportSha256After"
        }
        $reportEvidence.Add([ordered]@{ path = $reportFullPath; sha256 = $reportSha256After; row_count = $reportRows.Count })
    }

    $reportedIds = @($rows | ForEach-Object { $_.Id } | Sort-Object -Unique)
    if ([string]::IsNullOrWhiteSpace($SelectedRequirement)) {
        $missingRequirementIds = @($expectedReportIds | Where-Object { $reportedIds -notcontains $_ } | Sort-Object)
        $duplicateRequirementIds = @($rows | Group-Object -Property Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { [int]$_.Name } | Sort-Object)
        $unknownRequirementIds = @($reportedIds | Where-Object { $expectedReportIds -notcontains $_ } | Sort-Object)
    }
    else {
        $missingRequirementIds = @($perReportMissingRequirementIds | Sort-Object -Unique)
        $duplicateRequirementIds = @($perReportDuplicateRequirementIds | Sort-Object -Unique)
        $unknownRequirementIds = @($perReportUnknownRequirementIds | Sort-Object -Unique)
    }
    $invalidStatusIds = @($rows | Where-Object { -not $validStatuses.Contains($_.Status) } | ForEach-Object { $_.Id } | Sort-Object -Unique)
    $duplicateRequirementSections = @($duplicateRequirementSections | Sort-Object -Unique)
    $invalidStatusFields = @($invalidStatusFields | Sort-Object -Unique)
    $invalidSectionContent = @($invalidSectionContent | Sort-Object -Unique)

    if ($duplicateRequirementSections.Count -gt 0 -or
        $invalidSectionContent.Count -gt 0 -or
        $missingRequirementIds.Count -gt 0 -or
        $duplicateRequirementIds.Count -gt 0 -or
        $unknownRequirementIds.Count -gt 0 -or
        $invalidColumnCountRows.Count -gt 0 -or
        $emptyFieldIds.Count -gt 0 -or
        $invalidRequirementCells.Count -gt 0 -or
        $invalidHeader.Count -gt 0 -or
        $invalidStatusFields.Count -gt 0 -or
        $invalidStatusIds.Count -gt 0) {
        throw "需求對照結構不一致。contractVersion=$script:WorkflowCollectContractVersion; duplicateRequirementSections=$($duplicateRequirementSections -join ','); invalidSectionContent=$($invalidSectionContent -join ','); missingRequirementIds=$($missingRequirementIds -join ','); duplicateRequirementIds=$($duplicateRequirementIds -join ','); unknownRequirementIds=$($unknownRequirementIds -join ','); invalidColumnCountRows=$($invalidColumnCountRows -join ','); emptyFieldIds=$($emptyFieldIds -join ','); invalidRequirementCells=$($invalidRequirementCells -join ','); invalidHeader=$($invalidHeader -join ','); invalidStatusFields=$($invalidStatusFields -join ','); invalidStatusIds=$($invalidStatusIds -join ',')"
    }

    return [ordered]@{
        contractVersion = $script:WorkflowCollectContractVersion
        summaryPath     = $summaryFullPath
        summarySha256   = $summarySha256After
        requirementIds  = @($requirementIds)
        selectedRequirement = if ($selectedRequirementIds.Count -eq 0) { $null } else { ($selectedRequirementIds | ForEach-Object { '#' + [string]$_ }) -join ',' }
        outOfScopeRequirementIds = @($expectedOutOfScopeIds)
        reportEvidence  = @($reportEvidence.ToArray())
        reportRowCount  = $rows.Count
        statusCounts    = $statusCounts
    }
}

function Get-ReportReferencedPaths {
    param(
        [Parameter(Mandatory)]
        [string[]]$ReportPath,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $references = New-Object System.Collections.Generic.List[string]
    foreach ($report in $ReportPath) {
        $reportFullPath = Resolve-AbsolutePath -Path $report
        if (-not (Test-Path -LiteralPath $reportFullPath -PathType Leaf)) {
            throw "找不到結案報告：$reportFullPath"
        }
        $content = Get-Content -LiteralPath $reportFullPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) {
            throw "結案報告為空：$reportFullPath"
        }
        $phaseMatch = [regex]::Match($content, '(?ms)^##\s+Phase 對照\s*$\r?\n(?<section>.*?)(?=^##\s|\z)')
        if (-not $phaseMatch.Success) {
            throw "結案報告缺少 Phase 對照節：$reportFullPath"
        }
        $section = $phaseMatch.Groups['section'].Value
        foreach ($match in [regex]::Matches($section, '`([^`]+)`')) {
            $candidate = Convert-ReportPathForComparison -Path $match.Groups[1].Value -DispatchRoot $DispatchRoot
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $references.Add($candidate)
            }
        }
    }

    return @($references | Sort-Object -Unique)
}

function Get-DirectWriteFileEvidence {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$EvidenceName,

        [switch]$AllowEmpty
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $SourceRoot)) {
        throw "direct-write 的 $EvidenceName 超出 sourceRoot：$fullPath"
    }
    Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $fullPath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "direct-write 缺少 $EvidenceName 檔案證據：$fullPath"
    }

    $file = Get-Item -LiteralPath $fullPath -Force
    if ($file.Length -le 0 -and -not $AllowEmpty) {
        throw "direct-write 的 $EvidenceName 檔案為空：$fullPath"
    }

    $hash = Get-FileSha256 -Path $fullPath
    return [ordered]@{
        path             = $fullPath
        relativePath     = Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot
        length           = [int64]$file.Length
        lastWriteTimeUtc = $file.LastWriteTimeUtc.ToString('o')
        sha256           = $hash
    }
}

function Get-CollectInterruptionCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$ExecutionRoot,
        [Parameter(Mandatory)][string]$LineSlug,
        [Parameter(Mandatory)][string]$DispatchSlug,
        [AllowEmptyString()][string]$RunRecordPath
    )

    if ([string]::IsNullOrWhiteSpace($RunRecordPath)) {
        return $null
    }
    try {
        $runRecord = Read-DispatchRunRecord -Path $RunRecordPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $scopePlan = if ([string]::IsNullOrWhiteSpace([string]$runRecord.scope_plan_path)) { $null } else { Read-ScopePlanFile -Path ([string]$runRecord.scope_plan_path) }
        $selectedUnits = if ($null -eq $scopePlan) { @() } else { @($scopePlan.selected_units | ForEach-Object { [string]$_ }) }
        $checkpointPath = [string](Get-DispatchJsonProperty -Object $runRecord -Name 'interruption_checkpoint_path')
        if ([string]::IsNullOrWhiteSpace($checkpointPath)) {
            $checkpointPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$runRecord.run_id)
        }
        return Get-DispatchInterruptionCheckpoint -Path $checkpointPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$runRecord.run_id) -SelectedUnits $selectedUnits -SourcePath @($runRecord.request_path, $runRecord.scope_plan_path, $RunRecordPath, $runRecord.event_stream_path)
    }
    catch {
        return [ordered]@{
            status = 'invalid'
            path = $null
            line_slug = $LineSlug
            dispatch_slug = $DispatchSlug
            selected_units = @()
            confirmed_units = @()
            incomplete_units = @()
            source_locations = @()
            validation_error = '無法由 RunRecord 取得中斷保全檔：' + $_.Exception.Message
        }
    }
}

function Invoke-DirectWriteCollect {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot,

        [AllowEmptyString()]
        [string]$BaseSha,

        [AllowNull()]
        [object]$Preflight,

        [string]$PreflightPath,

        [string]$RequestPath,

        [string]$RunRecordPath,

        [AllowEmptyString()]
        [string]$RequiredIdentifier,

        [Parameter(Mandatory)]
        [ValidateSet('workflow', 'resource')]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$TargetStates,

        [Parameter(Mandatory)]
        [string[]]$ReportPath,

        [AllowNull()]
        [object]$RequirementMap,

        [string]$ReviewerReportPath,

        [string]$LineSlug,

        [string]$DispatchSlug
    )

    $identityValidation = $null
    $hasReviewerReport = -not [string]::IsNullOrWhiteSpace($ReviewerReportPath)
    $hasRequest = -not [string]::IsNullOrWhiteSpace($RequestPath)
    $hasRunRecord = -not [string]::IsNullOrWhiteSpace($RunRecordPath)
    $isFullCollection = $hasRequest -and $hasRunRecord
    $collectMode = if ($hasReviewerReport -and -not $isFullCollection) { 'structural-only' } else { 'full' }
    $identityRequested = if ($hasReviewerReport) {
        $isFullCollection
    }
    else {
        $hasRequest -or $hasRunRecord
    }
    if ($identityRequested) {
        $identityValidation = Test-DispatchCollectIdentity -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RequiredIdentifier $RequiredIdentifier -BaseSha $BaseSha -Preflight $Preflight -PreflightPath $PreflightPath -RequestPath $RequestPath -RunRecordPath $RunRecordPath -ReviewerReportPath $ReviewerReportPath
        if (-not $identityValidation.valid) {
            $identityFailureResult = [ordered]@{
                operation          = 'Collect'
                collectionMode     = 'direct-write'
                sourceRoot         = $SourceRoot
                executionRoot      = $ExecutionRoot
                dispatchRoot       = $DispatchRoot
                baseSha            = $BaseSha
                dispatchKind       = $DispatchKind
                reportPaths        = @($ReportPath)
                reportEvidence     = @()
                collect_mode       = $collectMode
                identityMismatches = @($identityValidation.differences)
                identity           = $identityValidation
                reviewerFindings   = $identityValidation.reviewer_report
                outputValid        = $false
                worktreeRemoved    = $false
            }
            if ($DispatchKind -eq 'workflow') {
                $identityFailureResult.requirementMap = $RequirementMap
            }
            Throw-DispatchIdentityCollectFailure -Result $identityFailureResult
        }
    }
    $interruptionCheckpoint = Get-CollectInterruptionCheckpoint -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunRecordPath $RunRecordPath

    if ($TargetStates.Count -eq 0) {
        throw 'direct-write 的 Preflight 輸出缺少核准輸出清單 targetStates。'
    }

    $approvedOutputs = New-Object System.Collections.Generic.List[object]
    foreach ($targetState in @($TargetStates)) {
        $fullPathProperty = $targetState.PSObject.Properties['FullPath']
        if ($null -eq $fullPathProperty -or [string]::IsNullOrWhiteSpace([string]$fullPathProperty.Value)) {
            throw 'direct-write 的 targetStates 缺少有效 FullPath。'
        }
        $inputPathProperty = $targetState.PSObject.Properties['InputPath']
        $inputPath = if ($null -ne $inputPathProperty) { [string]$inputPathProperty.Value } else { '' }
        $targetPath = Resolve-AbsolutePath -Path ([string]$fullPathProperty.Value)
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $targetPath
        if (Test-Path -LiteralPath $targetPath -PathType Container) {
            $files = @(Get-CleanupRemovalEntries -Root $targetPath | Where-Object { -not $_.PSIsContainer } | Sort-Object FullName)
            if (@($files | Where-Object { $_.Length -gt 0 }).Count -eq 0) {
                throw ('direct-write 的核准輸出目錄沒有非空檔案：' + $targetPath)
            }
            foreach ($file in $files) {
                $approvedOutputs.Add([ordered]@{
                        inputPath = $inputPath
                        evidence = Get-DirectWriteFileEvidence -Path $file.FullName -SourceRoot $SourceRoot -EvidenceName '核准輸出' -AllowEmpty
                    })
            }
        }
        else {
            $approvedOutputs.Add([ordered]@{
                    inputPath = $inputPath
                    evidence = Get-DirectWriteFileEvidence -Path $targetPath -SourceRoot $SourceRoot -EvidenceName '核准輸出'
                })
        }
    }

    $reportEvidence = New-Object System.Collections.Generic.List[object]
    foreach ($report in @($ReportPath)) {
        $reportEvidence.Add((Get-DirectWriteFileEvidence -Path $report -SourceRoot $SourceRoot -EvidenceName '結案報告'))
    }
    $reviewerFindings = Get-ReviewerFindingsForCollect -Path $ReviewerReportPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -WriteLedger:$isFullCollection

    $result = [ordered]@{
        operation          = 'Collect'
        status             = 'collected'
        collectionMode     = 'direct-write'
        sourceRoot         = $SourceRoot
        executionRoot      = $ExecutionRoot
        dispatchRoot       = $DispatchRoot
        baseSha            = $BaseSha
        dispatchKind       = $DispatchKind
        worktreeCreated    = $false
        approvedOutputs    = @($approvedOutputs.ToArray())
        reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
        reportEvidence     = @($reportEvidence.ToArray())
        trackedDiff        = @()
        stagedDiff         = @()
        untrackedFiles     = @()
        carryInFiles       = @()
        newFiles           = @()
        rejectedFiles      = @()
        allFiles           = @()
        reportReferences   = @()
        missingFromReport  = @()
        unexpectedInReport = @()
        itemChecks         = @()
        collect_mode       = $collectMode
        interruptionCheckpoint = $interruptionCheckpoint
        reviewerFindings   = $reviewerFindings
        identity           = $identityValidation
        outputValid        = $true
        worktreeRemoved    = $false
    }


    if ($DispatchKind -eq 'workflow') {
        $result.requirementMap = $RequirementMap
    }

    if ($null -ne $reviewerFindings -and $reviewerFindings.valid -ne $true) {
        Throw-ReviewerFindingCollectFailure -Result $result
    }

    return $result
}

function Get-CollectTargetPathKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Container) { return 'directory' }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return 'file' }
    return $null
}

function Resolve-CollectTargetStates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$TargetStates,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $resolvedStates = New-Object 'System.Collections.Generic.List[object]'
    $kindChangedPaths = New-Object 'System.Collections.Generic.List[string]'
    $inferredAny = $false
    foreach ($target in $TargetStates) {
        $fullPathProperty = $target.PSObject.Properties['FullPath']
        $existsProperty = $target.PSObject.Properties['Exists']
        if ($null -eq $fullPathProperty -or $fullPathProperty.Value -isnot [string] -or $null -eq $existsProperty -or $existsProperty.Value -isnot [bool]) {
            throw 'Collect Preflight targetStates 缺少有效 FullPath 或 Exists。'
        }

        $sourceTargetPath = Resolve-AbsolutePath -Path ([string]$fullPathProperty.Value)
        $relativePath = (Get-RelativePathFromRoot -Path $sourceTargetPath -Root $SourceRoot).Replace('\', '/').TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = '.' }
        $sourcePath = Get-DispatchSnapshotPath -Root $SourceRoot -Path $relativePath
        $dispatchPath = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $relativePath
        $targetKindProperty = $target.PSObject.Properties['TargetKind']
        if ($null -ne $targetKindProperty) {
            $targetKind = [string]$targetKindProperty.Value
            if ($targetKind -notin @('file', 'directory')) {
                throw "Collect Preflight targetStates 的 TargetKind 無效：$sourceTargetPath"
            }
            $kindSource = 'preflight'
        }
        else {
            $inferredAny = $true
            if ($existsProperty.Value) {
                $targetKind = Get-CollectTargetPathKind -Path $sourcePath
                if ([string]::IsNullOrWhiteSpace($targetKind)) {
                    $targetKind = Get-CollectTargetPathKind -Path $dispatchPath
                }
                if ([string]::IsNullOrWhiteSpace($targetKind)) {
                    $inputPathProperty = $target.PSObject.Properties['InputPath']
                    $inputPath = if ($null -ne $inputPathProperty) { [string]$inputPathProperty.Value } else { $sourceTargetPath }
                    $targetKind = if ($inputPath.EndsWith([string][char]92, [StringComparison]::Ordinal) -or $inputPath.EndsWith([string][char]47, [StringComparison]::Ordinal)) { 'directory' } else { 'file' }
                }
            }
            else {
                $targetKind = 'file'
            }
            $kindSource = 'inferred'
        }

        $dispatchTargetKind = Get-CollectTargetPathKind -Path $dispatchPath
        if (($targetKind -eq 'file' -and $dispatchTargetKind -eq 'directory') -or
            ($targetKind -eq 'directory' -and $dispatchTargetKind -eq 'file')) {
            $kindChangedPaths.Add($sourceTargetPath)
        }

        $resolvedState = [ordered]@{}
        foreach ($property in $target.PSObject.Properties) {
            if ($property.Name -notin @('TargetKind', 'kind_source')) {
                $resolvedState[$property.Name] = $property.Value
            }
        }
        $resolvedState['TargetKind'] = $targetKind
        $resolvedState['kind_source'] = $kindSource
        $resolvedStates.Add([pscustomobject]$resolvedState)
    }

    return [pscustomobject]@{
        targetStates = @($resolvedStates.ToArray())
        kind_source = if ($inferredAny) { 'inferred' } else { 'preflight' }
        kindChangedPaths = @($kindChangedPaths.ToArray())
    }
}

function Get-CollectApprovedTargetDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$TargetStates,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$DispatchRoot
    )

    $directories = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in $TargetStates) {
        $fullPathProperty = $target.PSObject.Properties['FullPath']
        $existsProperty = $target.PSObject.Properties['Exists']
        $targetKindProperty = $target.PSObject.Properties['TargetKind']
        if ($null -eq $fullPathProperty -or $fullPathProperty.Value -isnot [string] -or $null -eq $existsProperty -or $existsProperty.Value -isnot [bool] -or $null -eq $targetKindProperty -or [string]$targetKindProperty.Value -notin @('file', 'directory')) {
            throw 'Collect Preflight targetStates 缺少有效 FullPath、Exists 或 TargetKind。'
        }

        $sourceTargetPath = Resolve-AbsolutePath -Path ([string]$fullPathProperty.Value)
        $relativePath = (Get-RelativePathFromRoot -Path $sourceTargetPath -Root $SourceRoot).Replace('\', '/').TrimEnd('/')
        if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = '.' }
        $sourcePath = Get-DispatchSnapshotPath -Root $SourceRoot -Path $relativePath
        $dispatchPath = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $relativePath
        $approvedDirectory = [string]$targetKindProperty.Value -eq 'directory'
        if ($approvedDirectory) {
            $directories.Add([pscustomobject]@{
                    RelativePath = $relativePath
                    SourcePath = $sourcePath
                    DispatchPath = $dispatchPath
                })
        }
    }

    return @($directories.ToArray())
}

function Find-CollectApprovedTargetDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ApprovedDirectories
    )

    $candidate = Get-DispatchSnapshotPath -Root $SourceRoot -Path $RelativePath
    foreach ($directory in $ApprovedDirectories) {
        if (Test-PathWithinRoot -Path $candidate -Root ([string]$directory.SourcePath)) { return $directory }
    }
    return $null
}

function Test-CollectGitPathIgnored {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DispatchRoot, [Parameter(Mandatory)][string]$RelativePath)

    $result = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('check-ignore', '--quiet', '--no-index', '--', $RelativePath.Replace('\', '/')) -AllowFailure
    if ($result.ExitCode -eq 0) { return $true }
    if ($result.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($result.StdErr)) { return $false }
    throw "Collect git check-ignore 無法判定路徑狀態：$RelativePath；exit code $($result.ExitCode)；$($result.StdErr.Trim())"
}

function Invoke-Collect {
    [CmdletBinding()]
    param([switch]$ApplyCollectedChanges)

    $unrelatedBoundParameters = @($script:InvocationBoundParameters.Keys | Where-Object { $_ -notin @('Operation', 'ReviewerReportPath') })
    $reviewerStructuralOnly = $script:InvocationBoundParameters.Contains('ReviewerReportPath') -and
        -not $script:InvocationBoundParameters.Contains('ReportPath') -and
        -not $script:InvocationBoundParameters.Contains('DispatchKind') -and
        $unrelatedBoundParameters.Count -eq 0
    if ($reviewerStructuralOnly) {
        $reviewerFindings = Get-ReviewerFindingsForCollect -Path $ReviewerReportPath -WriteLedger:$false
        $result = [ordered]@{
            operation        = 'Collect'
            collect_mode     = 'structural-only'
            reviewerFindings = $reviewerFindings
            outputValid      = $null -ne $reviewerFindings -and $reviewerFindings.valid -eq $true
            worktreeRemoved  = $false
        }
        if (-not $result.outputValid) {
            Throw-ReviewerFindingCollectFailure -Result $result
        }
        return $result
    }

    if ([string]::IsNullOrWhiteSpace($DispatchKind)) {
        throw 'Collect 必須提供 DispatchKind。'
    }

    $collectDispatchRoot = ''
    $collectRequestPath = ''
    $collectRunRecordPath = ''
    $collectRequiredIdentifier = ''
    $collectReviewerReportPath = ''
    foreach ($optionalVariable in @(
            [ordered]@{ name = 'DispatchRoot'; target = 'collectDispatchRoot' }
            [ordered]@{ name = 'RequestPath'; target = 'collectRequestPath' }
            [ordered]@{ name = 'RunRecordPath'; target = 'collectRunRecordPath' }
            [ordered]@{ name = 'RequiredIdentifier'; target = 'collectRequiredIdentifier' }
            [ordered]@{ name = 'ReviewerReportPath'; target = 'collectReviewerReportPath' }
        )) {
        $optionalValue = Get-Variable -Name $optionalVariable.name -ErrorAction SilentlyContinue
        if ($null -ne $optionalValue) {
            Set-Variable -Name $optionalVariable.target -Value ([string]$optionalValue.Value) -Scope Local
        }
    }

    $reportPathValues = @($ReportPath | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $hasConclusionReport = @($reportPathValues | Where-Object {
            try {
                Test-Path -LiteralPath (Resolve-AbsolutePath -Path ([string]$_)) -PathType Leaf
            }
            catch {
                $false
            }
        }).Count -gt 0
    if (-not $hasConclusionReport -and
        -not [string]::IsNullOrWhiteSpace($collectRunRecordPath) -and
        (Test-Path -LiteralPath $collectRunRecordPath -PathType Leaf) -and
        -not [string]::IsNullOrWhiteSpace($SourceRoot) -and
        -not [string]::IsNullOrWhiteSpace($ExecutionRoot) -and
        -not [string]::IsNullOrWhiteSpace($LineSlug) -and
        -not [string]::IsNullOrWhiteSpace($DispatchSlug)) {
        try {
            $collectRunRecord = Read-DispatchRunRecord -Path $collectRunRecordPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
            $recoverableArtifactState = Get-DispatchRecoverableArtifactState -RunRecord $collectRunRecord -ConclusionReportPath $reportPathValues
            if ($recoverableArtifactState.applicable) {
                $missingReportResult = [ordered]@{
                    operation = 'Collect'
                    status = 'failed'
                    sourceRoot = [string]$SourceRoot
                    executionRoot = [string]$ExecutionRoot
                    dispatchRoot = [string]$collectRunRecord.execution_root
                    baseSha = [string]$recoverableArtifactState.base_sha
                    dispatchKind = [string]$DispatchKind
                    reportPaths = @($reportPathValues | ForEach-Object { Resolve-AbsolutePath -Path ([string]$_) })
                    outputValid = $false
                    errorCode = 'ConclusionReportMissing'
                    error = 'turn.failed 且沒有結案報告；Collect 未套用變更，請由主 Agent 判定是否以新 slug 接續。'
                    recoverable_artifacts_present = [bool]$recoverableArtifactState.recoverable_artifacts_present
                    recoverable_artifact_files = @($recoverableArtifactState.recoverable_artifact_files)
                    worktreeRemoved = $false
                }
                $exception = New-Object System.InvalidOperationException([string]$missingReportResult.error)
                $exception.Data['errorCode'] = 'ConclusionReportMissing'
                $exception.Data['operationResult'] = $missingReportResult
                throw $exception
            }
        }
        catch {
            if ($null -ne $_.Exception.Data['operationResult']) {
                throw
            }
        }
    }
    if ($null -eq $ReportPath -or $ReportPath.Count -eq 0) {
        throw 'Collect 必須提供至少一個 ReportPath。'
    }
    $requirementMap = $null
    $selectedRequirement = ''
    $selectedRequirementVariable = Get-Variable -Name 'SelectedRequirement' -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $selectedRequirementVariable) {
        $selectedRequirement = [string]$selectedRequirementVariable.Value
    }
    if ($DispatchKind -eq 'workflow') {
        $requirementMap = Get-RequirementMap -RequirementSummaryPath $RequirementSummaryPath -ReportPath $ReportPath -SelectedRequirement $selectedRequirement
    }

    $preflight = $null
    $worktreeCreated = $true
    if (-not [string]::IsNullOrWhiteSpace($PreflightResultPath)) {
        $preflight = Get-PreflightData
        $operationProperty = $preflight.PSObject.Properties['operation']
        if ($null -ne $operationProperty -and [string]$operationProperty.Value -ne 'Preflight') {
            throw 'Collect 的 PreflightResultPath 必須指向 Preflight 輸出。'
        }
        $preflightSourceRoot = Resolve-AbsolutePath -Path (Get-RequiredPreflightProperty -Object $preflight -Name 'sourceRoot')
        $preflightExecutionRoot = Resolve-AbsolutePath -Path (Get-RequiredPreflightProperty -Object $preflight -Name 'executionRoot')
        $worktreeProperty = $preflight.PSObject.Properties['worktreeCreated']
        if ($null -eq $worktreeProperty -or $worktreeProperty.Value -isnot [bool]) {
            throw 'Collect 的 Preflight 輸出缺少布林欄位 worktreeCreated。'
        }
        $worktreeCreated = [bool]$worktreeProperty.Value
        if (-not $worktreeCreated) {
            if (-not [string]::Equals($preflightSourceRoot, $preflightExecutionRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'direct-write 的 Preflight 輸出必須讓 executionRoot 等於 sourceRoot。'
            }
            $baseProperty = $preflight.PSObject.Properties['baseSha']
            if ($null -eq $baseProperty -or -not [string]::IsNullOrEmpty([string]$baseProperty.Value)) {
                throw 'direct-write 的 Preflight 輸出必須保留空 baseSha，不得偽造 Git 基準。'
            }
            $targetStatesProperty = $preflight.PSObject.Properties['targetStates']
            if ($null -eq $targetStatesProperty) {
                throw 'direct-write 的 Preflight 輸出缺少 targetStates。'
            }
            $preflightDispatchRootProperty = $preflight.PSObject.Properties['dispatchRoot']
            $directDispatchRoot = if ($null -ne $preflightDispatchRootProperty -and -not [string]::IsNullOrWhiteSpace([string]$preflightDispatchRootProperty.Value)) {
                [string]$preflightDispatchRootProperty.Value
            }
            elseif (-not [string]::IsNullOrWhiteSpace($collectDispatchRoot)) {
                $collectDispatchRoot
            }
            else {
                $preflightSourceRoot
            }
            $preflightBaseShaProperty = $preflight.PSObject.Properties['baseSha']
            $directBaseSha = if ($null -eq $preflightBaseShaProperty) { '' } else { [string]$preflightBaseShaProperty.Value }
            if ($ApplyCollectedChanges) {
                throw 'DispatchCollectApplyDirectWriteNotApplicable：direct-write 已直接寫入 sourceRoot，Collect 不執行 worktree 套用。'
            }
            return Invoke-DirectWriteCollect -SourceRoot $preflightSourceRoot -ExecutionRoot $preflightExecutionRoot -DispatchRoot $directDispatchRoot -BaseSha $directBaseSha -Preflight $preflight -PreflightPath $PreflightResultPath -RequestPath $collectRequestPath -RunRecordPath $collectRunRecordPath -RequiredIdentifier $collectRequiredIdentifier -DispatchKind $DispatchKind -TargetStates @($targetStatesProperty.Value) -ReportPath $ReportPath -RequirementMap $requirementMap -ReviewerReportPath $collectReviewerReportPath -LineSlug (Get-RequiredPreflightProperty -Object $preflight -Name 'lineSlug') -DispatchSlug (Get-RequiredPreflightProperty -Object $preflight -Name 'dispatchSlug')
        }

        $preflightDispatchRootProperty = $preflight.PSObject.Properties['dispatchRoot']
        if ([string]::IsNullOrWhiteSpace($DispatchRoot) -and $null -ne $preflightDispatchRootProperty) {
            $DispatchRoot = [string]$preflightDispatchRootProperty.Value
        }
        $preflightBaseShaProperty = $preflight.PSObject.Properties['baseSha']
        if ([string]::IsNullOrWhiteSpace($BaseSha) -and $null -ne $preflightBaseShaProperty) {
            $BaseSha = [string]$preflightBaseShaProperty.Value
        }
    }

    if (-not $worktreeCreated -or [string]::IsNullOrWhiteSpace($DispatchRoot) -or [string]::IsNullOrWhiteSpace($BaseSha)) {
        throw 'Collect 必須提供 worktree 的 DispatchRoot 與 BaseSha，或提供 worktreeCreated=false 的 PreflightResultPath。'
    }

    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    if (-not (Test-Path -LiteralPath $dispatchRootPath -PathType Container)) {
        throw "dispatchRoot 不存在或不是目錄：$dispatchRootPath"
    }
    $baseResult = Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('rev-parse', '--verify', $BaseSha) -AllowFailure
    if ($baseResult.ExitCode -ne 0) {
        throw "baseSha 不存在於 dispatchRoot：$BaseSha"
    }
    $trackedDiff = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('diff', $BaseSha, '--name-only', '-z', '--')))
    $stagedDiff = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('diff', '--cached', '--name-only', '-z', '--')))
    $untrackedFiles = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('ls-files', '--others', '--exclude-standard', '-z')))
    $baselineSourceRoot = $SourceRoot
    $baselineLineSlug = $LineSlug
    $baselineDispatchSlug = $DispatchSlug
    if ($null -ne $preflight) {
        foreach ($entry in @(@('sourceRoot', $SourceRoot), @('lineSlug', $LineSlug), @('dispatchSlug', $DispatchSlug))) {
            $value = Get-RequiredPreflightProperty $preflight $entry[0]
            if (-not [string]::IsNullOrWhiteSpace($entry[1]) -and $value -cne $entry[1]) { throw 'Collect 顯式身分與 Preflight 不一致。' }
        }
        $baselineSourceRoot = $preflightSourceRoot
        $baselineLineSlug = Get-RequiredPreflightProperty $preflight 'lineSlug'
        $baselineDispatchSlug = Get-RequiredPreflightProperty $preflight 'dispatchSlug'
    }
    $baselineBinding = Resolve-DispatchBaselineBinding -Preflight $preflight -SourceRoot $baselineSourceRoot -DispatchRoot $dispatchRootPath -LineSlug $baselineLineSlug -DispatchSlug $baselineDispatchSlug -BaseSha $BaseSha -Path $BaselinePath -Sha256 $BaselineSha256
    $collectTargetStates = @()
    $targetKindSource = 'not-available'
    if ($null -ne $preflight) {
        $targetStatesProperty = $preflight.PSObject.Properties['targetStates']
        if ($null -ne $targetStatesProperty) {
            $targetKindResolution = Resolve-CollectTargetStates -TargetStates @($targetStatesProperty.Value) -SourceRoot $baselineSourceRoot -DispatchRoot $dispatchRootPath
            $collectTargetStates = @($targetKindResolution.targetStates)
            $targetKindSource = [string]$targetKindResolution.kind_source
            if (@($targetKindResolution.kindChangedPaths).Count -gt 0) {
                throw ('CollectTargetKindChanged：target 在 dispatch worktree 的類型與 Preflight 不一致：' + (@($targetKindResolution.kindChangedPaths) -join ', '))
            }
        }
    }    $dispatchDiff = @(Get-DispatchIncrementalChanges -Baseline $baselineBinding.Record -DispatchRoot $dispatchRootPath)
    $carryInFiles = @()
    $newFiles = @()
    $rejectedFiles = @()
    $protectedCarryInPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $carryInManifestProperty = if ($null -eq $preflight) { $null } else { $preflight.PSObject.Properties['carryInManifest'] }
    if ($null -ne $carryInManifestProperty -and $null -ne $carryInManifestProperty.Value) {
        $carryInUntrackedProperty = $carryInManifestProperty.Value.PSObject.Properties['UntrackedFiles']
        if ($null -ne $carryInUntrackedProperty) {
            $carryInFiles = @($carryInUntrackedProperty.Value | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        }
    }
    $carryInSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($carryInPath in $carryInFiles) {
        if ([string]::IsNullOrWhiteSpace($carryInPath)) { throw 'Preflight carryInManifest 含空白路徑。' }
        $null = Get-DispatchSnapshotPath -Root $dispatchRootPath -Path $carryInPath
        $null = Get-DispatchSnapshotPath -Root $baselineSourceRoot -Path $carryInPath
        $null = $carryInSet.Add($carryInPath)
    }
    $baselineFileByPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($baselineFile in @($baselineBinding.Record.files)) {
        $baselineFileByPath[[string]$baselineFile.path] = $baselineFile
    }
    $newFileSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($untrackedFile in $untrackedFiles) {
        if (-not $carryInSet.Contains([string]$untrackedFile)) {
            $null = $newFileSet.Add([string]$untrackedFile)
        }
    }
    $indexAddedFiles = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('diff', '--cached', '--diff-filter=A', '--name-only', '-z', '--')))
    foreach ($indexAddedFile in $indexAddedFiles) {
        $relativePath = [string]$indexAddedFile
        if ($carryInSet.Contains($relativePath) -or $baselineFileByPath.ContainsKey($relativePath)) { continue }
        $sourcePath = Get-DispatchSnapshotPath -Root $baselineSourceRoot -Path $relativePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            $null = $newFileSet.Add($relativePath)
        }
    }
    $newFiles = @($newFileSet | Sort-Object -Unique)
    $rejectedFileList = New-Object System.Collections.Generic.List[object]
    foreach ($carryInPath in $carryInFiles) {
        $baselineFile = if ($baselineFileByPath.ContainsKey($carryInPath)) { $baselineFileByPath[$carryInPath] } else { $null }
        $sourcePath = Get-DispatchSnapshotPath -Root $baselineSourceRoot -Path $carryInPath
        $sourceExists = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $sourceSha256 = if ($sourceExists) { Get-FileSha256 -Path $sourcePath } else { $null }
        $expectedSha256 = if ($null -ne $baselineFile -and $baselineFile.exists) { [string]$baselineFile.sha256 } else { $null }
        if ([string]::IsNullOrWhiteSpace($expectedSha256) -or -not $sourceExists -or $sourceSha256 -ine $expectedSha256) {
            $null = $protectedCarryInPaths.Add($carryInPath)
            $rejectedFileList.Add([ordered]@{
                    path = $carryInPath
                    reason = 'source-drift'
                    expected_sha256 = $expectedSha256
                    actual_sha256 = $sourceSha256
                    source_exists = [bool]$sourceExists
                })
            continue
        }
        if (@($dispatchDiff | Where-Object { [string]::Equals([string]$_, $carryInPath, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
            $null = $protectedCarryInPaths.Add($carryInPath)
            $rejectedFileList.Add([ordered]@{
                    path = $carryInPath
                    reason = 'carry-in-protected'
                    expected_sha256 = $expectedSha256
                    actual_sha256 = $sourceSha256
                    source_exists = $true
                })
        }
    }
    $rejectedFiles = @($rejectedFileList.ToArray())
    $allFiles = @($dispatchDiff | Where-Object { -not $carryInSet.Contains([string]$_) })
    $indexTracked = @(Get-NameOnlyList -Result (Invoke-GitCommand -WorkingDirectory $dispatchRootPath -Arguments @('ls-files', '-z')))
    $reportReferences = @()
    $missingFromReport = @()
    $unexpectedInReport = @()
    $matchesArray = @()
    $reportEvidence = @()
    $normalizedReportReferences = @()
    if ($DispatchKind -eq 'workflow') {
        $reportReferences = @(Get-ReportReferencedPaths -ReportPath $ReportPath -DispatchRoot $dispatchRootPath)
        $matches = New-Object System.Collections.Generic.List[object]
        $normalizedAllFiles = @($allFiles | ForEach-Object { Convert-ComparisonPath -Path $_ } | Sort-Object -Unique)
        $normalizedReportReferences = @($reportReferences | ForEach-Object { Convert-ComparisonPath -Path $_ } | Sort-Object -Unique)
        foreach ($file in $normalizedAllFiles) {
            $normalizedFile = $file
            $inReport = $normalizedReportReferences -contains $normalizedFile
            $matches.Add([pscustomobject]@{
                    Path      = $normalizedFile
                    InReport  = $inReport
                    IsStaged  = @($stagedDiff | ForEach-Object { Convert-ComparisonPath -Path $_ }) -contains $normalizedFile
                    IsTracked = @($indexTracked | ForEach-Object { Convert-ComparisonPath -Path $_ }) -contains $normalizedFile
                })
        }
        $matchesArray = @($matches.ToArray())
        $missingFromReport = @($matchesArray | Where-Object { -not $_.InReport } | ForEach-Object { $_.Path })
        $normalizedRejectedPaths = @($rejectedFiles | ForEach-Object { Convert-ComparisonPath -Path ([string]$_.path) } | Sort-Object -Unique)
        $unexpectedInReport = @($normalizedReportReferences | Where-Object { $normalizedAllFiles -notcontains $_ -and $normalizedRejectedPaths -notcontains $_ })
        if ($missingFromReport.Count -gt 0 -or $unexpectedInReport.Count -gt 0) {
            throw "差異清單與結案報告不一致。missingFromReport=$($missingFromReport -join ','); unexpectedInReport=$($unexpectedInReport -join ',')"
        }
    }
    else {
        $reportEvidenceList = New-Object System.Collections.Generic.List[object]
        foreach ($report in @($ReportPath)) {
            $reportEvidenceList.Add((Get-DirectWriteFileEvidence -Path $report -SourceRoot $dispatchRootPath -EvidenceName '結案報告'))
        }
        $reportEvidence = @($reportEvidenceList.ToArray())
    }

    $identityValidation = $null
    $hasReviewerReport = -not [string]::IsNullOrWhiteSpace($ReviewerReportPath)
    $hasRequest = -not [string]::IsNullOrWhiteSpace($RequestPath)
    $hasRunRecord = -not [string]::IsNullOrWhiteSpace($RunRecordPath)
    $isFullCollection = $hasRequest -and $hasRunRecord
    $collectMode = if ($hasReviewerReport -and -not $isFullCollection) { 'structural-only' } else { 'full' }
    $identityRequested = if ($hasReviewerReport) {
        $isFullCollection
    }
    else {
        $hasRequest -or $hasRunRecord
    }
    if ($identityRequested) {
        $identityValidation = Test-DispatchCollectIdentity -SourceRoot $baselineSourceRoot -ExecutionRoot $dispatchRootPath -DispatchRoot $dispatchRootPath -LineSlug $baselineLineSlug -DispatchSlug $baselineDispatchSlug -RequiredIdentifier $RequiredIdentifier -BaseSha $BaseSha -Preflight $preflight -PreflightPath $PreflightResultPath -RequestPath $RequestPath -RunRecordPath $RunRecordPath -ReviewerReportPath $ReviewerReportPath
        if (-not $identityValidation.valid) {
            $identityFailureResult = [ordered]@{
                operation          = 'Collect'
                dispatchRoot       = $dispatchRootPath
                baseSha            = $BaseSha
                dispatchKind       = $DispatchKind
                reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
                reportReferences   = @($normalizedReportReferences)
                missingFromReport  = @($missingFromReport)
                unexpectedInReport = @($unexpectedInReport)
                itemChecks         = $matchesArray
                carryInFiles       = @($carryInFiles)
                newFiles           = @($newFiles)
                rejectedFiles      = @($rejectedFiles)
                reportEvidence     = @($reportEvidence)
                collect_mode       = $collectMode
                identityMismatches = @($identityValidation.differences)
                identity           = $identityValidation
                reviewerFindings   = $identityValidation.reviewer_report
                outputValid        = $false
                worktreeRemoved    = $false
            }
            if ($DispatchKind -eq 'workflow') {
                $identityFailureResult.requirementMap = $requirementMap
            }
            Throw-DispatchIdentityCollectFailure -Result $identityFailureResult
        }
    }
    $interruptionCheckpoint = Get-CollectInterruptionCheckpoint -SourceRoot $baselineSourceRoot -ExecutionRoot $dispatchRootPath -LineSlug $baselineLineSlug -DispatchSlug $baselineDispatchSlug -RunRecordPath $RunRecordPath
    $reviewerFindings = Get-ReviewerFindingsForCollect -Path $ReviewerReportPath -SourceRoot $baselineSourceRoot -ExecutionRoot $dispatchRootPath -LineSlug $baselineLineSlug -DispatchSlug $baselineDispatchSlug -WriteLedger:$isFullCollection

    $result = [ordered]@{
        operation          = 'Collect'
        status             = 'collected'
        dispatchRoot       = $dispatchRootPath
        baseSha            = $BaseSha
        dispatchKind       = $DispatchKind
        trackedDiff        = @($trackedDiff)
        stagedDiff         = @($stagedDiff)
        untrackedFiles     = @($untrackedFiles)
        carryInFiles       = @($carryInFiles)
        newFiles           = @($newFiles)
        rejectedFiles      = @($rejectedFiles)
        allFiles           = @($allFiles)
        dispatchDiff       = @($dispatchDiff)
        baselinePath       = $baselineBinding.Path
        baselineSha256     = $baselineBinding.Sha256
        reportPaths        = @($ReportPath | ForEach-Object { Resolve-AbsolutePath -Path $_ })
        reportReferences   = @($normalizedReportReferences)
        missingFromReport  = @($missingFromReport)
        unexpectedInReport = @($unexpectedInReport)
        itemChecks         = $matchesArray
        targetStates       = @($collectTargetStates)
        kind_source        = $targetKindSource
        interruptionCheckpoint = $interruptionCheckpoint
        reportEvidence     = @($reportEvidence)
        collect_mode       = $collectMode
        outputValid        = $true
        reviewerFindings   = $reviewerFindings
        identity           = $identityValidation
        worktreeRemoved    = $false
    }

    if ($DispatchKind -eq 'workflow') {
        $result.requirementMap = $requirementMap
    }

    if ($null -ne $reviewerFindings -and $reviewerFindings.valid -ne $true) {
        Throw-ReviewerFindingCollectFailure -Result $result
    }

    if ($ApplyCollectedChanges) {
        if ($null -eq $script:CallerSessionIdentity) {
            throw 'CallerSessionIdMissing：Collect apply 必須提供 caller Session ID。'
        }
        $approvedTargetDirectories = @()
        if ($null -ne $preflight) {
            $approvedTargetDirectories = @(Get-CollectApprovedTargetDirectories -TargetStates @($collectTargetStates) -SourceRoot $baselineSourceRoot -DispatchRoot $dispatchRootPath)
        }
        $unapprovedNewFiles = @($newFiles | Where-Object {
            $candidate = Get-DispatchSnapshotPath -Root $baselineSourceRoot -Path ([string]$_)
            $approved = $false
            if ($null -ne $preflight) {
                foreach ($target in @($collectTargetStates)) {
                    $targetPathValue = Resolve-AbsolutePath ([string]$target.FullPath)
                    if ([string]::Equals($candidate, $targetPathValue, [StringComparison]::OrdinalIgnoreCase)) { $approved = $true; break }
                }
                if (-not $approved) {
                    $approvedDirectory = Find-CollectApprovedTargetDirectory -SourceRoot $baselineSourceRoot -RelativePath ([string]$_) -ApprovedDirectories $approvedTargetDirectories
                    if ($null -ne $approvedDirectory -and -not (Test-CollectGitPathIgnored -DispatchRoot $dispatchRootPath -RelativePath ([string]$_))) { $approved = $true }
                }
            }
            -not $approved
        })
        $result.unappliedNewFiles = @($unapprovedNewFiles)
        $integrationFiles = @($allFiles | Where-Object { $unapprovedNewFiles -notcontains $_ })
        $integrationBaseline = $baselineBinding.Record
        $transientBaselineFiles = New-Object 'System.Collections.Generic.List[object]'
        foreach ($integrationFile in $integrationFiles) {
            if ($baselineFileByPath.ContainsKey([string]$integrationFile)) { continue }
            $approvedDirectory = Find-CollectApprovedTargetDirectory -SourceRoot $baselineSourceRoot -RelativePath ([string]$integrationFile) -ApprovedDirectories $approvedTargetDirectories
            if ($null -eq $approvedDirectory -or (Test-CollectGitPathIgnored -DispatchRoot $dispatchRootPath -RelativePath ([string]$integrationFile))) { continue }
            $transientBaselineFiles.Add([pscustomobject]@{
                    path = [string]$integrationFile
                    kind = 'file'
                    exists = $false
                    byte_length = 0
                    sha256 = $null
                    git_mode = '100644'
                })
        }
        if ($transientBaselineFiles.Count -gt 0) {
            $integrationBaseline = [pscustomobject]@{ files = @($baselineBinding.Record.files) + @($transientBaselineFiles.ToArray()) }
        }
        $result.sourceIntegration = Invoke-DispatchSourceIntegration `
            -SourceRoot $baselineSourceRoot `
            -DispatchRoot $dispatchRootPath `
            -Path @($integrationFiles) `
            -Baseline $integrationBaseline `
            -CallerIdentity $script:CallerSessionIdentity `
            -LineSlug $baselineLineSlug `
            -DispatchSlug $baselineDispatchSlug `
            -RunRecordPath $collectRunRecordPath
    }

    return $result
}
