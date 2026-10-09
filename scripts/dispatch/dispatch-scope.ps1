function Get-DispatchWorkflowPhaseUnits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DesignPath
    )

    if (-not (Test-Path -LiteralPath $DesignPath -PathType Leaf)) {
        throw "找不到 Workflow 設計文件，無法建立 Phase 單位清單：$DesignPath"
    }

    $units = New-Object 'System.Collections.Generic.List[string]'
    $phaseHeadingLines = @{}
    $lastUnit = $null
    $designLines = @(Get-Content -LiteralPath $DesignPath -Encoding UTF8)
    $fencedLineFlags = New-Object 'System.Collections.Generic.List[bool]'
    $backtickCharacter = ([char]96).ToString()
    $fenceOpeningPattern = '^ {0,3}(?<fence>' + [regex]::Escape($backtickCharacter) + '{3,}|~{3,})(?<info>.*)$'
    $fenceCharacter = $null
    $fenceLength = 0

    for ($index = 0; $index -lt $designLines.Count; $index++) {
        $line = [string]$designLines[$index]
        if ($null -ne $fenceCharacter) {
            $fencedLineFlags.Add($true)
            $closingFencePattern = '^ {0,3}' + [regex]::Escape([string]$fenceCharacter) + '{' + [string]$fenceLength + ',}[ \t]*$'
            if ($line -match $closingFencePattern) {
                $fenceCharacter = $null
                $fenceLength = 0
            }
            continue
        }

        if ($line -match $fenceOpeningPattern) {
            $fenceMarker = [string]$matches['fence']
            $fenceInfoString = [string]$matches['info']
            if ($fenceMarker.Substring(0, 1) -ceq $backtickCharacter -and $fenceInfoString.IndexOf($backtickCharacter, [System.StringComparison]::Ordinal) -ge 0) {
                $fencedLineFlags.Add($false)
                continue
            }

            $fencedLineFlags.Add($true)
            $fenceCharacter = $fenceMarker.Substring(0, 1)
            $fenceLength = $fenceMarker.Length
            continue
        }

        $fencedLineFlags.Add($false)
    }

    $taskSectionStart = -1
    $taskSectionEnd = $designLines.Count
    for ($index = 0; $index -lt $designLines.Count; $index++) {
        if ($fencedLineFlags[$index]) { continue }
        if ($designLines[$index] -match '^##\s+.*實作任務清單') {
            $taskSectionStart = $index
            break
        }
    }
    if ($taskSectionStart -ge 0) {
        for ($index = $taskSectionStart + 1; $index -lt $designLines.Count; $index++) {
            if ($fencedLineFlags[$index]) { continue }
            if ($designLines[$index] -match '^##\s+') {
                $taskSectionEnd = $index
                break
            }
        }
    }
    $script:DispatchPhaseUnitSource = if ($taskSectionStart -ge 0) { 'implementation-task-list' } else { 'whole-document-fallback' }
    for ($lineIndex = 0; $lineIndex -lt $designLines.Count; $lineIndex++) {
        if ($fencedLineFlags[$lineIndex]) { continue }
        if ($taskSectionStart -ge 0 -and ($lineIndex -le $taskSectionStart -or $lineIndex -ge $taskSectionEnd)) { continue }
        $line = $designLines[$lineIndex]
        if ($line -match '^#{3,4}\s+Phase\s+(?<phase>\d+)\b') {
            $unit = 'Phase ' + $matches.phase
            if (-not $phaseHeadingLines.ContainsKey($unit)) {
                $phaseHeadingLines[$unit] = New-Object 'System.Collections.Generic.List[int]'
                $units.Add($unit)
            }
            elseif (-not [string]::Equals($lastUnit, $unit, [System.StringComparison]::OrdinalIgnoreCase)) {
                $conflictingLineNumbers = @($phaseHeadingLines[$unit].ToArray()) + ($lineIndex + 1)
                throw ('Workflow 設計文件非連續重複宣告單位：{0}；衝突標題行號：{1}' -f $unit, ($conflictingLineNumbers -join ', '))
            }

            $phaseHeadingLines[$unit].Add($lineIndex + 1)
            $lastUnit = $unit
        }
    }
    if ($units.Count -eq 0) {
        throw "Workflow 設計文件未宣告 Phase 標題：$DesignPath"
    }
    return @($units.ToArray())
}

function Remove-DispatchOrderSingleBacktick {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $normalizedValue = $Value.Trim()
    if ($normalizedValue.Length -ge 2 -and $normalizedValue[0] -eq [char]96 -and $normalizedValue[$normalizedValue.Length - 1] -eq [char]96) {
        return $normalizedValue.Substring(1, $normalizedValue.Length - 2)
    }

    return $normalizedValue
}

function Read-DispatchOrderSections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "找不到資源派遣單：$Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $targetMatch = [regex]::Match($content, '(?ms)^##\s+3\.\s+目標物件\s*\r?\n(?<section>.*?)(?=^##\s+4\.)')
    $taskMatch = [regex]::Match($content, '(?ms)^##\s+4\.\s+任務內容\s*\r?\n(?<section>.*?)(?=^##\s+5\.)')
    if (-not $targetMatch.Success -or -not $taskMatch.Success) {
        throw "派遣單缺少可解析的第 3 或第 4 欄：$Path"
    }

    $targets = New-Object System.Collections.Generic.List[string]
    $targetDetails = New-Object System.Collections.Generic.List[object]
    $targetSection = $targetMatch.Groups['section']
    $targetStartLine = ([regex]::Matches($content.Substring(0, $targetSection.Index), '\r?\n')).Count + 1
    $targetLines = @($targetSection.Value -split '\r?\n')
    $insideTextCodeBlock = $false
    for ($lineIndex = 0; $lineIndex -lt $targetLines.Count; $lineIndex++) {
        $lineNumber = $targetStartLine + $lineIndex
        $trimmedValue = ([string]$targetLines[$lineIndex]).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedValue)) { continue }

        $fenceMatch = [regex]::Match($trimmedValue, '^```(?<language>[A-Za-z0-9_-]*)\s*$')
        if ($fenceMatch.Success) {
            $language = [string]$fenceMatch.Groups['language'].Value
            if ($insideTextCodeBlock) {
                if (-not [string]::IsNullOrWhiteSpace($language)) {
                    throw ('派遣單第 3 欄格式錯誤：剝除後路徑={0}；原始行號={1}；檔案={2}' -f $language, $lineNumber, $Path)
                }
                $insideTextCodeBlock = $false
            }
            else {
                if ($language -notin @('', 'text')) {
                    throw ('派遣單第 3 欄格式錯誤：剝除後路徑={0}；原始行號={1}；檔案={2}' -f $language, $lineNumber, $Path)
                }
                $insideTextCodeBlock = $true
            }
            continue
        }

        if ($insideTextCodeBlock) {
            $targetValue = $trimmedValue
        }
        else {
            $bulletMatch = [regex]::Match($trimmedValue, '^-\s+(?<path>.+)$')
            if (-not $bulletMatch.Success) {
                $cleanedValue = $trimmedValue
                $errorBulletMatch = [regex]::Match($cleanedValue, '^[*+-]\s*(?<path>.*)$')
                if ($errorBulletMatch.Success) { $cleanedValue = [string]$errorBulletMatch.Groups['path'].Value }
                $cleanedValue = Remove-DispatchOrderSingleBacktick -Value $cleanedValue
                if ([string]::IsNullOrWhiteSpace($cleanedValue)) { $cleanedValue = '<空白>' }
                throw ('派遣單第 3 欄格式錯誤：剝除後路徑={0}；原始行號={1}；檔案={2}' -f $cleanedValue, $lineNumber, $Path)
            }
            $targetValue = Remove-DispatchOrderSingleBacktick -Value ([string]$bulletMatch.Groups['path'].Value)
        }

        if ([string]::IsNullOrWhiteSpace($targetValue)) {
            throw ('派遣單第 3 欄格式錯誤：剝除後路徑=<空白>；原始行號={0}；檔案={1}' -f $lineNumber, $Path)
        }
        $targets.Add($targetValue)
        $targetDetails.Add([pscustomobject]@{ Path = $targetValue; LineNumber = $lineNumber })
    }

    if ($insideTextCodeBlock) {
        $lastLineNumber = $targetStartLine + [Math]::Max(0, $targetLines.Count - 1)
        throw ('派遣單第 3 欄格式錯誤：剝除後路徑=<未閉合 text 區塊>；原始行號={0}；檔案={1}' -f $lastLineNumber, $Path)
    }
    if ($targets.Count -eq 0) {
        throw "派遣單第 3 欄沒有目標物件：$Path"
    }

    return [pscustomobject]@{
        Path = Resolve-AbsolutePath -Path $Path
        Targets = @($targets.ToArray())
        TargetDetails = @($targetDetails.ToArray())
        TaskBody = [string]$taskMatch.Groups['section'].Value
    }
}
function Get-DispatchUnitMismatchDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$DeclaredUnits,

        [Parameter(Mandatory)]
        [string[]]$RequestedUnits
    )

    $differences = New-Object 'System.Collections.Generic.List[string]'
    $declaredIndex = 0
    foreach ($requestedUnit in $RequestedUnits) {
        $matchIndex = -1
        for ($index = $declaredIndex; $index -lt $DeclaredUnits.Count; $index++) {
            if ([string]::Equals($DeclaredUnits[$index], $requestedUnit.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                $matchIndex = $index
                break
            }
        }
        if ($matchIndex -lt 0) {
            $differences.Add(('request item not found in source order: ' + $requestedUnit))
        }
        else {
            $declaredIndex = $matchIndex + 1
        }
    }
    if ($differences.Count -eq 0) {
        $differences.Add('requested units are not an ordered source subset')
    }

    return @($differences.ToArray())
}

function New-DispatchAutoPrepareArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [ValidateSet('workflow', 'resource')]
        [string]$DispatchKind,

        [AllowNull()]
        [object]$ResourceOrder
    )

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    $sourceLineRoot = Join-Path -Path $sourceRootPath -ChildPath ('.local\ai-sessions\handoff\' + $LineSlug)
    $destinationLineRoot = Join-Path -Path $dispatchRootPath -ChildPath ('.local\ai-sessions\handoff\' + $LineSlug)
    $sourceManifestPath = Join-Path -Path $sourceLineRoot -ChildPath 'line.json'
    $sourceSummaryPath = Join-Path -Path $sourceLineRoot -ChildPath 'requirement-summary.md'
    if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
        throw "找不到同線 line.json：$sourceManifestPath"
    }
    if (-not (Test-Path -LiteralPath $sourceSummaryPath -PathType Leaf)) {
        throw "找不到同線 requirement-summary.md：$sourceSummaryPath"
    }

    $manifest = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $sourceManifestPath -Raw -Encoding UTF8)
    if ([string](Get-DispatchJsonProperty -Object $manifest -Name 'line-slug') -cne $LineSlug) {
        throw "line.json line-slug 與 Request 不一致：expected=$LineSlug; received=$([string](Get-DispatchJsonProperty -Object $manifest -Name 'line-slug'))"
    }

    $artifactSources = New-Object 'System.Collections.Generic.List[object]'
    $artifactSources.Add([pscustomobject]@{ Source = $sourceManifestPath; Destination = (Join-Path -Path $destinationLineRoot -ChildPath 'line.json'); Purpose = 'same-line LineContext manifest' })
    $artifactSources.Add([pscustomobject]@{ Source = $sourceSummaryPath; Destination = (Join-Path -Path $destinationLineRoot -ChildPath 'requirement-summary.md'); Purpose = 'same-line requirement summary' })

    $sourceDesignPath = Join-Path -Path $sourceLineRoot -ChildPath 'design.md'
    $includeDesign = $DispatchKind -eq 'workflow'
    if ($DispatchKind -eq 'resource' -and $null -ne $ResourceOrder -and ([string]$ResourceOrder.TaskBody -match '(?i)\bdesign\.md\b')) {
        $includeDesign = $true
    }
    if ($includeDesign) {
        if (-not (Test-Path -LiteralPath $sourceDesignPath -PathType Leaf)) {
            throw "派遣所需的 design.md 不存在：$sourceDesignPath"
        }
        $artifactSources.Add([pscustomobject]@{ Source = $sourceDesignPath; Destination = (Join-Path -Path $destinationLineRoot -ChildPath 'design.md'); Purpose = 'same-line design baseline' })
    }

    if ($DispatchKind -eq 'resource' -and $null -ne $ResourceOrder) {
        $sourceOrderPath = Join-Path -Path $sourceRootPath -ChildPath ('.local\ai-sessions\handoff\dispatch-order-' + $DispatchSlug + '.md')
        $destinationOrderPath = Join-Path -Path $destinationLineRoot -ChildPath ('dispatch-order-' + $DispatchSlug + '.md')
        $artifactSources.Add([pscustomobject]@{ Source = $sourceOrderPath; Destination = $destinationOrderPath; Purpose = 'resource dispatch order' })
    }

    $artifacts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($artifactSource in $artifactSources) {
        if (-not (Test-Path -LiteralPath $artifactSource.Source -PathType Leaf)) {
            throw "Prepare 自動帶入來源不存在：$($artifactSource.Source)"
        }
        $resolvedSource = Resolve-AbsolutePath -Path $artifactSource.Source
        $resolvedDestination = Resolve-AbsolutePath -Path $artifactSource.Destination
        if ([string]::Equals($resolvedSource, $resolvedDestination, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $artifacts.Add([ordered]@{
                source = $resolvedSource
                destination = $resolvedDestination
                sha256 = Get-FileSha256 -Path $resolvedSource
                purpose = [string]$artifactSource.Purpose
            })
    }
    return @($artifacts.ToArray())
}

function Initialize-DispatchRequestDerivedInputs {
    [CmdletBinding()]
    param()

    if ($null -eq $script:RequestContext -or [string]$script:RequestContext.document.operation -cne 'Dispatch') {
        return
    }

    $sourceRootPath = Resolve-AbsolutePath -Path $script:SourceRoot
    $dispatchKindValue = [string]$script:DispatchKind
    $unitKindValue = Get-DefaultUnitKind -DispatchKind $dispatchKindValue -UnitKind $script:UnitKind -TaskType $script:TaskType
    if ($unitKindValue -eq 'advisor-evidence-question') {
        return
    }
    $resourceOrder = $null

    if ($dispatchKindValue -eq 'resource') {
        $orderPath = Join-Path -Path $sourceRootPath -ChildPath ('.local\ai-sessions\handoff\dispatch-order-' + $script:DispatchSlug + '.md')
        $resourceOrder = Read-DispatchOrderSections -Path $orderPath
        if (-not (Compare-DispatchStringArrays -Left @($script:TargetPath) -Right @($resourceOrder.Targets))) {
            $differences = New-DispatchRequestArrayMismatchDetail -Field 'target_path' -Expected @($resourceOrder.Targets) -Received @($script:TargetPath)
            $sourceTargetDetails = @($resourceOrder.TargetDetails | ForEach-Object { '{0} (line {1})' -f [string]$_.Path, [int]$_.LineNumber })
            Throw-DispatchRequestFailure -Code 'DispatchRequestedUnitMismatch' -Message ('Dispatch request target_path 與派遣單第 3 欄不一致；source=[' + ($sourceTargetDetails -join ', ') + ']；request=[' + (@($script:TargetPath) -join ', ') + ']；differences=' + (($differences.mismatches | ForEach-Object { 'index ' + $_.index + ': source=' + $_.expected + '; request=' + $_.received }) -join '; ')) -RequestPathValue ([string]$script:RequestContext.path) -Field 'target_path' -Detail ([ordered]@{ source = @($resourceOrder.Targets); request = @($script:TargetPath); differences = @($differences.mismatches); process_started = $false })
        }
    }

    if ($unitKindValue -ne 'advisor-evidence-question') {
        $declaredUnits = if ($dispatchKindValue -eq 'resource') { @($resourceOrder.Targets) } else { @(Get-DispatchDeclaredUnitList -DispatchKind 'workflow' -ExecutionRoot $sourceRootPath -SourceRoot $sourceRootPath -LineSlug $script:LineSlug -DispatchSlug $script:DispatchSlug -TargetPath @($script:TargetPath)) }
        $requestedUnits = @()
        if ($null -ne $script:RequestedUnit -and @($script:RequestedUnit).Count -gt 0) {
            $requestedUnits = @($script:RequestedUnit | ForEach-Object { ([string]$_).Trim() })
            if (-not (Test-DispatchOrderedUnitSubset -DeclaredUnits $declaredUnits -RequestedUnits $requestedUnits -UnitKind $unitKindValue)) {
                $differences = Get-DispatchUnitMismatchDetails -DeclaredUnits $declaredUnits -RequestedUnits $requestedUnits
                Throw-DispatchRequestFailure -Code 'DispatchRequestedUnitMismatch' -Message ('RequestedUnit 與來源宣告單位不一致；source=[' + ($declaredUnits -join ', ') + ']；request=[' + ($requestedUnits -join ', ') + ']；differences=' + ($differences -join '; ')) -RequestPathValue ([string]$script:RequestContext.path) -Field 'requested_unit' -Detail ([ordered]@{ source = @($declaredUnits); request = @($requestedUnits); differences = @($differences); process_started = $false })
            }
        }
        else {
            $requestedUnits = @($declaredUnits)
        }
        $script:RequestedUnit = [string[]]$requestedUnits
        $script:ResolvedRequestedUnit = [string[]]$requestedUnits
    }

    $script:RequestResourceOrder = $resourceOrder
    $script:RequestManualPrepareArtifacts = @($script:RequestPrepareArtifacts)
    $script:RequestAutoPrepareArtifacts = New-Object 'System.Object[]' 0
    $script:RequestPrepareArtifacts = @($script:RequestManualPrepareArtifacts)
}

function Test-DispatchOrderedUnitSubset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$DeclaredUnits,

        [Parameter(Mandatory)]
        [string[]]$RequestedUnits,

        [Parameter(Mandatory)]
        [string]$UnitKind
    )

    if ($RequestedUnits.Count -eq 0) {
        return $false
    }

    $declaredIndex = 0
    foreach ($requestedUnit in $RequestedUnits) {
        if ([string]::IsNullOrWhiteSpace($requestedUnit)) {
            return $false
        }
        $matchIndex = -1
        for ($index = $declaredIndex; $index -lt $DeclaredUnits.Count; $index++) {
            if ([string]::Equals($DeclaredUnits[$index], $requestedUnit.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
                $matchIndex = $index
                break
            }
        }
        if ($matchIndex -lt 0) {
            return $false
        }
        $declaredIndex = $matchIndex + 1
    }

    return $true
}

function Get-DispatchDeclaredUnitList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('workflow', 'resource')]
        [string]$DispatchKind,

        [string]$ExecutionRoot,

        [string]$SourceRoot,

        [string]$LineSlug,

        [string]$DispatchSlug,

        [string[]]$TargetPath
    )

    $sourceRootValue = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { $ExecutionRoot } else { $SourceRoot }
    if ($DispatchKind -eq 'workflow') {
        $designRoot = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { $sourceRootValue } else { $ExecutionRoot }
        $designPath = Join-Path -Path $designRoot -ChildPath ('.local\ai-sessions\handoff\' + $LineSlug + '\design.md')
        return @(Get-DispatchWorkflowPhaseUnits -DesignPath $designPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($DispatchSlug)) {
        $orderPath = Join-Path -Path $sourceRootValue -ChildPath ('.local\ai-sessions\handoff\dispatch-order-' + $DispatchSlug + '.md')
        $order = Read-DispatchOrderSections -Path $orderPath
        return @($order.Targets)
    }

    if ($null -ne $TargetPath -and $TargetPath.Count -gt 0) {
        return @($TargetPath | ForEach-Object { ([string]$_).Trim() })
    }

    throw 'Resource Dispatch 缺少 dispatch_slug，無法由派遣單第 3 欄產生 RequestedUnit。'
}

function Get-DispatchUnitList {
    [CmdletBinding()]
    param(
        [string[]]$RequestedUnit,

        [string]$DispatchKind,

        [string]$UnitKind,

        [string]$ExecutionRoot,

        [string]$SourceRoot,

        [string]$LineSlug,

        [string]$DispatchSlug,

        [string]$EvidencePackPath,

        [string[]]$EvidenceQuestionUnits,

        [string[]]$TargetPath
    )

    $units = New-Object System.Collections.Generic.List[string]
    $isAdvisorEvidence = $UnitKind -eq 'advisor-evidence-question' -or -not [string]::IsNullOrWhiteSpace($EvidencePackPath)
    if ($isAdvisorEvidence) {
        $declaredUnits = @($EvidenceQuestionUnits | ForEach-Object { ([string]$_).Trim() })
        if ($declaredUnits.Count -eq 0) {
            throw 'EvidencePackInvalid：advisor evidence pack 未宣告 question units。'
        }
        if ($null -ne $RequestedUnit -and $RequestedUnit.Count -gt 0) {
            foreach ($unit in $RequestedUnit) {
                if ([string]::IsNullOrWhiteSpace($unit)) {
                    throw 'RequestedUnit 不可包含空白項目。'
                }
                $units.Add($unit.Trim())
            }
            $requestedUnits = @($units.ToArray())
            if (-not (Test-StringArrayEqual -Left $requestedUnits -Right $declaredUnits)) {
                $differences = New-Object System.Collections.Generic.List[string]
                $maxCount = [math]::Max($requestedUnits.Count, $declaredUnits.Count)
                for ($index = 0; $index -lt $maxCount; $index++) {
                    $expectedValue = if ($index -lt $declaredUnits.Count) { $declaredUnits[$index] } else { '<none>' }
                    $requestedValue = if ($index -lt $requestedUnits.Count) { $requestedUnits[$index] } else { '<none>' }
                    if (-not [string]::Equals($expectedValue, $requestedValue, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $differences.Add(('index {0}: expected={1}; requested={2}' -f $index, $expectedValue, $requestedValue))
                    }
                }
                throw ('EvidencePackUnitOrderMismatch：RequestedUnit 必須完全符合 evidence pack 宣告順序；expected=' + ($declaredUnits -join ', ') + '；requested=' + ($requestedUnits -join ', ') + '；differences=' + ($differences.ToArray() -join '; '))
            }
        }
        else {
            foreach ($questionId in $declaredUnits) {
                $units.Add($questionId)
            }
        }
    }
    else {
        $isRequestDrivenDispatch = $null -ne $script:RequestContext -and [string]$script:RequestContext.document.operation -ceq 'Dispatch'
        if ($isRequestDrivenDispatch) {
            $requestedUnits = @($script:ResolvedRequestedUnit | ForEach-Object { ([string]$_).Trim() })
            if ($requestedUnits.Count -eq 0) {
                throw 'Dispatch request 尚未完成來源單位解析。'
            }
            foreach ($unit in $requestedUnits) { $units.Add($unit) }
        }
        elseif ($null -ne $RequestedUnit -and $RequestedUnit.Count -gt 0) {
            foreach ($unit in $RequestedUnit) {
                if ([string]::IsNullOrWhiteSpace($unit)) {
                    throw 'RequestedUnit 不可包含空白項目。'
                }
                $units.Add($unit.Trim())
            }
        }
        elseif ($DispatchKind -eq 'workflow') {
            $designPath = Join-Path -Path $ExecutionRoot -ChildPath ('.local\ai-sessions\handoff\' + $LineSlug + '\design.md')
            foreach ($unit in @(Get-DispatchWorkflowPhaseUnits -DesignPath $designPath)) { $units.Add([string]$unit) }
        }
        elseif ($DispatchKind -eq 'resource' -and $null -ne $TargetPath -and $TargetPath.Count -gt 0) {
            foreach ($target in $TargetPath) {
                if ([string]::IsNullOrWhiteSpace($target)) {
                    throw 'TargetPath 不可包含空白項目。'
                }
                $units.Add($target.Trim())
            }
        }
        else {
            $units.Add('dispatch-unit')
        }
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($unit in $units) {
        if (-not $seen.Add($unit)) {
            throw "派工單位不可重複：$unit"
        }
    }
    return @($units.ToArray())
}

function Get-DefaultUnitKind {
    param(
        [string]$DispatchKind,

        [string]$UnitKind,

        [string]$TaskType
    )

    if (-not [string]::IsNullOrWhiteSpace($UnitKind)) {
        return $UnitKind
    }
    if ($TaskType -eq 'advisor-consult') {
        return 'advisor-evidence-question'
    }
    if ($DispatchKind -eq 'workflow') {
        return 'workflow-phase'
    }
    return 'resource-target'
}

function New-ScopePlan {
    param(
        [Parameter(Mandatory)][string]$DispatchSlug,
        [Parameter(Mandatory)][string]$DispatchKind,
        [Parameter(Mandatory)][string]$TaskType,
        [Parameter(Mandatory)][string]$RequestedProfile,
        [Parameter(Mandatory)][string]$SessionMode,
        [Parameter(Mandatory)][AllowNull()][psobject]$BeforeSnapshot,
        [string]$CalibrationPath,
        [string[]]$Units,
        [Parameter(Mandatory)][string]$UnitKind,
        [Nullable[double]]$RequestedBudgetPercent,
        [Nullable[double]]$RequestedReservePercent,
        [string]$Model,
        [AllowNull()][object]$ModelEvidence,
        [AllowNull()][object]$ReasoningEffortEvidence,
        [AllowNull()][object]$ActivationDecision
    )
    if ($null -eq $Units -or $Units.Count -eq 0) { throw 'ScopePlan 不可使用空的單位清單。' }

    $primaryWindow = if ($null -eq $BeforeSnapshot) { $null } else { Get-DispatchJsonProperty -Object $BeforeSnapshot -Name 'primary' }
    $primaryObservation = if ($null -eq $BeforeSnapshot) { $null } else { Get-QuotaSnapshotObservation -Snapshot $BeforeSnapshot -WindowName 'primary' }
    $remainingValue = Get-DispatchJsonProperty -Object $primaryObservation -Name 'remaining_percent'
    if ($null -eq $remainingValue) { $remainingValue = Get-DispatchJsonProperty -Object $primaryWindow -Name 'remaining_percent' }
    $remaining = $null
    if ($null -ne $remainingValue) { try { $remaining = [double]$remainingValue } catch { $remaining = $null } }

    $quotaFreshness = if ($null -eq $BeforeSnapshot) { 'unknown' } else { Get-QuotaSnapshotFreshness -Snapshot $BeforeSnapshot }
    $hasObservations = $null -ne $BeforeSnapshot -and (Test-QuotaSnapshotHasObservations -Snapshot $BeforeSnapshot)
    $quotaState = if ($null -eq $BeforeSnapshot) { 'SnapshotUnavailable' } else { [string](Get-DispatchJsonProperty -Object $BeforeSnapshot -Name 'state') }
    if ([string]::IsNullOrWhiteSpace($quotaState)) { $quotaState = if ($hasObservations) { 'Valid' } else { 'SnapshotUnavailable' } }
    $serviceRejection = if ($null -eq $BeforeSnapshot) { $null } else { Get-QuotaSnapshotServiceRejection -Snapshot $BeforeSnapshot }
    $activationMode = if ($null -eq $ActivationDecision) { 'none' } else { [string](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'activationMode') }
    $authorizationSource = if ($null -eq $ActivationDecision) { $null } else { Get-OptionalObjectProperty -Object $ActivationDecision -Name 'authorizationSource' }
    $activationGranted = $null -ne $ActivationDecision -and [bool](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'granted')
    $activationNotice = if ($null -eq $ActivationDecision) { '' } else { [string](Get-OptionalObjectProperty -Object $ActivationDecision -Name 'notice') }

    return [ordered]@{
        dispatch_slug = $DispatchSlug
        dispatch_kind = $DispatchKind
        task_type = $TaskType
        requested_profile = $RequestedProfile
        session_mode = $SessionMode
        primary_remaining_percent = $remaining
        primary_reserve_percent = 0.0
        primary_budget_percent = $null
        estimate_percent = $null
        estimate_source = 'not-used'
        unit_kind = $UnitKind
        requested_units = @($Units)
        selected_units = @($Units)
        deferred_units = @()
        decision = 'full'
        decision_reason = 'ScopePlan selects every unit explicitly declared by the Request.'
        calibration_sample_count = 0
        resolved_model = Get-DispatchEvidenceValue -Evidence $ModelEvidence
        resolved_reasoning_effort = Get-DispatchEvidenceValue -Evidence $ReasoningEffortEvidence
        quota_state = $quotaState
        quota_freshness = $quotaFreshness
        quota_observation_available = $hasObservations
        service_rejection = $serviceRejection
        retry_allowed = $null
        stop_after_selected_units = $false
        authorization_source = $authorizationSource
        activation_mode = $activationMode
        activation_granted = $activationGranted
        activation_notice = $activationNotice
        advisor_hard_limit_percent = $null
        advisor_unit_estimate_percent = $null
        reserve_bypassed = $false
        minimum_unit_over_budget = $false
    }
}

function Read-ScopePlanFile {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $fullPath))) {
        throw "找不到 ScopePlan：$fullPath"
    }
    try {
        $plan = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $fullPath)
    }
    catch {
        throw "ScopePlan 格式錯誤：$fullPath；$($_.Exception.Message)"
    }
    foreach ($requiredName in @('dispatch_slug', 'dispatch_kind', 'task_type', 'requested_profile', 'session_mode', 'primary_remaining_percent', 'primary_reserve_percent', 'primary_budget_percent', 'estimate_percent', 'estimate_source', 'unit_kind', 'requested_units', 'selected_units', 'deferred_units', 'decision', 'decision_reason')) {
        if ($null -eq $plan.PSObject.Properties[$requiredName]) {
            throw "ScopePlan 缺少欄位：$fullPath；$requiredName"
        }
    }
    if (-not (Test-ScopePlanCompleteness -ScopePlan $plan)) {
        throw "ScopePlan 欄位不完整或單位清單不一致：$fullPath"
    }
    return $plan
}

function Test-StringArrayEqual {
    param(
        [AllowNull()]
        [object]$Left,

        [AllowNull()]
        [object]$Right
    )

    $leftItems = @($Left | ForEach-Object { [string]$_ })
    $rightItems = @($Right | ForEach-Object { [string]$_ })
    if ($leftItems.Count -ne $rightItems.Count) {
        return $false
    }
    for ($index = 0; $index -lt $leftItems.Count; $index++) {
        if (-not [string]::Equals($leftItems[$index], $rightItems[$index], [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    return $true
}

function Get-ScopePlanFingerprint {
    param(
        [Parameter(Mandatory)]
        [psobject]$ScopePlan
    )

    $normalizedScopePlan = $ScopePlan | ConvertTo-Json -Depth 20 | ConvertFrom-Json
    $fingerprintInput = [ordered]@{}
    foreach ($property in @($normalizedScopePlan.PSObject.Properties | Sort-Object -Property Name)) {
        if ($property.Name -ne 'scope_plan_fingerprint') {
            if ($property.Name -in @('requested_units', 'selected_units', 'deferred_units')) {
                $fingerprintInput[$property.Name] = @($property.Value | ForEach-Object { [string]$_ })
            }
            else {
                $value = $property.Value
                if ($null -ne $value -and $value -is [ValueType] -and $value -isnot [bool]) {
                    try {
                        $value = ([double]$value).ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
                    }
                    catch {
                        $value = $property.Value
                    }
                }
                $fingerprintInput[$property.Name] = $value
            }
        }
    }
    $json = ConvertTo-Json -InputObject $fingerprintInput -Depth 20 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Read-DispatchSharedBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $buffer = New-Object IO.MemoryStream
    try {
        $stream.CopyTo($buffer)
        return ,$buffer.ToArray()
    }
    finally {
        $buffer.Dispose()
        $stream.Dispose()
    }
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $fileApiPath = ConvertTo-FileSystemApiPath -Path $resolvedPath
    if (-not [System.IO.File]::Exists($fileApiPath)) {
        throw "找不到要計算 SHA-256 的檔案：$resolvedPath"
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = Read-DispatchSharedBytes -Path $fileApiPath
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-JsonSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 30 -Compress
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Compare-DispatchStringArrays {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$Left,

        [AllowEmptyCollection()]
        [string[]]$Right,

        [switch]$OrdinalIgnoreCase
    )

    $leftValues = @($Left)
    $rightValues = @($Right)
    if ($leftValues.Count -ne $rightValues.Count) {
        return $false
    }
    $comparison = if ($OrdinalIgnoreCase) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    for ($index = 0; $index -lt $leftValues.Count; $index++) {
        if (-not [string]::Equals([string]$leftValues[$index], [string]$rightValues[$index], $comparison)) {
            return $false
        }
    }
    return $true
}

function Get-DispatchRequestInputLength {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 0
    }

    if ($Value -is [System.Array]) {
        $length = 0
        foreach ($item in $Value) {
            if ($null -ne $item) {
                $length += ([string]$item).Length
            }
        }
        return $length
    }

    return ([string]$Value).Length
}

function Get-DispatchRequestExpectedFormat {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Field,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Detail
    )

    switch ($Field) {
        'schema' { return 'ai-sessions.dispatch-request.v1' }
        'operation' { return 'Preflight|Prepare|Start|Inspect|Collect|QuotaProbe|Dispatch|Cleanup' }
        'line_slug' { return '小寫 slug（^[a-z0-9]+(?:-[a-z0-9]+)*$）' }
        'dispatch_slug' { return '小寫 slug（^[a-z0-9]+(?:-[a-z0-9]+)*$）' }
        'selected_requirement' { return '#<positive integer>[,#<positive integer>...]' }
        'failure_receipt_path' { return 'fully-qualified path' }
        'evidence_pack_path' { return 'fully-qualified path' }
        'advisor_consult_report_path' { return 'fully-qualified path' }
        'target_path' { return 'fully-qualified path' }
        'profile' { return 'default|advisor' }
        'advisor_request_source' { return 'user-explicit' }
        'write_mode' { return 'readonly|write' }
        'dispatch_kind' { return 'workflow|resource' }
        'session_mode' { return 'cold-start|continuation' }
        'unit_kind' { return 'workflow-phase|resource-target|advisor-evidence-question' }
    }

    if ($Detail.Contains('valid_values')) {
        return (@($Detail['valid_values']) -join '|')
    }
    if ($Detail.Contains('expected_type')) {
        return [string]$Detail['expected_type']
    }
    if ($Detail.Contains('expected')) {
        return [string]$Detail['expected']
    }

    return '符合 Request 欄位格式'
}

function Get-DispatchRequestSafeDetail {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Field,

        [AllowNull()]
        [object]$Detail
    )

    if ($null -eq $Detail -or $Detail -isnot [System.Collections.IDictionary]) {
        return $Detail
    }

    $containsInputValues = $Detail.Contains('received') -or $Detail.Contains('mismatches')
    if (-not $containsInputValues) {
        return $Detail
    }

    $inputLength = 0
    if ($Detail.Contains('received')) {
        $inputLength = [math]::Max($inputLength, (Get-DispatchRequestInputLength -Value $Detail['received']))
    }
    if ($Detail.Contains('mismatches')) {
        foreach ($mismatch in @($Detail['mismatches'])) {
            if ($null -eq $mismatch -or $mismatch -isnot [System.Collections.IDictionary]) {
                continue
            }
            foreach ($name in @('expected', 'received')) {
                if ($mismatch.Contains($name)) {
                    $inputLength = [math]::Max($inputLength, (Get-DispatchRequestInputLength -Value $mismatch[$name]))
                }
            }
        }
    }

    return [ordered]@{
        expected_format = Get-DispatchRequestExpectedFormat -Field $Field -Detail $Detail
        input_length = $inputLength
    }
}

function Throw-DispatchRequestFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [string]$RequestPathValue,

        [string]$Field,

        [AllowNull()]
        [object]$Detail
    )

    $detailValue = if ($null -eq $Detail) { [ordered]@{} } else { Get-DispatchRequestSafeDetail -Field $Field -Detail $Detail }
    $classification = switch ($Code) {
        'DispatchRequestMissingField' { 'MissingField' }
        'DispatchRequestFieldType' { 'FieldType' }
        'DispatchRequestNullArrayElement' { 'FieldType' }
        'DispatchRequestInvalidValue' { 'InvalidValue' }
        'DispatchRequestInvalidPath' { 'InvalidPath' }
        default { $null }
    }
    $result = [ordered]@{
        operation      = 'DispatchRequest'
        schema         = 'ai-sessions.dispatch-request.v1'
        code           = $Code
        error_code     = $Code
        reason_code    = $Code
        classification = $classification
        message        = $Message
        request_path   = if ([string]::IsNullOrWhiteSpace($RequestPathValue)) { $null } else { $RequestPathValue }
        field          = if ([string]::IsNullOrWhiteSpace($Field)) { $null } else { $Field }
        process_started = $false
        output_valid   = $false
        detail         = $detailValue
    }
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['operationResult'] = $result
    throw $exception
}

function Test-DispatchFullyQualifiedPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    return [System.Text.RegularExpressions.Regex]::IsMatch(
        $Path,
        '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Test-DispatchRequestFieldPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne $Document.PSObject.Properties[$Name]
}

function Assert-DispatchRequestRequiredField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    $property = $Document.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("request file 缺少必要欄位：{0}" -f $Name) -RequestPathValue $RequestPathValue -Field $Name
    }
}

function Get-DispatchRequestTypeName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 'null'
    }
    return $Value.GetType().FullName
}

function Get-DispatchRequestStringArray {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    if ($Value -isnot [array]) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 必須是 string array。" -f $Field) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ expected_type = 'string[]'; actual_type = Get-DispatchRequestTypeName -Value $Value })
    }

    $values = New-Object 'System.Collections.Generic.List[string]'
    $index = 0
    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestNullArrayElement' -Message ("request 欄位 {0} 的第 {1} 項不可為 null。" -f $Field, $index) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ index = $index })
        }
        if ($item -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 的第 {1} 項必須是 string。" -f $Field, $index) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ index = $index; expected_type = 'string'; actual_type = $item.GetType().FullName })
        }
        $stringValue = [string]$item
        if ($Field -ne 'literal_values' -and [string]::IsNullOrWhiteSpace($stringValue)) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 {0} 的第 {1} 項不可為空白。" -f $Field, $index) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ index = $index })
        }
        $values.Add($stringValue)
        $index++
    }

    return @($values.ToArray())
}

function Get-DispatchRequestArtifacts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    if ($Value -isnot [array]) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 prepare_artifacts 必須是 object array。' -RequestPathValue $RequestPathValue -Field 'prepare_artifacts' -Detail ([ordered]@{ expected_type = 'object[]'; actual_type = Get-DispatchRequestTypeName -Value $Value })
    }

    $artifacts = New-Object 'System.Collections.Generic.List[object]'
    $allowedArtifactFields = @('source', 'destination', 'sha256', 'purpose')
    $requiredArtifactFields = @('source', 'destination', 'sha256', 'purpose')
    $index = 0
    foreach ($item in @($Value)) {
        if ($null -eq $item -or $item -isnot [psobject]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 prepare_artifacts 的第 {0} 項必須是 object。" -f $index) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + ']') -Detail ([ordered]@{ index = $index; expected_type = 'object' })
        }
        foreach ($property in $item.PSObject.Properties) {
            if ($allowedArtifactFields -notcontains $property.Name) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestUnknownField' -Message ("request 欄位 prepare_artifacts[{0}] 含未知欄位 {1}。" -f $index, $property.Name) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].' + $property.Name) -Detail ([ordered]@{ index = $index; name = $property.Name })
            }
        }
        foreach ($requiredField in $requiredArtifactFields) {
            $property = $item.PSObject.Properties[$requiredField]
            if ($null -eq $property) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("request 欄位 prepare_artifacts[{0}] 缺少 {1}。" -f $index, $requiredField) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].' + $requiredField) -Detail ([ordered]@{ index = $index; name = $requiredField })
            }
            if ($property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 prepare_artifacts[{0}].{1} 必須是非空字串。" -f $index, $requiredField) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].' + $requiredField) -Detail ([ordered]@{ index = $index; name = $requiredField })
            }
        }
        if ([string]$item.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 prepare_artifacts[{0}].sha256 必須是 64 碼 SHA-256。" -f $index) -RequestPathValue $RequestPathValue -Field ('prepare_artifacts[' + $index + '].sha256') -Detail ([ordered]@{ index = $index })
        }
        $artifacts.Add($item)
        $index++
    }

    return @($artifacts.ToArray())
}

function Get-DispatchRequestOptionalString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    $property = $Document.PSObject.Properties[$Field]
    if ($null -eq $property) {
        return $null
    }
    if ($null -eq $property.Value -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 必須是非空字串。" -f $Field) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ expected_type = 'non-empty string' })
    }
    return [string]$property.Value
}

function Get-DispatchRequestEnumValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$Document,

        [Parameter(Mandatory)]
        [string]$Field,

        [Parameter(Mandatory)]
        [string[]]$AllowedValues,

        [Parameter(Mandatory)]
        [string]$RequestPathValue
    )

    $value = Get-DispatchRequestOptionalString -Document $Document -Field $Field -RequestPathValue $RequestPathValue
    if ($null -ne $value -and $AllowedValues -notcontains $value) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 {0} 格式無效。" -f $Field) -RequestPathValue $RequestPathValue -Field $Field -Detail ([ordered]@{ valid_values = @($AllowedValues); received = $value })
    }
    if ($null -ne $value) {
        foreach ($allowedValue in $AllowedValues) {
            if ([string]::Equals([string]$allowedValue, $value, [System.StringComparison]::OrdinalIgnoreCase)) {
                return [string]$allowedValue
            }
        }
    }
    return $value
}

function Read-DispatchRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message 'RequestPath 不可為空。' -Field 'RequestPath'
    }

    try {
        $requestPathValue = Resolve-AbsolutePath -Path $Path
    }
    catch {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ('RequestPath 無法解析：' + $_.Exception.Message) -RequestPathValue $Path -Field 'RequestPath'
    }
    if (-not (Test-Path -LiteralPath $requestPathValue -PathType Leaf)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMissingFile' -Message ('找不到 request file：' + $requestPathValue) -RequestPathValue $requestPathValue -Field 'RequestPath'
    }

    $bytesBefore = [System.IO.File]::ReadAllBytes($requestPathValue)
    if ($bytesBefore.Length -ge 3 -and $bytesBefore[0] -eq 239 -and $bytesBefore[1] -eq 187 -and $bytesBefore[2] -eq 191) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestEncoding' -Message ('request file 必須是 UTF-8 無 BOM：' + $requestPathValue) -RequestPathValue $requestPathValue -Field 'encoding'
    }
    $hashBefore = Get-DispatchByteArraySha256 -Bytes $bytesBefore
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    try {
        $content = [System.IO.File]::ReadAllText($requestPathValue, $encoding)
    }
    catch {
        Throw-DispatchRequestFailure -Code 'DispatchRequestEncoding' -Message ('request file 不是有效 UTF-8：' + $requestPathValue + '；' + $_.Exception.Message) -RequestPathValue $requestPathValue -Field 'encoding'
    }
    try {
        $document = ConvertFrom-DispatchJson -Content $content
    }
    catch {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidJson' -Message ('request file JSON 無法解析：' + $_.Exception.Message) -RequestPathValue $requestPathValue
    }
    $bytesAfter = [System.IO.File]::ReadAllBytes($requestPathValue)
    $hashAfter = Get-DispatchByteArraySha256 -Bytes $bytesAfter
    if (-not [string]::Equals($hashBefore, $hashAfter, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestChanged' -Message ('request file 在解析期間變更：' + $requestPathValue) -RequestPathValue $requestPathValue -Detail ([ordered]@{ before_sha256 = $hashBefore; after_sha256 = $hashAfter })
    }
    if ($null -eq $document -or $document -isnot [pscustomobject]) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidJson' -Message 'request file 根節點必須是 JSON object。' -RequestPathValue $requestPathValue
    }

    $dispatchOnlyFields = @('write_mode', 'dispatch_kind', 'prompt_path', 'task_type', 'session_mode', 'unit_kind', 'requested_unit', 'continue_from_scope_plan', 'background', 'required_identifier', 'failure_receipt_path', 'prepare_result_path', 'quota_before_path', 'quota_after_path', 'evidence_pack_path', 'advisor_consult_report_path', 'selected_requirement')
    $commonRootFields = @('source_root', 'dispatch_root', 'caller_session_id')
    $cleanupOnlyFields = @('run_record_path', 'reviewer_report_path', 'report_path', 'evidence_path')
    $allowedFields = @('schema', 'operation', 'line_slug', 'dispatch_slug', 'profile', 'advisor_request_source', 'target_path', 'add_directory', 'search', 'codex_parent_option', 'literal_values', 'prepare_artifacts', 'result_path', 'preflight_result_path') + $commonRootFields + $dispatchOnlyFields + $cleanupOnlyFields
    foreach ($property in $document.PSObject.Properties) {
        if ($allowedFields -notcontains $property.Name) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestUnknownField' -Message ("request file 含未知欄位：{0}" -f $property.Name) -RequestPathValue $requestPathValue -Field $property.Name -Detail ([ordered]@{ name = $property.Name })
        }
    }

    foreach ($requiredField in @('schema', 'operation', 'line_slug', 'dispatch_slug')) {
        Assert-DispatchRequestRequiredField -Document $document -Name $requiredField -RequestPathValue $requestPathValue
    }

    if ($document.schema -isnot [string] -or [string]$document.schema -cne 'ai-sessions.dispatch-request.v1') {
        Throw-DispatchRequestFailure -Code 'DispatchRequestSchemaMismatch' -Message 'request file schema 不符。' -RequestPathValue $requestPathValue -Field 'schema' -Detail ([ordered]@{ expected = 'ai-sessions.dispatch-request.v1'; received = [string]$document.schema })
    }
    $validOperations = @('Preflight', 'Prepare', 'Start', 'Inspect', 'Collect', 'QuotaProbe', 'Dispatch', 'Cleanup')
    $canonicalOperation = $null
    if ($document.operation -is [string]) {
        foreach ($validOperation in $validOperations) {
            if ([string]::Equals([string]$validOperation, [string]$document.operation, [System.StringComparison]::OrdinalIgnoreCase)) {
                $canonicalOperation = [string]$validOperation
                break
            }
        }
    }
    if ($null -eq $canonicalOperation) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message 'request operation 格式無效。' -RequestPathValue $requestPathValue -Field 'operation' -Detail ([ordered]@{ valid_values = $validOperations; received = [string]$document.operation })
    }
    $document.operation = $canonicalOperation
    if ([string]$document.operation -notin @('Dispatch', 'Cleanup')) {
        foreach ($field in @($commonRootFields) + @('result_path', 'preflight_result_path') + $dispatchOnlyFields + $cleanupOnlyFields) {
            if (Test-DispatchRequestFieldPresent -Document $document -Name $field) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestFieldNotAllowed' -Message ("request 欄位 {0} 僅可用於 operation=Dispatch 或 Cleanup。" -f $field) -RequestPathValue $requestPathValue -Field $field -Detail ([ordered]@{ operation = [string]$document.operation })
            }
        }
    }
    elseif ([string]$document.operation -eq 'Dispatch') {
        foreach ($field in $cleanupOnlyFields) {
            if (Test-DispatchRequestFieldPresent -Document $document -Name $field) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestFieldNotAllowed' -Message ("request 欄位 {0} 僅可用於 operation=Cleanup。" -f $field) -RequestPathValue $requestPathValue -Field $field -Detail ([ordered]@{ operation = [string]$document.operation })
            }
        }
        foreach ($requiredDispatchField in @('source_root', 'dispatch_root', 'write_mode', 'dispatch_kind', 'target_path', 'prompt_path', 'task_type', 'session_mode', 'unit_kind', 'failure_receipt_path')) {
            $requiredDispatchProperty = $document.PSObject.Properties[$requiredDispatchField]
            if ($null -eq $requiredDispatchProperty -or $null -eq $requiredDispatchProperty.Value) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("Dispatch request file 缺少必要欄位：{0}" -f $requiredDispatchField) -RequestPathValue $requestPathValue -Field $requiredDispatchField
            }
        }
    }
    else {
        foreach ($field in $dispatchOnlyFields) {
            if (Test-DispatchRequestFieldPresent -Document $document -Name $field) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestFieldNotAllowed' -Message ("Cleanup request 不允許欄位：{0}" -f $field) -RequestPathValue $requestPathValue -Field $field -Detail ([ordered]@{ operation = 'Cleanup' })
            }
        }
    }
    foreach ($identityField in @('line_slug', 'dispatch_slug')) {
        $identityValue = $document.$identityField
        if ($identityValue -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message ("request 欄位 {0} 必須是字串。" -f $identityField) -RequestPathValue $requestPathValue -Field $identityField -Detail ([ordered]@{ expected_type = 'string'; actual_type = Get-DispatchRequestTypeName -Value $identityValue })
        }
        if ([string]::IsNullOrWhiteSpace([string]$identityValue) -or [regex]::IsMatch([string]$identityValue, '^[a-z0-9]+(?:-[a-z0-9]+)*$') -eq $false) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ("request 欄位 {0} 必須是小寫 slug。" -f $identityField) -RequestPathValue $requestPathValue -Field $identityField -Detail ([ordered]@{ received = [string]$identityValue })
        }
    }

    $fieldPresence = [ordered]@{}
    $callerSessionIdPresent = Test-DispatchRequestFieldPresent -Document $document -Name 'caller_session_id'
    $callerSessionIdValue = $null
    if ($callerSessionIdPresent) {
        $callerSessionIdProperty = $document.PSObject.Properties['caller_session_id']
        if ($null -eq $callerSessionIdProperty -or $callerSessionIdProperty.Value -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 caller_session_id 必須是 string。' -RequestPathValue $requestPathValue -Field 'caller_session_id' -Detail ([ordered]@{ expected_type = 'string'; actual_type = Get-DispatchRequestTypeName -Value $(if ($null -eq $callerSessionIdProperty) { $null } else { $callerSessionIdProperty.Value }) })
        }
        $callerSessionIdValue = [string]$callerSessionIdProperty.Value
        if ([string]::IsNullOrWhiteSpace($callerSessionIdValue) -or $callerSessionIdValue.Length -gt 4096) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message 'request 欄位 caller_session_id 不可為空白且長度不得超過上限。' -RequestPathValue $requestPathValue -Field 'caller_session_id' -Detail ([ordered]@{ input_length = $callerSessionIdValue.Length })
        }
        $null = $document.PSObject.Properties.Remove('caller_session_id')
    }
    $fieldPresence.caller_session_id = $callerSessionIdPresent
    $arrayValues = [ordered]@{}
    foreach ($arrayField in @('target_path', 'add_directory', 'codex_parent_option', 'literal_values')) {
        $present = Test-DispatchRequestFieldPresent -Document $document -Name $arrayField
        $fieldPresence[$arrayField] = $present
        if ($present) {
            $arrayProperty = $document.PSObject.Properties[$arrayField]
            $arrayValues[$arrayField] = @(Get-DispatchRequestStringArray -Field $arrayField -Value $arrayProperty.Value -RequestPathValue $requestPathValue)
            if ($arrayField -ceq 'target_path') {
                if ($arrayValues[$arrayField].Count -eq 0) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message 'request 欄位 target_path 至少需要一項。' -RequestPathValue $requestPathValue -Field 'target_path' -Detail ([ordered]@{ count = 0 })
                }
                for ($targetIndex = 0; $targetIndex -lt $arrayValues[$arrayField].Count; $targetIndex++) {
                    $targetPathValue = [string]$arrayValues[$arrayField][$targetIndex]
                    if (-not (Test-DispatchFullyQualifiedPath -Path $targetPathValue)) {
                        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ("request 欄位 target_path 的第 {0} 項必須是完整絕對路徑。" -f $targetIndex) -RequestPathValue $requestPathValue -Field 'target_path' -Detail ([ordered]@{ index = $targetIndex; expected = 'fully-qualified path'; received = $targetPathValue })
                    }
                }
            }
        }
        else {
            $arrayValues[$arrayField] = $null
        }
    }
    $searchPresent = Test-DispatchRequestFieldPresent -Document $document -Name 'search'
    $fieldPresence.search = $searchPresent
    if ($searchPresent -and $document.search -isnot [bool]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 search 必須是 boolean。' -RequestPathValue $requestPathValue -Field 'search' -Detail ([ordered]@{ expected_type = 'boolean'; actual_type = Get-DispatchRequestTypeName -Value $document.search })
    }
    $profilePresent = Test-DispatchRequestFieldPresent -Document $document -Name 'profile'
    $fieldPresence.profile = $profilePresent
    $profileValue = $null
    if ($profilePresent) {
        if ($document.profile -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 profile 必須是 string。' -RequestPathValue $requestPathValue -Field 'profile' -Detail ([ordered]@{ expected_type = 'string'; actual_type = Get-DispatchRequestTypeName -Value $document.profile })
        }
        $profileValue = [string]$document.profile
        if (@('default', 'advisor') -notcontains $profileValue) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message 'request 欄位 profile 格式無效。' -RequestPathValue $requestPathValue -Field 'profile' -Detail ([ordered]@{ valid_values = @('default', 'advisor'); received = $profileValue })
        }
        foreach ($validProfile in @('default', 'advisor')) {
            if ([string]::Equals($validProfile, $profileValue, [System.StringComparison]::OrdinalIgnoreCase)) {
                $profileValue = $validProfile
                break
            }
        }
    }
    $advisorRequestSourcePresent = Test-DispatchRequestFieldPresent -Document $document -Name 'advisor_request_source'
    $fieldPresence.advisor_request_source = $advisorRequestSourcePresent
    $advisorRequestSourceValue = $null
    if ($advisorRequestSourcePresent) {
        if ($document.advisor_request_source -isnot [string]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 advisor_request_source 必須是 string。' -RequestPathValue $requestPathValue -Field 'advisor_request_source' -Detail ([ordered]@{ expected_type = 'string'; actual_type = Get-DispatchRequestTypeName -Value $document.advisor_request_source })
        }
        $advisorRequestSourceValue = [string]$document.advisor_request_source
        if (@('user-explicit') -notcontains $advisorRequestSourceValue) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message 'request 欄位 advisor_request_source 格式無效。' -RequestPathValue $requestPathValue -Field 'advisor_request_source' -Detail ([ordered]@{ valid_values = @('user-explicit'); received = $advisorRequestSourceValue })
        }
        $advisorRequestSourceValue = 'user-explicit'
    }
    $fieldPresence.prepare_artifacts = Test-DispatchRequestFieldPresent -Document $document -Name 'prepare_artifacts'
    $prepareArtifacts = @()
    if ($fieldPresence.prepare_artifacts) {
        $prepareArtifactsProperty = $document.PSObject.Properties['prepare_artifacts']
        $prepareArtifacts = @(Get-DispatchRequestArtifacts -Value $prepareArtifactsProperty.Value -RequestPathValue $requestPathValue)
    }

    $dispatchFieldPresence = [ordered]@{}
    $dispatchValues = [ordered]@{}
    $cleanupFieldPresence = [ordered]@{}
    $cleanupValues = [ordered]@{}
    if ([string]$document.operation -ceq 'Dispatch') {
        foreach ($field in @('source_root', 'dispatch_root', 'prompt_path', 'task_type', 'required_identifier', 'failure_receipt_path', 'result_path', 'preflight_result_path', 'prepare_result_path', 'quota_before_path', 'quota_after_path', 'evidence_pack_path', 'advisor_consult_report_path')) {
            $dispatchFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            $dispatchValues[$field] = Get-DispatchRequestOptionalString -Document $document -Field $field -RequestPathValue $requestPathValue
        }
        $dispatchFieldPresence.selected_requirement = Test-DispatchRequestFieldPresent -Document $document -Name 'selected_requirement'
        $selectedValue = if ($dispatchFieldPresence.selected_requirement) { $document.selected_requirement } else { $null }
        if ($selectedValue -is [array]) {
            $dispatchValues.selected_requirement = (@($selectedValue) -join ',')
        }
        elseif ($selectedValue -is [string]) {
            $dispatchValues.selected_requirement = [string]$selectedValue
        }
        else {
            $dispatchValues.selected_requirement = $null
        }
        if ($dispatchFieldPresence.selected_requirement -and ($selectedValue -isnot [string] -and $selectedValue -isnot [array] -or [string]$dispatchValues.selected_requirement -notmatch '^#[1-9][0-9]*(?:,#[1-9][0-9]*)*$')) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message 'request 欄位 selected_requirement 必須是編號字串或編號陣列。' -RequestPathValue $requestPathValue -Field 'selected_requirement' -Detail ([ordered]@{ expected_format = '#<positive integer>[,#<positive integer>...]'; input_length = ([string]$dispatchValues.selected_requirement).Length })
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$dispatchValues.failure_receipt_path) -and -not (Test-DispatchFullyQualifiedPath -Path ([string]$dispatchValues.failure_receipt_path))) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message 'request 欄位 failure_receipt_path 必須是完整絕對路徑。' -RequestPathValue $requestPathValue -Field 'failure_receipt_path' -Detail ([ordered]@{ expected = 'fully-qualified path'; received = [string]$dispatchValues.failure_receipt_path })
        }
        if ([string]$dispatchValues.task_type -ceq 'advisor-consult') {
            foreach ($advisorField in @('evidence_pack_path', 'advisor_consult_report_path')) {
                if (-not [bool]$dispatchFieldPresence[$advisorField] -or [string]::IsNullOrWhiteSpace([string]$dispatchValues[$advisorField])) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message ("advisor-consult Request 缺少必要欄位：{0}" -f $advisorField) -RequestPathValue $requestPathValue -Field $advisorField
                }
                if (-not (Test-DispatchFullyQualifiedPath -Path ([string]$dispatchValues[$advisorField]))) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidPath' -Message ("request 欄位 {0} 必須是完整絕對路徑。" -f $advisorField) -RequestPathValue $requestPathValue -Field $advisorField -Detail ([ordered]@{ expected = 'fully-qualified path'; received = [string]$dispatchValues[$advisorField] })
                }
            }
        }
        foreach ($fieldAndValues in @(
                [pscustomobject]@{ name = 'write_mode'; values = @('readonly', 'write') },
                [pscustomobject]@{ name = 'dispatch_kind'; values = @('workflow', 'resource') },
                [pscustomobject]@{ name = 'session_mode'; values = @('cold-start', 'continuation') },
                [pscustomobject]@{ name = 'unit_kind'; values = @('workflow-phase', 'resource-target', 'advisor-evidence-question') })) {
            $field = [string]$fieldAndValues.name
            $dispatchFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            $dispatchValues[$field] = Get-DispatchRequestEnumValue -Document $document -Field $field -AllowedValues @($fieldAndValues.values) -RequestPathValue $requestPathValue
        }
        $dispatchFieldPresence.requested_unit = Test-DispatchRequestFieldPresent -Document $document -Name 'requested_unit'
        if ($dispatchFieldPresence.requested_unit) {
            $requestedUnitProperty = $document.PSObject.Properties['requested_unit']
            $dispatchValues.requested_unit = @(Get-DispatchRequestStringArray -Field 'requested_unit' -Value $requestedUnitProperty.Value -RequestPathValue $requestPathValue)
        }
        else {
            $dispatchValues.requested_unit = $null
        }
        $dispatchFieldPresence.continue_from_scope_plan = Test-DispatchRequestFieldPresent -Document $document -Name 'continue_from_scope_plan'
        if ($dispatchFieldPresence.continue_from_scope_plan -and $document.continue_from_scope_plan -isnot [bool]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 continue_from_scope_plan 必須是 boolean。' -RequestPathValue $requestPathValue -Field 'continue_from_scope_plan' -Detail ([ordered]@{ expected_type = 'boolean'; actual_type = Get-DispatchRequestTypeName -Value $document.continue_from_scope_plan })
        }
        $dispatchValues.continue_from_scope_plan = if ($dispatchFieldPresence.continue_from_scope_plan) { [bool]$document.continue_from_scope_plan } else { $null }
        $dispatchFieldPresence.background = Test-DispatchRequestFieldPresent -Document $document -Name 'background'
        if ($dispatchFieldPresence.background -and $document.background -isnot [bool]) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestFieldType' -Message 'request 欄位 background 必須是 boolean。' -RequestPathValue $requestPathValue -Field 'background' -Detail ([ordered]@{ expected_type = 'boolean'; actual_type = Get-DispatchRequestTypeName -Value $document.background })
        }
        $dispatchValues.background = if ($dispatchFieldPresence.background) { [bool]$document.background } else { $false }
    }
    elseif ([string]$document.operation -ceq 'Cleanup') {
        foreach ($field in @('source_root', 'dispatch_root', 'result_path', 'preflight_result_path', 'run_record_path', 'reviewer_report_path')) {
            $cleanupFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            $cleanupValues[$field] = Get-DispatchRequestOptionalString -Document $document -Field $field -RequestPathValue $requestPathValue
        }
        foreach ($field in @('report_path', 'evidence_path')) {
            $cleanupFieldPresence[$field] = Test-DispatchRequestFieldPresent -Document $document -Name $field
            if ($cleanupFieldPresence[$field]) {
                $property = $document.PSObject.Properties[$field]
                $cleanupValues[$field] = @(Get-DispatchRequestStringArray -Field $field -Value $property.Value -RequestPathValue $requestPathValue)
            }
            else {
                $cleanupValues[$field] = $null
            }
        }
    }

    return [ordered]@{
        path                  = $requestPathValue
        sha256                = $hashBefore
        length                = [int64]$bytesBefore.Length
        schema                = 'ai-sessions.dispatch-request.v1'
        document              = $document
        caller_session_id = $callerSessionIdValue
        field_presence        = $fieldPresence
        values                = $arrayValues
        profile               = $profileValue
        advisor_request_source = $advisorRequestSourceValue
        search                = if ($searchPresent) { [bool]$document.search } else { $null }
        prepare_artifacts     = @($prepareArtifacts)
        literal_values_sha256 = if ($fieldPresence.literal_values) { Get-DispatchStringArraySha256 -Values $arrayValues.literal_values } else { $null }
        dispatch_field_presence = $dispatchFieldPresence
        dispatch_values       = $dispatchValues
        cleanup_field_presence = $cleanupFieldPresence
        cleanup_values        = $cleanupValues
    }
}

function Test-DispatchInvocationParameterBound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $script:InvocationBoundParameters.Contains($Name)
}

function Get-DispatchInvocationParameterValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Test-DispatchInvocationParameterBound -Name $Name)) {
        return $null
    }
    return $script:InvocationBoundParameters[$Name]
}

function New-DispatchRequestArrayMismatchDetail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Field,

        [AllowEmptyCollection()]
        [string[]]$Expected,

        [AllowEmptyCollection()]
        [string[]]$Received
    )

    $expectedValues = @($Expected)
    $receivedValues = @($Received)
    $mismatches = New-Object 'System.Collections.Generic.List[object]'
    $firstMismatchIndex = $null
    $maxCount = [math]::Max($expectedValues.Count, $receivedValues.Count)
    for ($index = 0; $index -lt $maxCount; $index++) {
        $expectedValue = if ($index -lt $expectedValues.Count) { $expectedValues[$index] } else { $null }
        $receivedValue = if ($index -lt $receivedValues.Count) { $receivedValues[$index] } else { $null }
        if ($null -eq $firstMismatchIndex -and -not [string]::Equals([string]$expectedValue, [string]$receivedValue, [System.StringComparison]::Ordinal)) {
            $firstMismatchIndex = $index
        }
        if (-not [string]::Equals([string]$expectedValue, [string]$receivedValue, [System.StringComparison]::Ordinal) -or ($null -eq $expectedValue -xor $null -eq $receivedValue)) {
            $mismatches.Add([ordered]@{ index = $index; expected = $expectedValue; received = $receivedValue })
        }
    }
    return [ordered]@{
        field                 = $Field
        expected_count        = $expectedValues.Count
        received_count        = $receivedValues.Count
        first_mismatch_index  = $firstMismatchIndex
        mismatches             = @($mismatches.ToArray())
    }
}

function Apply-DispatchRequestScalarField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Context,

        [Parameter(Mandatory)]
        [string]$CliField,

        [Parameter(Mandatory)]
        [string]$RequestField
    )

    if (-not [bool]$Context.dispatch_field_presence[$RequestField]) {
        return
    }
    $requestValue = [string]$Context.dispatch_values[$RequestField]
    if (Test-DispatchInvocationParameterBound -Name $CliField) {
        $receivedValue = [string](Get-DispatchInvocationParameterValue -Name $CliField)
        $comparison = if ($RequestField -in @('write_mode', 'dispatch_kind', 'session_mode', 'unit_kind')) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
        if (-not [string]::Equals($receivedValue, $requestValue, $comparison)) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $RequestField) -RequestPathValue ([string]$Context.path) -Field $RequestField -Detail ([ordered]@{ expected = $requestValue; received = $receivedValue; process_started = $false })
        }
    }
    else {
        Set-Variable -Name $CliField -Scope Script -Value $requestValue
    }
}

function Apply-DispatchRequestBooleanField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Context,

        [Parameter(Mandatory)]
        [string]$CliField,

        [Parameter(Mandatory)]
        [string]$RequestField
    )

    if (-not [bool]$Context.dispatch_field_presence[$RequestField]) {
        return
    }
    $requestValue = [bool]$Context.dispatch_values[$RequestField]
    if (Test-DispatchInvocationParameterBound -Name $CliField) {
        $receivedValue = [bool](Get-DispatchInvocationParameterValue -Name $CliField)
        if ($receivedValue -ne $requestValue) {
            Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $RequestField) -RequestPathValue ([string]$Context.path) -Field $RequestField -Detail ([ordered]@{ expected = $requestValue; received = $receivedValue; process_started = $false })
        }
    }
    else {
        Set-Variable -Name $CliField -Scope Script -Value $requestValue
    }
}

function Apply-DispatchRequest {
    [CmdletBinding()]
    param()

    if ([string]::IsNullOrWhiteSpace($RequestPath)) {
        $operationValue = Get-Variable -Name 'Operation' -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ([string]$operationValue -ieq 'Dispatch') {
            Throw-DispatchRequestFailure -Code 'DispatchRequestMissingField' -Message 'Dispatch operation 必須提供 -RequestPath。' -Field 'RequestPath' -Detail ([ordered]@{ operation = 'Dispatch'; process_started = $false })
        }
        return $null
    }

    $context = Read-DispatchRequest -Path $RequestPath
    $script:RequestContext = $context
    $document = $context.document
    $requestPathValue = $context.path

    $operationBound = Test-DispatchInvocationParameterBound -Name 'Operation'
    $collectLifecycleRequest = $operationBound -and [string]$Operation -ieq 'Collect' -and [string]$document.operation -ieq 'Dispatch'
    $operationMatches = [string]::Equals([string]$Operation, [string]$document.operation, [System.StringComparison]::OrdinalIgnoreCase)
    if ($operationBound -and -not $operationMatches -and -not $collectLifecycleRequest) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request operation 與命令列 Operation 不一致。' -RequestPathValue $requestPathValue -Field 'operation' -Detail ([ordered]@{ expected = [string]$document.operation; received = [string]$Operation; process_started = $false })
    }
    elseif (-not (Test-DispatchInvocationParameterBound -Name 'Operation')) {
        $script:Operation = [string]$document.operation
    }

    if ([bool]$context.field_presence.profile) {
        $requestProfile = [string]$context.profile
        if (Test-DispatchInvocationParameterBound -Name 'Profile') {
            $receivedProfile = [string](Get-DispatchInvocationParameterValue -Name 'Profile')
            if (-not [string]::Equals($receivedProfile, $requestProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request profile 與命令列參數不一致。' -RequestPathValue $requestPathValue -Field 'profile' -Detail ([ordered]@{ expected = $requestProfile; received = $receivedProfile; process_started = $false })
            }
        }
        else {
            $script:Profile = $requestProfile
            $script:ProfileExplicit = $true
        }
    }

    if ([bool]$context.field_presence.advisor_request_source) {
        $requestAdvisorSource = [string]$context.advisor_request_source
        if (Test-DispatchInvocationParameterBound -Name 'AdvisorRequestSource') {
            $receivedAdvisorSource = [string](Get-DispatchInvocationParameterValue -Name 'AdvisorRequestSource')
            if (-not [string]::Equals($receivedAdvisorSource, $requestAdvisorSource, [System.StringComparison]::OrdinalIgnoreCase)) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request advisor_request_source 與命令列參數不一致。' -RequestPathValue $requestPathValue -Field 'advisor_request_source' -Detail ([ordered]@{ expected = $requestAdvisorSource; received = $receivedAdvisorSource; process_started = $false })
            }
        }
        else {
            $script:AdvisorRequestSource = $requestAdvisorSource
        }
    }

    foreach ($identityField in @('LineSlug', 'DispatchSlug')) {
        $requestField = if ($identityField -eq 'LineSlug') { 'line_slug' } else { 'dispatch_slug' }
        $requestValue = [string](Get-DispatchJsonProperty -Object $document -Name $requestField)
        if (Test-DispatchInvocationParameterBound -Name $identityField) {
            $currentValue = [string](Get-DispatchInvocationParameterValue -Name $identityField)
            if ($currentValue -cne $requestValue) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue $requestPathValue -Field $requestField -Detail ([ordered]@{ expected = $requestValue; received = $currentValue; process_started = $false })
            }
        }
        else {
            if ($identityField -eq 'LineSlug') { $script:LineSlug = $requestValue } else { $script:DispatchSlug = $requestValue }
        }
    }

    foreach ($mapping in @(
            @('TargetPath', 'target_path'),
            @('AddDirectory', 'add_directory'),
            @('CodexParentOption', 'codex_parent_option'))) {
        $cliField = [string]$mapping[0]
        $requestField = [string]$mapping[1]
        if (-not [bool]$context.field_presence[$requestField]) {
            continue
        }
        $requestValues = @($context.values[$requestField])
        if (Test-DispatchInvocationParameterBound -Name $cliField) {
            $receivedValues = @((Get-DispatchInvocationParameterValue -Name $cliField))
            if (-not (Compare-DispatchStringArrays -Left $requestValues -Right $receivedValues)) {
                $detail = New-DispatchRequestArrayMismatchDetail -Field $requestField -Expected $requestValues -Received $receivedValues
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue $requestPathValue -Field $requestField -Detail $detail
            }
        }
        else {
            switch ($cliField) {
                'TargetPath' {
                    $script:TargetPath = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
                }
                'AddDirectory' {
                    $script:AddDirectory = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
                    $script:AddDirectoryExplicit = $true
                }
                'CodexParentOption' {
                    $script:CodexParentOption = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
                    $script:CodexParentOptionExplicit = $true
                }
            }
        }
    }

    if ([bool]$context.field_presence.search) {
        $requestSearch = [bool]$context.search
        if (Test-DispatchInvocationParameterBound -Name 'Search') {
            $receivedSearch = [bool](Get-DispatchInvocationParameterValue -Name 'Search')
            if ($requestSearch -ne $receivedSearch) {
                Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request search 與命令列參數不一致。' -RequestPathValue $requestPathValue -Field 'search' -Detail ([ordered]@{ expected = $requestSearch; received = $receivedSearch; process_started = $false })
            }
        }
        else {
            $script:Search = $requestSearch
            $script:SearchExplicit = $true
        }
    }

    if ([bool]$context.field_presence.literal_values) {
        $script:RequestLiteralValues = @($context.values.literal_values)
    }
    else {
        $script:RequestLiteralValues = New-Object 'System.String[]' 0
    }
    if ([bool]$context.field_presence.prepare_artifacts) {
        $script:RequestPrepareArtifacts = @($context.prepare_artifacts)
    }
    else {
        $script:RequestPrepareArtifacts = New-Object 'System.Object[]' 0
    }
    $script:RequestManualPrepareArtifacts = @($script:RequestPrepareArtifacts)
    $script:RequestAutoPrepareArtifacts = New-Object 'System.Object[]' 0

    if ([string]$document.operation -ceq 'Dispatch') {
        foreach ($mapping in @(
                @('SourceRoot', 'source_root'),
                @('DispatchRoot', 'dispatch_root'),
                @('WriteMode', 'write_mode'),
                @('DispatchKind', 'dispatch_kind'),
                @('PromptPath', 'prompt_path'),
                @('RequiredIdentifier', 'required_identifier'),
                @('TaskType', 'task_type'),
                @('SessionMode', 'session_mode'),
                @('UnitKind', 'unit_kind'),
                @('FailureReceiptPath', 'failure_receipt_path'),
                @('EvidencePackPath', 'evidence_pack_path'),
                @('AdvisorConsultReportPath', 'advisor_consult_report_path'),
                @('ResultPath', 'result_path'),
                @('PreflightResultPath', 'preflight_result_path'),
                @('PrepareResultPath', 'prepare_result_path'),
                @('QuotaBeforePath', 'quota_before_path'),
                @('QuotaAfterPath', 'quota_after_path'),
                @('SelectedRequirement', 'selected_requirement'))) {
            Apply-DispatchRequestScalarField -Context $context -CliField ([string]$mapping[0]) -RequestField ([string]$mapping[1])
        }
        Apply-DispatchRequestBooleanField -Context $context -CliField 'ContinueFromScopePlan' -RequestField 'continue_from_scope_plan'
        $script:DispatchWaitForCompletion = -not [bool]$context.dispatch_values.background
        if ([bool]$context.dispatch_field_presence.requested_unit) {
            $requestValues = @($context.dispatch_values.requested_unit)
            if (Test-DispatchInvocationParameterBound -Name 'RequestedUnit') {
                $receivedValues = @((Get-DispatchInvocationParameterValue -Name 'RequestedUnit'))
                if (-not (Compare-DispatchStringArrays -Left $requestValues -Right $receivedValues)) {
                    $detail = New-DispatchRequestArrayMismatchDetail -Field 'requested_unit' -Expected $requestValues -Received $receivedValues
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message 'request requested_unit 與命令列參數不一致。' -RequestPathValue ([string]$context.path) -Field 'requested_unit' -Detail $detail
                }
            }
            else {
                $script:RequestedUnit = if ($requestValues.Count -eq 0) { New-Object 'System.String[]' 0 } else { [string[]]$requestValues }
            }
        }
    }
    elseif ([string]$document.operation -ceq 'Cleanup') {
        foreach ($mapping in @(
                @('SourceRoot', 'source_root'),
                @('DispatchRoot', 'dispatch_root'),
                @('ResultPath', 'result_path'),
                @('PreflightResultPath', 'preflight_result_path'),
                @('RunRecordPath', 'run_record_path'),
                @('ReviewerReportPath', 'reviewer_report_path'))) {
            $requestField = [string]$mapping[1]
            if (-not [bool]$context.cleanup_field_presence[$requestField]) { continue }
            $cliField = [string]$mapping[0]
            $requestValue = [string]$context.cleanup_values[$requestField]
            if (Test-DispatchInvocationParameterBound -Name $cliField) {
                $receivedValue = [string](Get-DispatchInvocationParameterValue -Name $cliField)
                if ($receivedValue -cne $requestValue) {
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue ([string]$context.path) -Field $requestField -Detail ([ordered]@{ expected = $requestValue; received = $receivedValue; process_started = $false })
                }
            }
            else {
                Set-Variable -Name $cliField -Scope Script -Value $requestValue
            }
        }
        foreach ($mapping in @(@('ReportPath', 'report_path'), @('EvidencePath', 'evidence_path'))) {
            $cliField = [string]$mapping[0]
            $requestField = [string]$mapping[1]
            if (-not [bool]$context.cleanup_field_presence[$requestField]) { continue }
            $requestValues = @($context.cleanup_values[$requestField])
            if (Test-DispatchInvocationParameterBound -Name $cliField) {
                $receivedValues = @((Get-DispatchInvocationParameterValue -Name $cliField))
                if (-not (Compare-DispatchStringArrays -Left $requestValues -Right $receivedValues)) {
                    $detail = New-DispatchRequestArrayMismatchDetail -Field $requestField -Expected $requestValues -Received $receivedValues
                    Throw-DispatchRequestFailure -Code 'DispatchRequestMismatch' -Message ("request {0} 與命令列參數不一致。" -f $requestField) -RequestPathValue ([string]$context.path) -Field $requestField -Detail $detail
                }
            }
            else {
                Set-Variable -Name $cliField -Scope Script -Value ([string[]]$requestValues)
            }
        }
    }
    if ([string]$document.operation -ceq 'Dispatch') {
        Initialize-DispatchRequestDerivedInputs
    }
    return $context
}

function Assert-DispatchSessionMode {
    [CmdletBinding()]
    param()

    $validValues = @('cold-start', 'continuation')
    if ($validValues -contains [string]$SessionMode) {
        return
    }
    $receivedValue = if ($null -eq $SessionMode) { $null } else { [string]$SessionMode }
    if ($null -ne $script:RequestContext) {
        Throw-DispatchRequestFailure -Code 'DispatchRequestInvalidValue' -Message ('request 欄位 session_mode 不支援：' + [string]$receivedValue) -RequestPathValue ([string]$script:RequestContext.path) -Field 'session_mode' -Detail ([ordered]@{ valid_values = $validValues; received = $receivedValue })
    }
    throw ('SessionMode 不支援：received={0}; valid_values={1}' -f [string]$receivedValue, ($validValues -join ', '))
}

function ConvertTo-NonNullObjectArray {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Values
    )

    $valueList = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $Values) {
        foreach ($value in @($Values)) {
            if ($null -ne $value) {
                $valueList.Add($value)
            }
        }
    }
    return ,$valueList.ToArray()
}

function Get-DispatchRequestEvidence {
    [CmdletBinding()]
    param()

    if ($null -eq $script:RequestContext) {
        return $null
    }
    $context = $script:RequestContext
    $arrayEvidence = [ordered]@{}
    foreach ($field in @('target_path', 'add_directory', 'codex_parent_option', 'literal_values')) {
        $provided = [bool]$context.field_presence[$field]
        $valueList = New-Object 'System.Collections.Generic.List[string]'
        if ($provided) {
            foreach ($value in @($context.values[$field])) {
                if ($null -ne $value) {
                    $valueList.Add([string]$value)
                }
            }
        }
        $values = $valueList.ToArray()
        $arrayEvidence[$field] = [ordered]@{
            provided = $provided
            count    = $values.Count
            sha256   = if ($provided) { Get-DispatchStringArraySha256 -Values $values } else { $null }
            values   = $values
        }
    }
    return [ordered]@{
        schema                = $context.schema
        operation             = [string](Get-DispatchJsonProperty -Object $context.document -Name 'operation')
        line_slug             = [string](Get-DispatchJsonProperty -Object $context.document -Name 'line_slug')
        dispatch_slug         = [string](Get-DispatchJsonProperty -Object $context.document -Name 'dispatch_slug')
        path                  = $context.path
        sha256                = $context.sha256
        length                = $context.length
        field_presence        = $context.field_presence
        literal_values_sha256 = $context.literal_values_sha256
        profile               = [ordered]@{
            provided = [bool]$context.field_presence.profile
            value    = if ([bool]$context.field_presence.profile) { [string]$context.profile } else { $null }
        }
        advisor_request_source = [ordered]@{
            provided = [bool]$context.field_presence.advisor_request_source
            value    = if ([bool]$context.field_presence.advisor_request_source) { [string]$context.advisor_request_source } else { $null }
        }
        caller_session = [ordered]@{
            provided = [bool]$context.field_presence.caller_session_id
            fingerprint = if ($null -eq $script:CallerSessionIdentity) { $null } else { [string]$script:CallerSessionIdentity.Fingerprint }
            source = if ($null -eq $script:CallerSessionIdentity) { $null } else { [string]$script:CallerSessionIdentity.Source }
        }
        search                = [ordered]@{
            provided = [bool]$context.field_presence.search
            value    = if ([bool]$context.field_presence.search) { [bool]$context.search } else { $null }
        }
        arrays                = $arrayEvidence
        prepare_artifacts     = ConvertTo-NonNullObjectArray -Values $context.prepare_artifacts
        dispatch              = [ordered]@{
            field_presence = $context.dispatch_field_presence
            values         = $context.dispatch_values
        }
        cleanup               = [ordered]@{
            field_presence = $context.cleanup_field_presence
            values         = $context.cleanup_values
        }
    }
}

function Get-ScopePlanHashRecordPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceHistoryRoot,

        [Parameter(Mandatory)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $lineScopedPath = Join-Path -Path (Join-Path -Path $SourceHistoryRoot -ChildPath $LineSlug) -ChildPath ('scope-plan-hash-' + $DispatchSlug + '.json')
    if (Test-Path -LiteralPath $lineScopedPath -PathType Leaf) {
        return $lineScopedPath
    }

    $legacyPath = Join-Path -Path $SourceHistoryRoot -ChildPath ('scope-plan-hash-' + $DispatchSlug + '.json')
    if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) {
        return $lineScopedPath
    }

    try {
        $legacyRecord = Get-Content -LiteralPath $legacyPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $lineScopedPath
    }
    $legacyLineSlug = [string](Get-OptionalObjectProperty -Object $legacyRecord -Name 'line_slug')
    if ([string]::IsNullOrWhiteSpace($legacyLineSlug)) {
        $rootRunId = [string](Get-OptionalObjectProperty -Object $legacyRecord -Name 'root_run_id')
        $rootRunGuid = [guid]::Empty
        if ([guid]::TryParse($rootRunId, [ref]$rootRunGuid)) {
            foreach ($lineDirectory in @(Get-ChildItem -LiteralPath $SourceHistoryRoot -Directory -ErrorAction SilentlyContinue)) {
                $runRecordPath = Join-Path -Path (Join-Path -Path (Join-Path -Path $lineDirectory.FullName -ChildPath 'runs') -ChildPath $DispatchSlug) -ChildPath ($rootRunGuid.ToString('D') + '.json')
                if (-not (Test-Path -LiteralPath $runRecordPath -PathType Leaf)) {
                    continue
                }
                try {
                    $runRecord = Get-Content -LiteralPath $runRecordPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $legacyLineSlug = [string](Get-OptionalObjectProperty -Object $runRecord -Name 'line_slug')
                    if ([string]::IsNullOrWhiteSpace($legacyLineSlug)) {
                        $legacyLineSlug = [string]$lineDirectory.Name
                    }
                }
                catch {
                    $legacyLineSlug = ''
                }
                break
            }
        }
    }

    if ([string]::Equals($legacyLineSlug, $LineSlug, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $legacyPath
    }
    return $lineScopedPath
}

function Write-ScopePlanHashRecordIfMissing {
    param(
        [Parameter(Mandatory)]
        [string]$SourceHistoryRoot,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$ScopePlanPath,

        [string]$RootRunId,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    $recordPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot $SourceHistoryRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        try {
            $existingRecord = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            throw "既有 ScopePlan SHA-256 紀錄無法解析：$recordPath；$($_.Exception.Message)"
        }
        if (-not [string]::IsNullOrWhiteSpace($RootRunId)) {
            $existingRootRunIdProperty = $existingRecord.PSObject.Properties['root_run_id']
            if ($null -eq $existingRootRunIdProperty -or [string]$existingRootRunIdProperty.Value -cne $RootRunId) {
                throw "既有 ScopePlan SHA-256 紀錄的 root run 不一致：record=$([string](Get-OptionalObjectProperty -Object $existingRecord -Name 'root_run_id'))；expected=$RootRunId"
            }
        }
        return $recordPath
    }

    $resolvedScopePlanPath = Resolve-AbsolutePath -Path $ScopePlanPath
    $record = [ordered]@{
        dispatch_slug   = $DispatchSlug
        line_slug       = $LineSlug
        scope_plan_path = $resolvedScopePlanPath
        sha256          = Get-FileSha256 -Path $resolvedScopePlanPath
        created_at_utc  = [datetime]::UtcNow.ToString('o')
        root_run_id     = if ([string]::IsNullOrWhiteSpace($RootRunId)) { $null } else { $RootRunId }
    }
    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $recordPath = Resolve-DispatchOutputPath -CandidatePath $recordPath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    Write-Utf8NoBom -Path $recordPath -Content (($record | ConvertTo-Json -Depth 8) + "`n") -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    return $recordPath
}

function Test-ScopePlanHashRecord {
    param(
        [Parameter(Mandatory)]
        [string]$SourceHistoryRoot,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$ScopePlanPath,

        [string]$ExpectedRootRunId
    )

    $recordPath = Get-ScopePlanHashRecordPath -SourceHistoryRoot $SourceHistoryRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        throw "續行缺少 ScopePlan SHA-256 紀錄：$recordPath"
    }

    try {
        $record = Get-Content -LiteralPath $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "ScopePlan SHA-256 紀錄無法解析：$recordPath；$($_.Exception.Message)"
    }
    foreach ($requiredProperty in @('dispatch_slug', 'line_slug', 'scope_plan_path', 'sha256', 'created_at_utc')) {
        if ($null -eq $record.PSObject.Properties[$requiredProperty] -or [string]::IsNullOrWhiteSpace([string]$record.$requiredProperty)) {
            throw "ScopePlan SHA-256 紀錄缺少必要欄位：$requiredProperty"
        }
    }

    $resolvedScopePlanPath = Resolve-AbsolutePath -Path $ScopePlanPath
    $recordScopePlanPath = Resolve-AbsolutePath -Path ([string]$record.scope_plan_path)
    if (-not [string]::Equals([string]$record.dispatch_slug, $DispatchSlug, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$record.line_slug, $LineSlug, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ScopePlan SHA-256 紀錄的 dispatchSlug 或 lineSlug 不一致：$recordPath"
    }
    if (-not [string]::Equals($recordScopePlanPath, $resolvedScopePlanPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ScopePlan SHA-256 紀錄的路徑不一致：record=$recordScopePlanPath；requested=$resolvedScopePlanPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRootRunId)) {
        $rootRunIdProperty = $record.PSObject.Properties['root_run_id']
        if ($null -eq $rootRunIdProperty -or [string]$rootRunIdProperty.Value -cne $ExpectedRootRunId) {
            throw "ScopePlan SHA-256 紀錄的 root run 不一致：record=$([string]$record.root_run_id)；expected=$ExpectedRootRunId"
        }
    }

    $actualHash = Get-FileSha256 -Path $resolvedScopePlanPath
    if (-not [string]::Equals([string]$record.sha256, $actualHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ScopePlan SHA-256 不一致：record=$($record.sha256)；actual=$actualHash"
    }
    return $true
}

function Test-ScopePlanCompleteness {
    param([AllowNull()][object]$ScopePlan)
    if ($null -eq $ScopePlan) { return $false }
    if ($ScopePlan -is [System.Collections.IDictionary]) {
        $ScopePlan = [pscustomobject]$ScopePlan
    }
    foreach ($name in @('dispatch_slug', 'dispatch_kind', 'task_type', 'requested_profile', 'session_mode', 'primary_remaining_percent', 'primary_reserve_percent', 'primary_budget_percent', 'estimate_percent', 'estimate_source', 'unit_kind', 'requested_units', 'selected_units', 'deferred_units', 'decision', 'decision_reason')) {
        if ($null -eq $ScopePlan.PSObject.Properties[$name]) { return $false }
    }
    if ([string]::IsNullOrWhiteSpace([string]$ScopePlan.dispatch_slug) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.dispatch_kind) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.task_type) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.requested_profile) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.session_mode) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.unit_kind) -or
        [string]$ScopePlan.estimate_source -ne 'not-used' -or
        $null -ne $ScopePlan.estimate_percent -or
        [string]$ScopePlan.decision -ne 'full' -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.decision_reason)) { return $false }
    if ($ScopePlan.unit_kind -notin @('workflow-phase', 'resource-target', 'advisor-evidence-question')) { return $false }
    if ([string]$ScopePlan.task_type -eq 'advisor-consult') {
        foreach ($name in @('activation_mode', 'authorization_source', 'activation_granted', 'reserve_bypassed', 'minimum_unit_over_budget', 'stop_after_selected_units', 'advisor_unit_estimate_percent')) {
            if ($null -eq $ScopePlan.PSObject.Properties[$name]) { return $false }
        }
        if ([string]$ScopePlan.activation_mode -notin @('user-authorized', 'none') -or
            ($null -ne $ScopePlan.authorization_source -and [string]$ScopePlan.authorization_source -ne 'user-explicit') -or
            $ScopePlan.activation_granted -isnot [bool] -or
            $ScopePlan.reserve_bypassed -isnot [bool] -or
            $ScopePlan.minimum_unit_over_budget -isnot [bool] -or
            $ScopePlan.stop_after_selected_units -isnot [bool] -or
            $null -ne $ScopePlan.advisor_unit_estimate_percent) { return $false }
        if ($ScopePlan.activation_granted -and ([string]$ScopePlan.activation_mode -ne 'user-authorized' -or [string]$ScopePlan.authorization_source -ne 'user-explicit')) { return $false }
    }
    $freshness = $ScopePlan.PSObject.Properties['quota_freshness']
    if ($null -ne $freshness -and [string]$freshness.Value -notin @('fresh', 'stale', 'unknown')) { return $false }

    $requested = @($ScopePlan.requested_units | ForEach-Object { [string]$_ })
    $selected = @($ScopePlan.selected_units | ForEach-Object { [string]$_ })
    $deferred = @($ScopePlan.deferred_units | ForEach-Object { [string]$_ })
    if ($requested.Count -eq 0 -or
        @($requested | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        @($selected | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        $deferred.Count -ne 0 -or
        -not (Test-StringArrayEqual -Left $requested -Right $selected)) { return $false }
    $unitSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($unit in $requested) { if (-not $unitSet.Add($unit)) { return $false } }
    return $true
}

function Test-ContinuationScopePlan {
    param(
        [Parameter(Mandatory)]
        [psobject]$ScopePlan,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$RequestedProfile,

        [Parameter(Mandatory)]
        [string]$UnitKind,

        [Parameter(Mandatory)]
        [string[]]$Units
    )

    if (-not (Test-ScopePlanCompleteness -ScopePlan $ScopePlan)) {
        return $false
    }
    $selectedUnits = @($ScopePlan.selected_units | ForEach-Object { [string]$_ })
    $deferredUnits = @($ScopePlan.deferred_units | ForEach-Object { [string]$_ })
    $continuationUnits = @($selectedUnits + $deferredUnits)
    if (-not (Test-StringArrayEqual -Left $continuationUnits -Right $ScopePlan.requested_units) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.decision) -or
        [string]::IsNullOrWhiteSpace([string]$ScopePlan.estimate_source)) {
        return $false
    }
    if (-not [string]::Equals([string]$ScopePlan.dispatch_slug, $DispatchSlug, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.dispatch_kind, $DispatchKind, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.task_type, $TaskType, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.requested_profile, $RequestedProfile, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([string]$ScopePlan.unit_kind, $UnitKind, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]$ScopePlan.session_mode -notin @('cold-start', 'continuation') -or
        -not (Test-StringArrayEqual -Left $ScopePlan.requested_units -Right $Units)) {
        return $false
    }
    return $true
}

function New-ContinuationScopePlanSubset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject]$ParentScopePlan,

        [Parameter(Mandatory)]
        [string[]]$RequestedUnits,

        [Parameter(Mandatory)]
        [string]$ParentScopePlanPath,

        [Parameter(Mandatory)]
        [string]$ParentScopePlanSha256,

        [Parameter(Mandatory)]
        [string]$ParentRunId
    )

    if (-not (Test-ScopePlanCompleteness -ScopePlan $ParentScopePlan)) {
        throw '續行的父 ScopePlan 不完整，拒絕建立子集。'
    }
    if ($null -eq $RequestedUnits -or $RequestedUnits.Count -eq 0) {
        throw 'ContinueFromScopePlan 必須提供至少一個 RequestedUnit。'
    }

    $parentUnits = @($ParentScopePlan.requested_units | ForEach-Object { [string]$_ })
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $previousParentIndex = -1
    foreach ($requestedUnit in @($RequestedUnits)) {
        if ([string]::IsNullOrWhiteSpace($requestedUnit)) {
            throw 'ContinueFromScopePlan 的 RequestedUnit 不可為空白。'
        }
        if (-not $seen.Add([string]$requestedUnit)) {
            throw ('ContinueFromScopePlan 的 RequestedUnit 不可重複：' + [string]$requestedUnit)
        }
        $parentIndex = -1
        for ($index = 0; $index -lt $parentUnits.Count; $index++) {
            if ([string]::Equals($parentUnits[$index], [string]$requestedUnit, [System.StringComparison]::OrdinalIgnoreCase)) {
                $parentIndex = $index
                break
            }
        }
        if ($parentIndex -lt 0) {
            throw ('ContinueFromScopePlan 的 RequestedUnit 不在父集合：' + [string]$requestedUnit)
        }
        if ($parentIndex -le $previousParentIndex) {
            throw 'ContinueFromScopePlan 的 RequestedUnit 必須維持父 ScopePlan 宣告順序。'
        }
        $previousParentIndex = $parentIndex
    }

    $child = $ParentScopePlan | ConvertTo-Json -Depth 30 | ConvertFrom-Json
    $child.requested_units = @($RequestedUnits | ForEach-Object { [string]$_ })
    $child.selected_units = @($RequestedUnits | ForEach-Object { [string]$_ })
    $child.deferred_units = @()
    $child.decision = 'full'
    $child.decision_reason = 'continuation subset 已依父 ScopePlan 宣告順序建立。'
    $child.session_mode = 'continuation'
    $child.stop_after_selected_units = $false
    $child | Add-Member -MemberType NoteProperty -Name 'parent_scope_plan_path' -Value (Resolve-AbsolutePath -Path $ParentScopePlanPath) -Force
    $child | Add-Member -MemberType NoteProperty -Name 'parent_scope_plan_sha256' -Value $ParentScopePlanSha256 -Force
    $child | Add-Member -MemberType NoteProperty -Name 'parent_run_id' -Value $ParentRunId -Force
    $child | Add-Member -MemberType NoteProperty -Name 'selection_classification' -Value 'subset' -Force
    $child.scope_plan_fingerprint = Get-ScopePlanFingerprint -ScopePlan $child
    return $child
}
