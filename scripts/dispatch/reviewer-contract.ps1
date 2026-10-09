function Get-ReviewerPropertyValue {
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
        if ($Object.Contains($Name)) {
            return $Object[$Name]
        }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Test-ReviewerJsonArray {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $false
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $false
    }
    $value = $property.Value
    return $null -ne $value -and $value -is [System.Collections.IEnumerable] -and $value -isnot [string] -and $value -isnot [System.Collections.IDictionary]
}

function Test-ReviewerJsonPositiveInteger {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $false
    }

    $typeCode = [System.Type]::GetTypeCode($Value.GetType())
    if ($typeCode -notin @([System.TypeCode]::SByte, [System.TypeCode]::Byte, [System.TypeCode]::Int16, [System.TypeCode]::UInt16, [System.TypeCode]::Int32, [System.TypeCode]::UInt32, [System.TypeCode]::Int64, [System.TypeCode]::UInt64)) {
        return $false
    }

    $numericValue = [decimal]$Value
    return $numericValue -gt 0 -and $numericValue -le [decimal][int64]::MaxValue
}

function Test-ReviewerFindingId {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$FindingId
    )

    return $FindingId -cmatch '^(?:F-[0-9]{3}|T[0-9]{3}[A-Z]?)$'
}

function Get-ReviewerDeclaredCount {
    param(
        [AllowNull()]
        [object]$Counts,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Inconsistencies
    )

    $property = if ($null -eq $Counts) { $null } else { $Counts.PSObject.Properties[$Name] }
    if ($null -eq $property) {
        $Inconsistencies.Add('counts.' + $Name + ' missing')
        return $null
    }

    try {
        $value = [int64]$property.Value
    }
    catch {
        $Inconsistencies.Add('counts.' + $Name + ' is not an integer')
        return $null
    }
    if ($value -lt 0) {
        $Inconsistencies.Add('counts.' + $Name + ' is negative')
        return $null
    }
    return $value
}

function Get-ReviewerAcceptance {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Acceptance,

        [Parameter(Mandatory)]
        [string]$FindingId,

        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Inconsistencies
    )

    if ($null -eq $Acceptance -or $Acceptance -isnot [pscustomobject]) {
        $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance must be an object')
        return $null
    }

    $decidedBy = [string](Get-ReviewerPropertyValue -Object $Acceptance -Name 'decided_by')
    $scope = [string](Get-ReviewerPropertyValue -Object $Acceptance -Name 'scope')
    $reopenCondition = [string](Get-ReviewerPropertyValue -Object $Acceptance -Name 'reopen_condition')
    if ([string]::IsNullOrWhiteSpace($decidedBy)) { $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance.decided_by missing') }
    if ([string]::IsNullOrWhiteSpace($scope)) { $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance.scope missing') }
    if ([string]::IsNullOrWhiteSpace($reopenCondition)) { $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance.reopen_condition missing') }

    $evidenceProperty = $Acceptance.PSObject.Properties['evidence']
    $evidence = $null
    if ($null -ne $evidenceProperty) {
        $evidence = $evidenceProperty.Value
    }
    if ($null -eq $evidence -or $evidence -isnot [System.Array]) {
        $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance.evidence must be a non-empty array')
        $evidence = @()
    }
    $normalizedEvidence = New-Object System.Collections.Generic.List[object]
    foreach ($position in @($evidence)) {
        $positionPath = [string](Get-ReviewerPropertyValue -Object $position -Name 'path')
        $positionLine = [int64]0
        $positionLineValue = Get-ReviewerPropertyValue -Object $position -Name 'line'
        if ([string]::IsNullOrWhiteSpace($positionPath) -or -not (Test-ReviewerJsonPositiveInteger -Value $positionLineValue)) {
            $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance evidence position invalid')
            continue
        }
        $positionLine = [int64]$positionLineValue
        if (-not (Test-ReviewerAbsolutePath -Path $positionPath)) {
            $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance evidence path must be absolute')
            continue
        }
        $normalizedEvidence.Add([ordered]@{ path = $positionPath; line = $positionLine })
    }
    if ($normalizedEvidence.Count -eq 0) {
        $Inconsistencies.Add($FindingId + ' ' + $Label + ' acceptance.evidence missing')
    }

    return [pscustomobject]@{
        decided_by = $decidedBy
        scope = $scope
        evidence = @($normalizedEvidence.ToArray())
        reopen_condition = $reopenCondition
    }
}

function ConvertTo-ReviewerJudgmentStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        '^(closed|已閉合)$' { return 'closed' }
        '^(open|未閉合)$' { return 'open' }
        '^(withdrawn|撤回)$' { return 'withdrawn' }
        '^(accepted|已接受殘餘風險)$' { return 'accepted' }
        default { return $null }
    }
}

function Test-ReviewerAbsolutePath {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        return $false
    }
    if (Test-IsWindowsPlatform) {
        return $Path -match '^(?:[A-Za-z]:[\\/]|\\\\)'
    }
    return $true
}

function Get-ReviewerBodyJudgment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Content
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $sectionMatches = [regex]::Matches($Content, '(?ms)^##[ \t]+本輪 finding 判定[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
    if ($sectionMatches.Count -ne 1) {
        $errors.Add(('current judgment prose section count={0}' -f $sectionMatches.Count))
        return [ordered]@{ present = $false; entries = @(); errors = @($errors) }
    }

    $seen = @{}
    foreach ($line in [regex]::Split($sectionMatches[0].Groups['section'].Value, '\r?\n')) {
        $idMatch = [regex]::Match($line, '\[(?<id>F-[0-9]{3}|T[0-9]{3}[A-Z]?)\]')
        if (-not $idMatch.Success) {
            continue
        }

        $id = $idMatch.Groups['id'].Value
        $statusMatch = [regex]::Match($line, '(?i)(?<![A-Za-z])(?<status>closed|open|withdrawn|accepted|已閉合|未閉合|撤回|已接受殘餘風險)(?![A-Za-z])')
        $statusNegated = $statusMatch.Success -and [regex]::IsMatch($line.Substring(0, $statusMatch.Index), '(?i)\bnot[ \t]+$|(?:非|未|不)[ \t]*$')
        $status = if ($statusMatch.Success -and -not $statusNegated) { ConvertTo-ReviewerJudgmentStatus -Value $statusMatch.Groups['status'].Value } else { $null }
        if ($null -eq $status) {
            $errors.Add($id + ' current judgment prose status missing')
        }

        $severityMatch = [regex]::Match($line, '(?:\[(?<bracket>Critical|Major|Minor)\]|（(?<full>Critical|Major|Minor)）)')
        $severity = if ($severityMatch.Success) {
            if (-not [string]::IsNullOrWhiteSpace($severityMatch.Groups['bracket'].Value)) { $severityMatch.Groups['bracket'].Value } else { $severityMatch.Groups['full'].Value }
        }
        else {
            $null
        }
        if ($null -eq $severity) {
            $errors.Add($id + ' current judgment prose severity missing')
        }

        $evidenceMatch = [regex]::Match($line, '(?i)(?:evidence|證據)[ \t]*[:：][ \t]*(?<path>.+?)(?::(?<line>[0-9]+))[ \t]*$')
        $evidencePath = if ($evidenceMatch.Success) { $evidenceMatch.Groups['path'].Value.Trim() } else { $null }
        $evidenceLine = [int64]0
        $hasEvidenceLine = $evidenceMatch.Success -and [int64]::TryParse($evidenceMatch.Groups['line'].Value, [ref]$evidenceLine) -and $evidenceLine -gt 0
        if (-not $hasEvidenceLine -or [string]::IsNullOrWhiteSpace($evidencePath)) {
            $errors.Add($id + ' current judgment prose evidence missing')
        }
        elseif (-not (Test-ReviewerAbsolutePath -Path $evidencePath)) {
            $errors.Add($id + ' current judgment prose evidence path must be absolute')
        }

        $reopenConditionMatch = [regex]::Match($line, '(?i)(?:reopen_condition|重新開啟條件)[ \t]*[:：][ \t]*(?<condition>.+?)(?=[ \t]*(?:\||;|；|(?:evidence|證據)[ \t]*[:：])|$)')
        $reopenCondition = if ($reopenConditionMatch.Success) { $reopenConditionMatch.Groups['condition'].Value.Trim() } else { $null }

        $entry = [pscustomobject]@{
            id = $id
            status = $status
            severity = $severity
            evidence = if ($hasEvidenceLine) { @([ordered]@{ path = $evidencePath; line = $evidenceLine }) } else { @() }
            reopen_condition = $reopenCondition
        }
        if ($seen.ContainsKey($id)) {
            $previous = $seen[$id]
            if ($previous.status -cne $entry.status -or $previous.severity -cne $entry.severity -or $previous.reopen_condition -cne $entry.reopen_condition -or (ConvertTo-Json -InputObject $previous.evidence -Compress) -cne (ConvertTo-Json -InputObject $entry.evidence -Compress)) {
                $errors.Add($id + ' current judgment prose duplicate fields conflict')
            }
        }
        else {
            $seen[$id] = $entry
            $entries.Add($entry)
        }
    }

    return [ordered]@{
        present = $true
        entries = @($entries.ToArray())
        errors = @($errors)
    }
}

function Test-ReviewerFindingReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Reviewer report 不存在：$fullPath"
    }

    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $content = $utf8.GetString([System.IO.File]::ReadAllBytes($fullPath))
    }
    catch {
        throw "Reviewer report 無法讀取：$fullPath；$($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Reviewer report 為空：$fullPath"
    }

    $inconsistencies = New-Object System.Collections.Generic.List[string]
    $overviewMatches = [regex]::Matches($content, '(?m)^##[ \t]+總覽[ \t]*\r?$')
    $manifestMatches = [regex]::Matches($content, '(?m)^##[ \t]+Finding manifest[ \t]*\r?$')
    if ($overviewMatches.Count -ne 1) {
        $inconsistencies.Add(('overview heading count={0}' -f $overviewMatches.Count))
    }
    if ($manifestMatches.Count -ne 1) {
        $inconsistencies.Add(('Finding manifest heading count={0}' -f $manifestMatches.Count))
    }
    if ($overviewMatches.Count -eq 1 -and $manifestMatches.Count -eq 1 -and $manifestMatches[0].Index -lt $overviewMatches[0].Index) {
        $inconsistencies.Add('Finding manifest must follow 總覽')
    }

    $manifest = $null
    $manifestSection = ''
    if ($manifestMatches.Count -eq 1) {
        $manifestStart = $manifestMatches[0].Index + $manifestMatches[0].Length
        $remaining = $content.Substring($manifestStart)
        $nextHeading = [regex]::Match($remaining, '(?m)^##[ \t]+')
        if ($nextHeading.Success) {
            $manifestSection = $remaining.Substring(0, $nextHeading.Index)
        }
        else {
            $manifestSection = $remaining
        }

        $jsonBlocks = [regex]::Matches($manifestSection, '(?ms)^```json[ \t]*\r?\n(?<json>.*?)^```[ \t]*\r?$')
        $fenceLines = [regex]::Matches($manifestSection, '(?m)^```')
        if ($jsonBlocks.Count -ne 1 -or $fenceLines.Count -ne 2) {
            $inconsistencies.Add(('Finding manifest JSON block count={0}; fence line count={1}' -f $jsonBlocks.Count, $fenceLines.Count))
        }
        elseif ($jsonBlocks.Count -eq 1) {
            try {
                $manifest = ConvertFrom-DispatchJson -Content $jsonBlocks[0].Groups['json'].Value.Trim()
            }
            catch {
                $inconsistencies.Add('Finding manifest JSON parse failed: ' + $_.Exception.Message)
            }
        }
    }

    $currentEntries = @()
    $previousEntries = @()
    $currentJudgmentEntries = @()
    $currentJudgmentSeen = @{}
    $currentJudgmentExplicit = $false
    $currentJudgmentAdapter = $false
    $manifestSchema = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'schema')
    $manifestLineSlug = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'line_slug')
    $manifestDispatchSlug = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'dispatch_slug')
    $manifestRound = Get-ReviewerPropertyValue -Object $manifest -Name 'round'
    $manifestRoundValue = $null
    $currentSeen = @{}
    $previousSeen = @{}
    $duplicateIds = New-Object System.Collections.Generic.List[string]
    if ($null -ne $manifest) {
        if ($manifestSchema -notin @('codex-dispatch.review-findings.v1', 'codex-dispatch.review-findings.v2')) {
            $inconsistencies.Add('schema must be codex-dispatch.review-findings.v1 or codex-dispatch.review-findings.v2')
        }
        if ($manifestSchema -ceq 'codex-dispatch.review-findings.v2') {
            if ([string]::IsNullOrWhiteSpace($manifestLineSlug)) {
                $inconsistencies.Add('line_slug missing')
            }
            elseif ($manifestLineSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                $inconsistencies.Add('line_slug invalid: ' + $manifestLineSlug)
            }
            if ([string]::IsNullOrWhiteSpace($manifestDispatchSlug)) {
                $inconsistencies.Add('dispatch_slug missing')
            }
            elseif ($manifestDispatchSlug -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                $inconsistencies.Add('dispatch_slug invalid: ' + $manifestDispatchSlug)
            }
            $roundValue = [int64]0
            if ($null -eq $manifestRound -or -not [int64]::TryParse([string]$manifestRound, [ref]$roundValue) -or $roundValue -lt 1) {
                $inconsistencies.Add('round must be a positive integer')
            }
            else {
                $manifestRoundValue = $roundValue
            }
        }
        if (-not (Test-ReviewerJsonArray -Object $manifest -Name 'current_findings')) {
            $inconsistencies.Add('current_findings must be an array')
        }
        else {
            $currentEntries = @($manifest.PSObject.Properties['current_findings'].Value)
        }
        if (-not (Test-ReviewerJsonArray -Object $manifest -Name 'previous_status')) {
            $inconsistencies.Add('previous_status must be an array')
        }
        else {
            $previousEntries = @($manifest.PSObject.Properties['previous_status'].Value)
        }

        $currentJudgmentProperty = $manifest.PSObject.Properties['current_judgment']
        if ($null -ne $currentJudgmentProperty) {
            $currentJudgmentExplicit = $true
            if (-not (Test-ReviewerJsonArray -Object $manifest -Name 'current_judgment')) {
                $inconsistencies.Add('current_judgment must be an array')
            }
            else {
                $currentJudgmentEntries = @($currentJudgmentProperty.Value)
            }
        }
        elseif ($manifestSchema -ceq 'codex-dispatch.review-findings.v2') {
            $inconsistencies.Add('current_judgment must be present for v2')
        }

        foreach ($entry in $currentEntries) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                $inconsistencies.Add('current_findings contains a non-object entry')
                continue
            }
            $id = [string](Get-ReviewerPropertyValue -Object $entry -Name 'id')
            $axis = [string](Get-ReviewerPropertyValue -Object $entry -Name 'axis')
            $status = [string](Get-ReviewerPropertyValue -Object $entry -Name 'status')
            $severity = [string](Get-ReviewerPropertyValue -Object $entry -Name 'severity')
            $disposition = [string](Get-ReviewerPropertyValue -Object $entry -Name 'disposition')
            $summary = [string](Get-ReviewerPropertyValue -Object $entry -Name 'summary')
            if (-not (Test-ReviewerFindingId -FindingId $id)) { $inconsistencies.Add('current finding ID invalid: ' + $id); continue }
            if ($axis -notin @('Standards', 'Spec')) { $inconsistencies.Add($id + ' axis invalid: ' + $axis) }
            if ($status -cne 'open') { $inconsistencies.Add($id + ' current status must be open') }
            if ($severity -notin @('Critical', 'Major', 'Minor')) { $inconsistencies.Add($id + ' severity invalid: ' + $severity) }
            if ($disposition -notin @('new', 'carried')) { $inconsistencies.Add($id + ' disposition invalid: ' + $disposition) }
            if ([string]::IsNullOrWhiteSpace($summary)) { $inconsistencies.Add($id + ' summary missing') }
            $normalizedEntry = [pscustomobject]@{ id = $id; status = $status; severity = $severity; disposition = $disposition }
            if ($currentSeen.ContainsKey($id)) {
                $duplicateIds.Add($id)
                $previousEntry = $currentSeen[$id]
                if ($previousEntry.status -cne $status -or $previousEntry.severity -cne $severity -or $previousEntry.disposition -cne $disposition) {
                    $inconsistencies.Add($id + ' duplicate fields conflict')
                }
            }
            else {
                $currentSeen[$id] = $normalizedEntry
            }
        }

        foreach ($entry in $previousEntries) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                $inconsistencies.Add('previous_status contains a non-object entry')
                continue
            }
            $id = [string](Get-ReviewerPropertyValue -Object $entry -Name 'id')
            $status = [string](Get-ReviewerPropertyValue -Object $entry -Name 'status')
            $severity = [string](Get-ReviewerPropertyValue -Object $entry -Name 'severity')
            if (-not (Test-ReviewerFindingId -FindingId $id)) { $inconsistencies.Add('previous finding ID invalid: ' + $id); continue }
            if ($status -notin @('closed', 'open', 'withdrawn', 'accepted')) { $inconsistencies.Add($id + ' previous status invalid: ' + $status) }
            if ($severity -notin @('Critical', 'Major', 'Minor')) { $inconsistencies.Add($id + ' previous severity invalid: ' + $severity) }
            $acceptance = if ($status -ceq 'accepted') {
                Get-ReviewerAcceptance -Acceptance (Get-ReviewerPropertyValue -Object $entry -Name 'acceptance') -FindingId $id -Label 'previous_status' -Inconsistencies $inconsistencies
            }
            else {
                $null
            }
            $normalizedEntry = [pscustomobject]@{ id = $id; status = $status; severity = $severity; acceptance = $acceptance }
            if ($previousSeen.ContainsKey($id)) {
                $previousEntry = $previousSeen[$id]
                if ($previousEntry.status -cne $status -or $previousEntry.severity -cne $severity -or (ConvertTo-Json -InputObject $previousEntry.acceptance -Compress) -cne (ConvertTo-Json -InputObject $acceptance -Compress)) {
                    $inconsistencies.Add($id + ' previous duplicate fields conflict')
                }
            }
            else {
                $previousSeen[$id] = $normalizedEntry
            }
        }

        foreach ($entry in $currentJudgmentEntries) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject]) {
                $inconsistencies.Add('current_judgment contains a non-object entry')
                continue
            }
            $id = [string](Get-ReviewerPropertyValue -Object $entry -Name 'id')
            $status = [string](Get-ReviewerPropertyValue -Object $entry -Name 'status')
            $severity = [string](Get-ReviewerPropertyValue -Object $entry -Name 'severity')
            $evidenceProperty = $entry.PSObject.Properties['evidence']
            $evidence = $null
            if ($null -ne $evidenceProperty) {
                $evidence = $evidenceProperty.Value
            }
            if (-not (Test-ReviewerFindingId -FindingId $id)) { $inconsistencies.Add('current judgment ID invalid: ' + $id); continue }
            if ($status -notin @('closed', 'open', 'withdrawn', 'accepted')) { $inconsistencies.Add($id + ' current judgment status invalid: ' + $status) }
            if ($severity -notin @('Critical', 'Major', 'Minor')) { $inconsistencies.Add($id + ' current judgment severity invalid: ' + $severity) }
            if ($null -eq $evidence -or $evidence -isnot [System.Array]) {
                $inconsistencies.Add($id + ' current judgment evidence must be an array')
                $evidence = @()
            }
            $normalizedEvidence = New-Object System.Collections.Generic.List[object]
            foreach ($position in @($evidence)) {
                $positionPath = [string](Get-ReviewerPropertyValue -Object $position -Name 'path')
                $positionLine = [int64]0
                $positionLineValue = Get-ReviewerPropertyValue -Object $position -Name 'line'
                if ([string]::IsNullOrWhiteSpace($positionPath) -or -not (Test-ReviewerJsonPositiveInteger -Value $positionLineValue)) {
                    $inconsistencies.Add($id + ' current judgment evidence position invalid')
                    continue
                }
                $positionLine = [int64]$positionLineValue
                if (-not (Test-ReviewerAbsolutePath -Path $positionPath)) {
                    $inconsistencies.Add($id + ' current judgment evidence path must be absolute')
                    continue
                }
                $normalizedEvidence.Add([ordered]@{ path = $positionPath; line = $positionLine })
            }
            if ($normalizedEvidence.Count -eq 0) {
                $inconsistencies.Add($id + ' current judgment evidence missing')
            }
            $acceptance = if ($status -ceq 'accepted') {
                Get-ReviewerAcceptance -Acceptance (Get-ReviewerPropertyValue -Object $entry -Name 'acceptance') -FindingId $id -Label 'current_judgment' -Inconsistencies $inconsistencies
            }
            else {
                $null
            }
            $normalizedEntry = [pscustomobject]@{ id = $id; status = $status; severity = $severity; evidence = @($normalizedEvidence.ToArray()); acceptance = $acceptance }
            if ($currentJudgmentSeen.ContainsKey($id)) {
                $previousEntry = $currentJudgmentSeen[$id]
                if ((ConvertTo-Json -InputObject $previousEntry -Compress) -cne (ConvertTo-Json -InputObject $normalizedEntry -Compress)) {
                    $inconsistencies.Add($id + ' current judgment duplicate fields conflict')
                }
            }
            else {
                $currentJudgmentSeen[$id] = $normalizedEntry
            }
        }
    }

    foreach ($id in @($currentSeen.Keys)) {
        $current = $currentSeen[$id]
        $previous = if ($previousSeen.ContainsKey($id)) { $previousSeen[$id] } else { $null }
        if ($current.disposition -ceq 'carried' -and ($null -eq $previous -or $previous.status -notin @('open', 'accepted'))) {
            $inconsistencies.Add($id + ' carried finding must have previous open or accepted status')
        }
        if ($current.disposition -ceq 'carried' -and $null -ne $previous -and $current.severity -cne $previous.severity) {
            $inconsistencies.Add($id + ' carried finding severity conflicts with previous_status')
        }
        if ($current.disposition -ceq 'new' -and $null -ne $previous) {
            $inconsistencies.Add($id + ' new finding must not appear in previous_status')
        }
        if ($null -ne $previous -and $previous.status -in @('closed', 'withdrawn')) {
            $inconsistencies.Add($id + ' closed or withdrawn finding cannot be current')
        }
    }

    $judgmentBody = [ordered]@{ present = $false; entries = @(); errors = @() }
    if ($manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit) {
        $judgmentBody = Get-ReviewerBodyJudgment -Content $content
        foreach ($error in @($judgmentBody.errors)) {
            $inconsistencies.Add([string]$error)
        }
        $bodySeen = @{}
        foreach ($entry in @($judgmentBody.entries)) {
            $bodySeen[[string]$entry.id] = $entry
        }
        foreach ($id in @($currentJudgmentSeen.Keys)) {
            if (-not $bodySeen.ContainsKey($id)) {
                $inconsistencies.Add('current judgment missing from prose: ' + $id)
                continue
            }
            $manifestEntry = $currentJudgmentSeen[$id]
            $bodyEntry = $bodySeen[$id]
            if ($manifestEntry.status -cne $bodyEntry.status) { $inconsistencies.Add($id + ' current judgment prose status conflicts with manifest') }
            if ($manifestEntry.severity -cne $bodyEntry.severity) { $inconsistencies.Add($id + ' current judgment prose severity conflicts with manifest') }
            $manifestEvidence = @($manifestEntry.evidence)
            $bodyEvidence = @($bodyEntry.evidence)
            $evidenceMatches = $manifestEvidence.Count -eq $bodyEvidence.Count
            if ($evidenceMatches) {
                for ($index = 0; $index -lt $manifestEvidence.Count; $index++) {
                    $manifestPosition = $manifestEvidence[$index]
                    $bodyPosition = $bodyEvidence[$index]
                    $manifestPath = [string](Get-ReviewerPropertyValue -Object $manifestPosition -Name 'path')
                    $bodyPath = [string](Get-ReviewerPropertyValue -Object $bodyPosition -Name 'path')
                    $manifestLine = [int64](Get-ReviewerPropertyValue -Object $manifestPosition -Name 'line')
                    $bodyLine = [int64](Get-ReviewerPropertyValue -Object $bodyPosition -Name 'line')
                    if ($manifestPath -cne $bodyPath -or $manifestLine -ne $bodyLine) {
                        $evidenceMatches = $false
                        break
                    }
                }
            }
            if (-not $evidenceMatches) { $inconsistencies.Add($id + ' current judgment prose evidence conflicts with manifest') }

            $previousEntry = if ($previousSeen.ContainsKey($id)) { $previousSeen[$id] } else { $null }
            if ($null -ne $previousEntry -and $previousEntry.status -ceq 'accepted') {
                if ($manifestEntry.status -notin @('accepted', 'closed', 'open')) {
                    $inconsistencies.Add($id + ' accepted finding transition must remain accepted, close, or reopen')
                }
                if ($manifestEntry.status -ceq 'open') {
                    $currentFinding = if ($currentSeen.ContainsKey($id)) { $currentSeen[$id] } else { $null }
                    if ($null -eq $currentFinding -or $currentFinding.disposition -cne 'carried') {
                        $inconsistencies.Add($id + ' reopened accepted finding must be carried')
                    }
                    $reopenCondition = [string](Get-ReviewerPropertyValue -Object $previousEntry.acceptance -Name 'reopen_condition')
                    if ([string]::IsNullOrWhiteSpace($reopenCondition) -or $bodyEntry.reopen_condition -cne $reopenCondition) {
                        $inconsistencies.Add($id + ' reopening condition trigger missing or conflicts with previous acceptance')
                    }
                }
            }
        }
        foreach ($id in @($bodySeen.Keys)) {
            if (-not $currentJudgmentSeen.ContainsKey($id)) {
                $inconsistencies.Add('current judgment prose missing from manifest: ' + $id)
            }
        }

    }

    $previousProseEntries = @{}
    $previousProseMatches = [regex]::Matches($content, '(?ms)^##[ \t]+前輪 finding 狀態(?:[ \t]*（[^\r\n]*）)?[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
    if ($previousProseMatches.Count -gt 1) {
        $inconsistencies.Add(('previous prose section count={0}' -f $previousProseMatches.Count))
    }
    if ($previousProseMatches.Count -eq 1) {
        $previousHeadingLine = 1 + ([regex]::Matches($content.Substring(0, $previousProseMatches[0].Index), '\r?\n')).Count
        $previousSectionLineOffset = 1
        foreach ($line in [regex]::Split($previousProseMatches[0].Groups['section'].Value, '\r?\n')) {
            $previousEvidenceLine = $previousHeadingLine + $previousSectionLineOffset
            $previousSectionLineOffset++
            $idMatch = [regex]::Match($line, '\[(?<id>F-[0-9]{3}|T[0-9]{3}[A-Z]?)\]')
            if (-not $idMatch.Success) {
                continue
            }
            $id = $idMatch.Groups['id'].Value
            $statusMatch = [regex]::Match($line, '(?<status>已閉合|未閉合|撤回|已接受殘餘風險)')
            $severityMatch = [regex]::Match($line, '(?:\[(?<bracket>Critical|Major|Minor)\]|（(?<full>Critical|Major|Minor)）)')
            $status = $null
            if ($statusMatch.Success) {
                $status = switch ($statusMatch.Groups['status'].Value) {
                    '已閉合' { 'closed' }
                    '未閉合' { 'open' }
                    '撤回' { 'withdrawn' }
                    '已接受殘餘風險' { 'accepted' }
                }
            }
            $severity = $null
            if ($severityMatch.Success) {
                $severity = if (-not [string]::IsNullOrWhiteSpace($severityMatch.Groups['bracket'].Value)) { $severityMatch.Groups['bracket'].Value } else { $severityMatch.Groups['full'].Value }
            }
            if ($null -eq $status) {
                $inconsistencies.Add($id + ' previous prose status missing')
            }
            if ($null -eq $severity) {
                $inconsistencies.Add($id + ' previous prose severity missing')
            }
            $normalizedEntry = [pscustomobject]@{
                id = $id
                status = $status
                severity = $severity
                evidence = if ($null -ne $status -and $null -ne $severity) {
                    @([ordered]@{ path = $fullPath; line = $previousEvidenceLine })
                }
                else {
                    @()
                }
            }
            if ($previousProseEntries.ContainsKey($id)) {
                $previousProseEntry = $previousProseEntries[$id]
                if ($previousProseEntry.status -cne $status -or $previousProseEntry.severity -cne $severity) {
                    $inconsistencies.Add($id + ' previous prose duplicate fields conflict')
                }
            }
            else {
                $previousProseEntries[$id] = $normalizedEntry
            }
        }
    }
    if ($previousSeen.Count -gt 0 -and $previousProseMatches.Count -eq 0) {
        $inconsistencies.Add('missing previous prose section: 前輪 finding 狀態')
    }
    foreach ($id in @($previousSeen.Keys)) {
        if (-not $previousProseEntries.ContainsKey($id)) {
            $inconsistencies.Add('previous finding missing from prose: ' + $id)
            continue
        }
        $previous = $previousSeen[$id]
        $previousProse = $previousProseEntries[$id]
        if ($previousProse.status -cne $previous.status) {
            $inconsistencies.Add($id + ' previous prose status conflicts with previous_status')
        }
        if ($previousProse.severity -cne $previous.severity) {
            $inconsistencies.Add($id + ' previous prose severity conflicts with previous_status')
        }
    }
    foreach ($id in @($previousProseEntries.Keys)) {
        if (-not $previousSeen.ContainsKey($id)) {
            $inconsistencies.Add('previous prose finding missing from previous_status: ' + $id)
        }
    }

    if ($manifestSchema -ceq 'codex-dispatch.review-findings.v1' -and -not $currentJudgmentExplicit) {
        $currentJudgmentAdapter = $true
        foreach ($id in @($previousSeen.Keys)) {
            $previous = $previousSeen[$id]
            $proseEntry = if ($previousProseEntries.ContainsKey($id)) { $previousProseEntries[$id] } else { $null }
            $evidence = if ($null -ne $proseEntry) { @($proseEntry.evidence) } else { @([ordered]@{ path = $fullPath; line = 1 }) }
            $currentJudgmentSeen[$id] = [pscustomobject]@{
                id = $id
                status = $previous.status
                severity = $previous.severity
                evidence = @($evidence)
            }
        }
        foreach ($id in @($currentSeen.Keys)) {
            if ($currentJudgmentSeen.ContainsKey($id)) {
                continue
            }
            $current = $currentSeen[$id]
            $currentJudgmentSeen[$id] = [pscustomobject]@{
                id = $id
                status = 'open'
                severity = $current.severity
                evidence = @([ordered]@{ path = $fullPath; line = 1 })
            }
        }
    }

    $currentJudgmentActive = $manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit -or $currentJudgmentAdapter
    if ($currentJudgmentActive) {
        foreach ($id in @($previousSeen.Keys)) {
            if (-not $currentJudgmentSeen.ContainsKey($id)) {
                $inconsistencies.Add('previous finding missing from current_judgment: ' + $id)
            }
        }
        foreach ($id in @($currentSeen.Keys)) {
            if (-not $currentJudgmentSeen.ContainsKey($id)) {
                $inconsistencies.Add('current finding missing from current_judgment: ' + $id)
            }
        }
        foreach ($id in @($currentJudgmentSeen.Keys)) {
            if (-not $previousSeen.ContainsKey($id) -and -not $currentSeen.ContainsKey($id) -and $currentJudgmentSeen[$id].status -cne 'accepted') {
                $inconsistencies.Add('current_judgment finding missing from previous_status and current_findings: ' + $id)
            }
        }

        $judgmentOpenIds = @($currentJudgmentSeen.Values | Where-Object { $_.status -ceq 'open' } | ForEach-Object { [string]$_.id } | Sort-Object -Unique)
        $currentFindingIds = @($currentSeen.Keys | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        foreach ($id in $judgmentOpenIds) {
            if ($currentFindingIds -notcontains $id) {
                $inconsistencies.Add('current judgment open finding missing from current_findings: ' + $id)
            }
        }
        foreach ($id in $currentFindingIds) {
            if ($judgmentOpenIds -notcontains $id) {
                $inconsistencies.Add('current finding missing from current_judgment open status: ' + $id)
            }
        }
    }

    $proseIds = New-Object System.Collections.Generic.List[string]
    foreach ($heading in @('Standards', 'Standards 缺陷審查', '需求對照核對', 'Spec')) {
        $sectionMatches = [regex]::Matches($content, '(?ms)^##[ \t]+' + [regex]::Escape($heading) + '[ \t]*\r?\n(?<section>.*?)(?=^##[ \t]|\z)')
        if ($sectionMatches.Count -eq 0) {
            $inconsistencies.Add('missing current prose section: ' + $heading)
            continue
        }
        foreach ($sectionMatch in $sectionMatches) {
            foreach ($idMatch in [regex]::Matches($sectionMatch.Groups['section'].Value, '\[(?:F-[0-9]{3}|T[0-9]{3}[A-Z]?)\]')) {
                $proseIds.Add($idMatch.Value.Substring(1, $idMatch.Value.Length - 2))
            }
        }
    }

    $currentIdSet = @($currentSeen.Keys | Sort-Object)
    $proseIdSet = @($proseIds | Sort-Object -Unique)
    foreach ($id in $currentIdSet) {
        if ($proseIdSet -notcontains $id) { $inconsistencies.Add('current finding missing from prose: ' + $id) }
    }
    foreach ($id in $proseIdSet) {
        if ($currentIdSet -notcontains $id) { $inconsistencies.Add('prose finding missing from current_findings: ' + $id) }
    }

    $counts = Get-ReviewerPropertyValue -Object $manifest -Name 'counts'
    $declaredCounts = [ordered]@{}
    foreach ($name in @('previous_closed', 'previous_open', 'current_new', 'current_open')) {
        $declaredCounts[$name] = Get-ReviewerDeclaredCount -Counts $counts -Name $name -Inconsistencies $inconsistencies
    }
    $expectedCounts = [ordered]@{
        previous_closed = @($previousSeen.Values | Where-Object { $_.status -ceq 'closed' }).Count
        previous_open = @($previousSeen.Values | Where-Object { $_.status -ceq 'open' }).Count
        current_new = @($currentSeen.Values | Where-Object { $_.disposition -ceq 'new' }).Count
        current_open = $currentSeen.Count
    }
    if ($manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit -or $currentJudgmentAdapter) {
        $expectedCounts.current_closed = @($currentJudgmentSeen.Values | Where-Object { $_.status -ceq 'closed' }).Count
        $expectedCounts.current_withdrawn = @($currentJudgmentSeen.Values | Where-Object { $_.status -ceq 'withdrawn' }).Count
        $expectedCounts.previous_withdrawn = @($previousSeen.Values | Where-Object { $_.status -ceq 'withdrawn' }).Count
        $expectedCounts.previous_accepted = @($previousSeen.Values | Where-Object { $_.status -ceq 'accepted' }).Count
        $expectedCounts.current_accepted = @($currentJudgmentSeen.Values | Where-Object { $_.status -ceq 'accepted' }).Count
    }
    foreach ($name in $expectedCounts.Keys) {
        $declared = if ($null -eq $counts) { $null } else { $declaredCounts[$name] }
        if ($name -in @('previous_accepted', 'current_accepted') -and $null -ne $counts -and $null -eq $counts.PSObject.Properties[$name]) {
            $declared = [int64]0
            $declaredCounts[$name] = $declared
        }
        if ($null -eq $declared -and ($manifestSchema -ceq 'codex-dispatch.review-findings.v2' -or $currentJudgmentExplicit)) {
            $declared = Get-ReviewerDeclaredCount -Counts $counts -Name $name -Inconsistencies $inconsistencies
            $declaredCounts[$name] = $declared
        }
        if ($null -ne $declared -and [int64]$declared -ne [int64]$expectedCounts[$name]) {
            $inconsistencies.Add(('counts.{0} declared={1}; expected={2}' -f $name, $declaredCounts[$name], $expectedCounts[$name]))
        }
    }

    $conclusion = [string](Get-ReviewerPropertyValue -Object $manifest -Name 'conclusion')
    if ($conclusion -notin @('pass', 'fail')) {
        $inconsistencies.Add('conclusion must be pass or fail')
    }
    $judgmentEntriesForConclusion = if ($currentJudgmentActive) { @($currentJudgmentSeen.Values) } else { @($currentSeen.Values) }
    $expectedConclusion = if (@($judgmentEntriesForConclusion | Where-Object { $_.status -ceq 'open' -and $_.severity -in @('Critical', 'Major') }).Count -gt 0) { 'fail' } else { 'pass' }
    if ($conclusion -in @('pass', 'fail') -and $conclusion -cne $expectedConclusion) {
        $inconsistencies.Add(('conclusion declared={0}; expected={1}' -f $conclusion, $expectedConclusion))
    }

    $uniqueInconsistencies = @($inconsistencies | Sort-Object -Unique)
    return [ordered]@{
        reviewer_report_path = $fullPath
        reviewer_report_sha256 = Get-FileSha256 -Path $fullPath
        valid = $uniqueInconsistencies.Count -eq 0
        schema = $manifestSchema
        line_slug = if ([string]::IsNullOrWhiteSpace($manifestLineSlug)) { $null } else { $manifestLineSlug }
        dispatch_slug = if ([string]::IsNullOrWhiteSpace($manifestDispatchSlug)) { $null } else { $manifestDispatchSlug }
        round = $manifestRoundValue
        current_judgment_explicit = $currentJudgmentExplicit
        current_judgment_source = if ($currentJudgmentExplicit) { 'manifest' } elseif ($currentJudgmentAdapter) { 'v1-adapter' } else { $null }
        current_judgment = @($currentJudgmentSeen.Values)
        previous_status = @($previousSeen.Values)
        current_findings = @($currentSeen.Values)
        conclusion = if ($conclusion -in @('pass', 'fail')) { $conclusion } else { $null }
        current_finding_count = $currentSeen.Count
        previous_closed_count = $expectedCounts.previous_closed
        previous_open_count = $expectedCounts.previous_open
        previous_withdrawn_count = @($previousSeen.Values | Where-Object { $_.status -ceq 'withdrawn' }).Count
        previous_accepted_count = @($previousSeen.Values | Where-Object { $_.status -ceq 'accepted' }).Count
        current_new_count = $expectedCounts.current_new
        current_open_count = $expectedCounts.current_open
        current_closed_count = if ($expectedCounts.Contains('current_closed')) { $expectedCounts.current_closed } else { $null }
        current_withdrawn_count = if ($expectedCounts.Contains('current_withdrawn')) { $expectedCounts.current_withdrawn } else { $null }
        current_accepted_count = if ($expectedCounts.Contains('current_accepted')) { $expectedCounts.current_accepted } else { $null }
        error_code = $null
        duplicate_ids = @($duplicateIds | Sort-Object -Unique)
        inconsistencies = $uniqueInconsistencies
    }
}

function Throw-ReviewerEvidenceFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [AllowEmptyString()]
        [string]$Path = '',

        [long]$Size = -1,

        [long]$MaximumBytes = -1
    )

    $exception = New-Object System.InvalidOperationException(($Code + '：' + $Message))
    $exception.Data['errorCode'] = $Code
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $exception.Data['path'] = $Path
    }
    if ($Size -ge 0) {
        $exception.Data['size'] = $Size
    }
    if ($MaximumBytes -ge 0) {
        $exception.Data['maximumBytes'] = $MaximumBytes
    }
    throw $exception
}

function Resolve-ReviewerEvidencePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EvidencePath,

        [Parameter(Mandatory)]
        [string]$ReportPath,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot
    )

    if ([string]::IsNullOrWhiteSpace($EvidencePath) -or $EvidencePath.StartsWith('\\', [System.StringComparison]::Ordinal) -or $EvidencePath.StartsWith('//', [System.StringComparison]::Ordinal)) {
        Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message 'Reviewer evidence 不可為空或 UNC 路徑。' -Path $EvidencePath
    }

    try {
        if ([System.IO.Path]::IsPathRooted($EvidencePath)) {
            $resolvedEvidencePath = Resolve-AbsolutePath -Path $EvidencePath
        }
        else {
            $resolvedReportPath = Resolve-AbsolutePath -Path $ReportPath
            $resolvedEvidencePath = Resolve-AbsolutePath -Path (Join-Path (Split-Path -Parent $resolvedReportPath) $EvidencePath)
        }
    }
    catch {
        Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message ('Reviewer evidence 路徑無法解析：' + $_.Exception.Message) -Path $EvidencePath
    }

    $allowedRoots = New-Object System.Collections.Generic.List[string]
    foreach ($rootValue in @($SourceRoot, $ExecutionRoot)) {
        try {
            $resolvedRoot = Resolve-AbsolutePath -Path ([string]$rootValue)
        }
        catch {
            Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message ('Reviewer evidence root 無法解析：' + $_.Exception.Message) -Path $resolvedEvidencePath
        }
        if (-not ($allowedRoots -contains $resolvedRoot)) {
            $allowedRoots.Add($resolvedRoot)
        }
    }

    $matchingRoots = New-Object System.Collections.Generic.List[string]
    foreach ($rootValue in $allowedRoots.ToArray()) {
        if (Test-PathWithinRoot -Path $resolvedEvidencePath -Root $rootValue) {
            $matchingRoots.Add($rootValue)
        }
    }
    if ($matchingRoots.Count -eq 0) {
        Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message 'Reviewer evidence 必須位於 SourceRoot 或 ExecutionRoot 內。' -Path $resolvedEvidencePath
    }

    foreach ($rootValue in $matchingRoots.ToArray()) {
        if (-not (Test-Path -LiteralPath $rootValue -PathType Container)) {
            Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message 'Reviewer evidence root 不存在或不是目錄。' -Path $rootValue
        }

        $currentPath = $rootValue
        $rootItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message 'Reviewer evidence root 不可為 ReparsePoint。' -Path $currentPath
        }

        $relativePath = $resolvedEvidencePath.Substring($rootValue.Length).TrimStart([char[]]@('\', '/'))
        foreach ($part in @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $currentPath = Join-Path -Path $currentPath -ChildPath $part
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction SilentlyContinue
            if ($null -ne $item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message 'Reviewer evidence 路徑含 ReparsePoint。' -Path $currentPath
            }
        }
    }

    return $resolvedEvidencePath
}

function Get-ReviewerEvidenceSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot
    )

    $maximumBytes = 16MB
    $resolvedPath = Resolve-ReviewerEvidencePath -EvidencePath $Path -ReportPath $Path -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot
    $fileItem = Get-Item -LiteralPath $resolvedPath -Force -ErrorAction Stop
    if ($fileItem.PSIsContainer) {
        Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidencePathRejected' -Message 'Reviewer evidence 必須是檔案。' -Path $resolvedPath
    }
    if ([int64]$fileItem.Length -gt $maximumBytes) {
        Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidenceOversize' -Message ('Reviewer evidence 超過大小上限：size=' + [int64]$fileItem.Length + '; maximum=' + $maximumBytes) -Path $resolvedPath -Size ([int64]$fileItem.Length) -MaximumBytes $maximumBytes
    }

    $fileApiPath = ConvertTo-FileSystemApiPath -Path $resolvedPath
    $stream = $null
    $sha256 = $null
    try {
        $stream = [System.IO.File]::Open($fileApiPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        if ($stream.Length -gt $maximumBytes) {
            Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidenceOversize' -Message ('Reviewer evidence 超過大小上限：size=' + $stream.Length + '; maximum=' + $maximumBytes) -Path $resolvedPath -Size $stream.Length -MaximumBytes $maximumBytes
        }

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $buffer = New-Object byte[] 81920
        $totalBytes = 0L
        while ($true) {
            $remainingBytes = $maximumBytes - $totalBytes
            $readLimit = [int][Math]::Min([long]$buffer.Length, $remainingBytes + 1)
            $readCount = $stream.Read($buffer, 0, $readLimit)
            if ($readCount -eq 0) {
                break
            }

            $totalBytes += $readCount
            if ($totalBytes -gt $maximumBytes) {
                Throw-ReviewerEvidenceFailure -Code 'ReviewerEvidenceOversize' -Message ('Reviewer evidence 超過大小上限：size>' + $maximumBytes + '; maximum=' + $maximumBytes) -Path $resolvedPath -Size $totalBytes -MaximumBytes $maximumBytes
            }
            $null = $sha256.TransformBlock($buffer, 0, $readCount, $buffer, 0)
        }

        $null = $sha256.TransformFinalBlock([byte[]]@(), 0, 0)
        return ([System.BitConverter]::ToString($sha256.Hash)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $sha256) {
            $sha256.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-ReviewerLedgerHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Ledger
    )

    $canonical = [ordered]@{
        schema = [string]$Ledger.schema
        line_slug = [string]$Ledger.line_slug
        entries = @($Ledger.entries)
    }
    return Get-JsonSha256 -Value $canonical
}

function Write-ReviewerFindingLedger {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$ReviewerFindings
    )

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    $historyLineRoot = Join-Path (Join-Path $sourceRootPath '.local\ai-sessions\history') $LineSlug
    $ledgerPath = Join-Path $historyLineRoot 'review-finding-ledger.json'
    $null = New-DispatchOutputDirectory -Path $historyLineRoot -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot

    $existingLedger = $null
    $existingFileSha256 = $null
    if (Test-Path -LiteralPath $ledgerPath -PathType Leaf) {
        try {
            $existingLedger = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $ledgerPath)
        }
        catch {
            $exception = New-Object System.InvalidOperationException('LedgerConflict：finding ledger JSON 無法解析：' + $_.Exception.Message)
            $exception.Data['errorCode'] = 'LedgerConflict'
            $exception.Data['path'] = $ledgerPath
            throw $exception
        }
        if ($null -eq $existingLedger -or $existingLedger -isnot [pscustomobject] -or [string]$existingLedger.schema -cne 'codex-dispatch.review-finding-ledger.v1' -or [string]$existingLedger.line_slug -cne $LineSlug -or $null -eq $existingLedger.entries) {
            $exception = New-Object System.InvalidOperationException('LedgerConflict：finding ledger schema 或 line_slug 不一致。')
            $exception.Data['errorCode'] = 'LedgerConflict'
            $exception.Data['path'] = $ledgerPath
            throw $exception
        }
        $existingLedgerCanonical = [ordered]@{
            schema = [string]$existingLedger.schema
            line_slug = [string]$existingLedger.line_slug
            entries = @($existingLedger.entries)
        }
        $existingHash = Get-ReviewerLedgerHash -Ledger $existingLedgerCanonical
        if ([string]$existingLedger.ledger_sha256 -cne $existingHash) {
            $exception = New-Object System.InvalidOperationException('LedgerConflict：finding ledger SHA-256 不一致。')
            $exception.Data['errorCode'] = 'LedgerConflict'
            $exception.Data['path'] = $ledgerPath
            $exception.Data['expected_sha256'] = $existingHash
            $exception.Data['received_sha256'] = [string]$existingLedger.ledger_sha256
            throw $exception
        }
        $existingFileSha256 = Get-FileSha256 -Path $ledgerPath
    }

    $currentFindingById = @{}
    foreach ($finding in @($ReviewerFindings.current_findings)) {
        $currentFindingById[[string]$finding.id] = $finding
    }
    $previousById = @{}
    foreach ($finding in @($ReviewerFindings.previous_status)) {
        $previousById[[string]$finding.id] = $finding
    }

    $newEntries = New-Object System.Collections.Generic.List[object]
    $round = [int64]$ReviewerFindings.round
    foreach ($judgment in @($ReviewerFindings.current_judgment)) {
        $findingId = [string]$judgment.id
        $entryKey = $findingId + '/' + $round
        $existingEntry = $null
        if ($null -ne $existingLedger) {
            $existingMatches = @($existingLedger.entries | Where-Object { ([string]$_.finding_id + '/' + [int64]$_.round) -ceq $entryKey })
            if ($existingMatches.Count -gt 1) {
                $exception = New-Object System.InvalidOperationException('LedgerConflict：finding_id + round 出現重複：' + $entryKey)
                $exception.Data['errorCode'] = 'LedgerConflict'
                $exception.Data['path'] = $ledgerPath
                throw $exception
            }
            if ($existingMatches.Count -eq 1) { $existingEntry = $existingMatches[0] }
        }

        $currentFinding = if ($currentFindingById.ContainsKey($findingId)) { $currentFindingById[$findingId] } else { $null }
        $previousFinding = if ($previousById.ContainsKey($findingId)) { $previousById[$findingId] } else { $null }
        $axis = if ($null -ne $currentFinding) { [string](Get-ReviewerPropertyValue -Object $currentFinding -Name 'axis') } elseif ($null -ne $previousFinding) { [string](Get-ReviewerPropertyValue -Object $previousFinding -Name 'axis') } else { 'Unknown' }
        if ([string]::IsNullOrWhiteSpace($axis)) { $axis = 'Unknown' }
        $evidenceList = New-Object System.Collections.Generic.List[object]
        foreach ($position in @($judgment.evidence)) {
            $resolvedEvidencePath = Resolve-ReviewerEvidencePath -EvidencePath ([string]$position.path) -ReportPath ([string]$ReviewerFindings.reviewer_report_path) -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath
            if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
                throw ('Reviewer evidence 不存在：' + $resolvedEvidencePath)
            }
            $evidenceList.Add([ordered]@{
                    path = $resolvedEvidencePath
                    line = [int64]$position.line
                    sha256 = Get-ReviewerEvidenceSha256 -Path $resolvedEvidencePath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath
                })
        }
        $acceptance = Get-ReviewerPropertyValue -Object $judgment -Name 'acceptance'
        if ($null -eq $acceptance -and $null -ne $previousFinding -and $previousFinding.status -ceq 'accepted') {
            $acceptance = Get-ReviewerPropertyValue -Object $previousFinding -Name 'acceptance'
        }
        $ledgerAcceptance = $null
        if ($null -ne $acceptance) {
            $acceptanceEvidence = New-Object System.Collections.Generic.List[object]
            foreach ($position in @($acceptance.evidence)) {
                $resolvedEvidencePath = Resolve-ReviewerEvidencePath -EvidencePath ([string]$position.path) -ReportPath ([string]$ReviewerFindings.reviewer_report_path) -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath
                if (-not (Test-Path -LiteralPath $resolvedEvidencePath -PathType Leaf)) {
                    throw ('Reviewer acceptance evidence 不存在：' + $resolvedEvidencePath)
                }
                $acceptanceEvidence.Add([ordered]@{
                        path = $resolvedEvidencePath
                        line = [int64]$position.line
                        sha256 = Get-ReviewerEvidenceSha256 -Path $resolvedEvidencePath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath
                    })
            }
            $ledgerAcceptance = [ordered]@{
                decided_by = [string]$acceptance.decided_by
                scope = [string]$acceptance.scope
                evidence = @($acceptanceEvidence.ToArray())
                reopen_condition = [string]$acceptance.reopen_condition
            }
        }
        $entry = [ordered]@{
            finding_id = $findingId
            round = $round
            previous_status = if ($null -eq $previousFinding) { $null } else { [string]$previousFinding.status }
            current_judgment = [string]$judgment.status
            axis = $axis
            severity = [string]$judgment.severity
            source_report_path = [string]$ReviewerFindings.reviewer_report_path
            source_report_sha256 = [string]$ReviewerFindings.reviewer_report_sha256
            evidence = @($evidenceList.ToArray())
            acceptance = $ledgerAcceptance
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        if ($null -ne $existingEntry) {
            $existingComparable = [ordered]@{
                finding_id = [string]$existingEntry.finding_id
                round = [int64]$existingEntry.round
                previous_status = if ($null -eq $existingEntry.previous_status) { $null } else { [string]$existingEntry.previous_status }
                current_judgment = [string]$existingEntry.current_judgment
                axis = [string]$existingEntry.axis
                severity = [string]$existingEntry.severity
                source_report_path = [string]$existingEntry.source_report_path
                source_report_sha256 = [string]$existingEntry.source_report_sha256
                evidence = @($existingEntry.evidence)
                acceptance = Get-ReviewerPropertyValue -Object $existingEntry -Name 'acceptance'
            }
            $newComparable = [ordered]@{
                finding_id = [string]$entry.finding_id
                round = [int64]$entry.round
                previous_status = if ($null -eq $entry.previous_status) { $null } else { [string]$entry.previous_status }
                current_judgment = [string]$entry.current_judgment
                axis = [string]$entry.axis
                severity = [string]$entry.severity
                source_report_path = [string]$entry.source_report_path
                source_report_sha256 = [string]$entry.source_report_sha256
                evidence = @($entry.evidence)
                acceptance = $entry.acceptance
            }
            if ((ConvertTo-Json -InputObject $existingComparable -Depth 20 -Compress) -cne (ConvertTo-Json -InputObject $newComparable -Depth 20 -Compress)) {
                $exception = New-Object System.InvalidOperationException('LedgerConflict：既有 finding entry 與本輪資料不一致：' + $entryKey)
                $exception.Data['errorCode'] = 'LedgerConflict'
                $exception.Data['path'] = $ledgerPath
                throw $exception
            }
            continue
        }
        $newEntries.Add($entry)
    }

    $entries = New-Object System.Collections.Generic.List[object]
    if ($null -ne $existingLedger) {
        foreach ($entry in @($existingLedger.entries)) { $entries.Add($entry) }
    }
    foreach ($entry in @($newEntries.ToArray())) { $entries.Add($entry) }
    $ledger = [ordered]@{
        schema = 'codex-dispatch.review-finding-ledger.v1'
        line_slug = $LineSlug
        entries = @($entries.ToArray())
        ledger_sha256 = $null
    }
    $ledger.ledger_sha256 = Get-ReviewerLedgerHash -Ledger $ledger
    $writeArguments = @{
        Path = $ledgerPath
        Document = $ledger
        SourceRoot = $sourceRootPath
        ExecutionRoot = $executionRootPath
        TargetPath = @()
        HashProperty = ''
    }
    if ($null -ne $existingFileSha256) {
        $writeArguments.ExpectedExistingSha256 = $existingFileSha256
    }
    else {
        $writeArguments.RequireAbsent = $true
        $writeArguments.AbsentErrorCode = 'LedgerConflict'
    }
    try {
        $written = Write-DispatchAtomicJsonDocument @writeArguments
    }
    catch {
        $exception = $_.Exception
        try { $exception.Data['errorCode'] = 'LedgerConflict' } catch { }
        throw $exception
    }
    return [ordered]@{
        path = $written.Path
        sha256 = $written.Sha256
        entries_added = @($newEntries.ToArray())
        ledger = $ledger
    }
}

function Get-ReviewerFindingsForCollect {
    param(
        [string]$Path,
        [string]$SourceRoot,
        [string]$ExecutionRoot,
        [string]$LineSlug,
        [string]$DispatchSlug,
        [bool]$WriteLedger = $true
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $result = Test-ReviewerFindingReport -Path $Path
    $judgmentEntries = @($result.current_judgment)
    $openBlockingCount = @($judgmentEntries | Where-Object {
            $_.status -ceq 'open' -and $_.severity -in @('Critical', 'Major')
        }).Count
    $expectedConclusion = if ($openBlockingCount -gt 0) { 'fail' } else { 'pass' }
    if ($result.valid -and [string]$result.conclusion -cne $expectedConclusion) {
        $result.valid = $false
        $result.error_code = 'ReviewerConclusionMismatch'
        $result.inconsistencies = @(
            @($result.inconsistencies)
            ('manifest inconsistency: current_judgment open Critical/Major={0}; conclusion declared={1}; expected={2}' -f $openBlockingCount, [string]$result.conclusion, $expectedConclusion)
        )
    }
    if ($result.valid -and $WriteLedger -and -not [string]::IsNullOrWhiteSpace($SourceRoot) -and -not [string]::IsNullOrWhiteSpace($ExecutionRoot) -and -not [string]::IsNullOrWhiteSpace($LineSlug) -and -not [string]::IsNullOrWhiteSpace($DispatchSlug)) {
        $result.ledger = Write-ReviewerFindingLedger -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -ReviewerFindings $result
    }
    return $result
}

function Throw-ReviewerFindingCollectFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Result
    )

    $reviewerFindings = $Result['reviewerFindings']
    $Result['outputValid'] = $false
    $errorCode = [string](Get-ReviewerPropertyValue -Object $reviewerFindings -Name 'error_code')
    if ([string]::IsNullOrWhiteSpace($errorCode)) { $errorCode = 'ReviewerManifestInvalid' }
    $Result['errorCode'] = $errorCode
    $message = 'Reviewer report 結構無效，Collect 拒絕回收：' + $errorCode + '：' + ([string]::Join('; ', @($reviewerFindings.inconsistencies)))
    $operationException = New-Object System.Exception($message)
    $operationException = Write-DispatchOperationFailureResult -Exception $operationException -Result $Result
    throw $operationException
}
