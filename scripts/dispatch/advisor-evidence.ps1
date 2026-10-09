function New-DispatchPrompt {
    param(
        [Parameter(Mandatory)]
        [string]$PromptPath,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [string]$Timestamp,

        [string[]]$Directive,

        [string]$OutputPath
    )

    $targetPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        if ($null -eq $Directive -or $Directive.Count -eq 0) {
            return $PromptPath
        }
        Join-Path -Path $HistoryRoot -ChildPath ('codex-prompt-' + $Timestamp + '.md')
    }
    else {
        Resolve-AbsolutePath -Path $OutputPath
    }

    $promptContent = Read-DispatchUtf8Text -Path $PromptPath
    if ($null -ne $Directive -and $Directive.Count -gt 0) {
        $suffix = "

" + ($Directive -join "

") + "
"
        $promptContent = $promptContent + $suffix
    }

    $context = Get-DispatchOutputPathContext
    $targetPath = Resolve-DispatchOutputPath `
        -CandidatePath $targetPath `
        -SourceRoot $context.SourceRoot `
        -ExecutionRoot $context.ExecutionRoot `
        -TargetPath $context.TargetPath
    $parent = Split-Path -Parent $targetPath
    $null = New-DispatchOutputDirectory -Path $parent -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $targetPath = Resolve-DispatchOutputPath `
        -CandidatePath $targetPath `
        -SourceRoot $context.SourceRoot `
        -ExecutionRoot $context.ExecutionRoot `
        -TargetPath $context.TargetPath
    $lock = $null
    $temporaryPath = $null
    try {
        $lock = Open-DispatchResultLock -ResolvedPath $targetPath
        if (Test-Path -LiteralPath $targetPath) {
            $collision = New-Object System.InvalidOperationException(('PromptTransferCollision：衍生 prompt 目標已存在，拒絕覆寫：' + $targetPath))
            $collision.Data['errorCode'] = 'PromptTransferCollision'
            $collision.Data['path'] = $targetPath
            throw $collision
        }
        $temporaryPath = Join-Path -Path $parent -ChildPath ([guid]::NewGuid().ToString('D') + '.prompt.tmp')
        Write-Utf8NoBom -Path $temporaryPath -Content $promptContent -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
        $temporaryPath = Resolve-DispatchOutputPath `
            -CandidatePath $temporaryPath `
            -SourceRoot $context.SourceRoot `
            -ExecutionRoot $context.ExecutionRoot `
            -TargetPath $context.TargetPath
        $targetPath = Resolve-DispatchOutputPath `
            -CandidatePath $targetPath `
            -SourceRoot $context.SourceRoot `
            -ExecutionRoot $context.ExecutionRoot `
            -TargetPath $context.TargetPath
        [System.IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $targetPath))
    }
    catch {
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if ($null -ne $lock -and $null -ne $lock.Stream) {
            $lock.Stream.Dispose()
        }
    }

    return $targetPath
}

function Copy-DispatchPromptToExecutionHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PromptPath,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$HistoryRoot,

        [Parameter(Mandatory)]
        [string]$Timestamp
    )

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    $sourcePath = Resolve-AbsolutePath -Path $PromptPath
    if (-not (Test-PathWithinRoot -Path $sourcePath -Root $sourceRootPath) -and -not (Test-PathWithinRoot -Path $sourcePath -Root $executionRootPath)) {
        $exception = New-Object System.InvalidOperationException(('PromptSourceBoundary：Prompt 必須位於 sourceRoot 或 executionRoot 內；received=' + $sourcePath + '; sourceRoot=' + $sourceRootPath + '; executionRoot=' + $executionRootPath))
        $exception.Data['errorCode'] = 'PromptSourceBoundary'
        $exception.Data['receivedPath'] = $sourcePath
        $exception.Data['sourceRoot'] = $sourceRootPath
        $exception.Data['executionRoot'] = $executionRootPath
        throw $exception
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        $exception = New-Object System.InvalidOperationException(('PromptSourceMissing：找不到 sourceRoot 內的 Prompt：' + $sourcePath))
        $exception.Data['errorCode'] = 'PromptSourceMissing'
        $exception.Data['path'] = $sourcePath
        throw $exception
    }

    $historyPath = Resolve-AbsolutePath -Path $HistoryRoot
    $destinationPath = Join-Path -Path $historyPath -ChildPath ('codex-prompt-source-' + $Timestamp + '.md')
    $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @()
    $sourceApiPath = ConvertTo-FileSystemApiPath -Path $sourcePath
    $sourceBytes = [System.IO.File]::ReadAllBytes($sourceApiPath)
    $sourceSha256 = Get-DispatchByteArraySha256 -Bytes $sourceBytes
    $parent = Split-Path -Parent $destinationPath
    $null = New-DispatchOutputDirectory -Path $parent -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath
    $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @()
    $lock = $null
    $temporaryPath = $null
    try {
        $lock = Open-DispatchResultLock -ResolvedPath $destinationPath
        if (Test-Path -LiteralPath $destinationPath) {
            $collision = New-Object System.InvalidOperationException(('PromptTransferCollision：Prompt 搬移目標已存在，拒絕覆寫：' + $destinationPath))
            $collision.Data['errorCode'] = 'PromptTransferCollision'
            $collision.Data['path'] = $destinationPath
            throw $collision
        }
        $temporaryPath = Join-Path -Path $parent -ChildPath ([guid]::NewGuid().ToString('D') + '.prompt.tmp')
        $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @()
        [System.IO.File]::WriteAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath), $sourceBytes)
        $temporarySha256 = Get-DispatchByteArraySha256 -Bytes ([System.IO.File]::ReadAllBytes((ConvertTo-FileSystemApiPath -Path $temporaryPath)))
        if (-not [string]::Equals($temporarySha256, $sourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $exception = New-Object System.InvalidOperationException(('PromptTransferHashMismatch：暫存 Prompt SHA-256 不一致；path=' + $sourcePath))
            $exception.Data['errorCode'] = 'PromptTransferHashMismatch'
            throw $exception
        }
        $sourceSha256AfterRead = Get-FileSha256 -Path $sourcePath
        if (-not [string]::Equals($sourceSha256AfterRead, $sourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $exception = New-Object System.InvalidOperationException(('PromptTransferSourceChanged：Prompt 在搬移期間變更；path=' + $sourcePath))
            $exception.Data['errorCode'] = 'PromptTransferSourceChanged'
            throw $exception
        }
        $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @()
        $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @()
        $destinationApiPath = ConvertTo-FileSystemApiPath -Path $destinationPath
        [System.IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), $destinationApiPath)
        $destinationSha256 = Get-FileSha256 -Path $destinationPath
        if (-not [string]::Equals($destinationSha256, $sourceSha256, [StringComparison]::OrdinalIgnoreCase)) {
            $exception = New-Object System.InvalidOperationException(('PromptTransferHashMismatch：搬移後 Prompt SHA-256 不一致；path=' + $destinationPath))
            $exception.Data['errorCode'] = 'PromptTransferHashMismatch'
            throw $exception
        }
    }
    catch {
        if ($null -ne $temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if ($null -ne $lock -and $null -ne $lock.Stream) {
            $lock.Stream.Dispose()
        }
    }

    return [pscustomobject]@{
        SourcePath = $sourcePath
        Path = $destinationPath
        SourceSha256 = $sourceSha256
        DestinationSha256 = $destinationSha256
    }
}

function Read-DispatchUtf8Text {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $primaryReadError = $null
    $contentBytes = $null
    try {
        $contentBytes = Read-DispatchSharedBytes -Path (ConvertTo-FileSystemApiPath -Path $resolvedPath)
    }
    catch {
        $primaryReadError = $_.Exception
        try {
            $contentBytes = Read-DispatchSharedBytes -Path $resolvedPath
        }
        catch {
            try {
                $content = [string](Get-Content -LiteralPath $resolvedPath -Raw -Encoding UTF8)
                if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
                    return $content.Substring(1)
                }
                return $content
            }
            catch {
                throw $primaryReadError
            }
        }
    }
    $content = $encoding.GetString($contentBytes)
    if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) {
        return $content.Substring(1)
    }
    return $content
}

function Assert-AdvisorContract {
    param(
        [Parameter(Mandatory)]
        [string]$RequestedProfile,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$DispatchKind,

        [Parameter(Mandatory)]
        [string]$WriteMode
    )

    if ($RequestedProfile -eq 'advisor' -and $TaskType -ne 'advisor-consult') {
        throw 'AdvisorImplementationProfileRejected：Profile=advisor 只允許 TaskType=advisor-consult。'
    }
    if ($RequestedProfile -eq 'advisor' -and $DispatchKind -eq 'workflow') {
        throw 'AdvisorImplementationProfileRejected：Profile=advisor 不允許 workflow 派遣。'
    }
    if ($RequestedProfile -eq 'advisor' -and $WriteMode -ne 'readonly') {
        throw 'AdvisorImplementationProfileRejected：Profile=advisor 必須使用 readonly 派遣。'
    }
    if ($TaskType -eq 'advisor-consult' -and $RequestedProfile -ne 'advisor') {
        throw 'AdvisorProfileRequired：TaskType=advisor-consult 必須使用 Profile=advisor。'
    }
}

function Get-AdvisorConsultReportPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $fullPath = Resolve-DispatchOutputPath -CandidatePath $Path -SourceRoot '' -ExecutionRoot $ExecutionRoot -TargetPath @()
    $reportRoot = Join-Path -Path (Resolve-AbsolutePath -Path $ExecutionRoot) -ChildPath ('.local\ai-sessions\report\' + $LineSlug)
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $reportRoot)) {
        throw "AdvisorConsultReportPath 必須位於同線 report root 內：$fullPath"
    }
    $expectedName = 'advisor-consult-' + $DispatchSlug + '.md'
    if (-not [string]::Equals([System.IO.Path]::GetFileName($fullPath), $expectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "AdvisorConsultReportPath 檔名必須為 $expectedName：$fullPath"
    }
    return $fullPath
}

function Get-AdvisorEvidenceQuestionUnits {
    param(
        [Parameter(Mandatory)]
        [string]$QuestionSection
    )

    $questionMatches = [regex]::Matches($QuestionSection, '(?m)^\s*(?<id>question-[A-Za-z0-9][A-Za-z0-9_-]*):\s*(?<value>.*?)\s*$')
    if ($questionMatches.Count -eq 0) {
        throw 'EvidencePackInvalid：evidence pack 待答問題必須至少包含一個 question-<id>。'
    }
    $questionUnits = New-Object System.Collections.Generic.List[string]
    $questionIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($questionMatch in $questionMatches) {
        $questionId = $questionMatch.Groups['id'].Value.Trim()
        $questionValue = $questionMatch.Groups['value'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($questionValue)) {
            throw "EvidencePackInvalid：問題 $questionId 不可為空。"
        }
        if (-not $questionIds.Add($questionId)) {
            throw "EvidencePackInvalid：問題 ID 不可重複：$questionId"
        }
        $questionUnits.Add($questionId)
    }
    return @($questionUnits.ToArray())
}

function Test-AdvisorEvidencePack {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $ExecutionRoot)) {
        throw "evidence pack 必須位於 executionRoot 內：$fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "找不到 evidence pack：$fullPath"
    }
    $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "evidence pack 不可為空：$fullPath"
    }
    foreach ($requiredPattern in @(
            '(?m)^schema:\s*advisor-consult\.evidence\.v1\s*$',
            '(?m)^line-slug:\s*' + [regex]::Escape($LineSlug) + '\s*$',
            '(?m)^dispatch-slug:\s*' + [regex]::Escape($DispatchSlug) + '\s*$',
            '(?m)^##\s+目標段落\s*$',
            '(?m)^##\s+已知結論\s*$',
            '(?m)^##\s+待答問題\s*$',
            '(?m)^##\s+可能反證\s*$',
            '(?m)^##\s+邊界\s*$',
            '(?m)^-\s+allowed-input:\s*this evidence pack only',
            '(?m)^-\s+forbidden-action:\s*source exploration, repository scan, file mutation, external dispatch'
        )) {
        if (-not [regex]::IsMatch($content, $requiredPattern)) {
            throw "evidence pack 缺少必要內容：$requiredPattern"
        }
    }

    $sectionBodies = [ordered]@{}
    foreach ($sectionName in @('目標段落', '已知結論', '待答問題', '可能反證', '邊界')) {
        $sectionMatch = [regex]::Match($content, '(?ms)^##\s+' + [regex]::Escape($sectionName) + '\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
        if (-not $sectionMatch.Success -or [string]::IsNullOrWhiteSpace($sectionMatch.Groups['body'].Value)) {
            throw "evidence pack 必要區段不可為空：$sectionName"
        }
        $sectionBodies[$sectionName] = $sectionMatch.Groups['body'].Value.Trim()
    }
    if ($sectionBodies['目標段落'] -notmatch '(?m)^\s*source:\s*\S+' -or
        $sectionBodies['目標段落'] -notmatch '(?m)^\s*excerpt:\s*\S+') {
        throw 'evidence pack 目標段落必須包含非空 source 與 excerpt。'
    }
    $questionUnits = @(Get-AdvisorEvidenceQuestionUnits -QuestionSection $sectionBodies['待答問題'])

    $requiredOutputMatches = [regex]::Matches($sectionBodies['待答問題'], '(?m)^[ \t]*required-output:[ \t]*(?<value>[^\r\n]*?)[ \t]*\r?$')
    if ($requiredOutputMatches.Count -ne 1) {
        throw 'C25 EvidencePackRequiredOutputInvalid：required-output 必須恰好宣告一次。'
    }
    $questionSectionLines = @($sectionBodies['待答問題'] -split '\r?\n')
    for ($lineIndex = 0; $lineIndex -lt $questionSectionLines.Count; $lineIndex++) {
        if ($questionSectionLines[$lineIndex] -notmatch '^\s*required-output:\s*') {
            continue
        }
        if ($lineIndex + 1 -ge $questionSectionLines.Count) {
            continue
        }
        $nextLine = $questionSectionLines[$lineIndex + 1]
        if ([string]::IsNullOrWhiteSpace($nextLine) -or
            $nextLine -match '^\s*question-[A-Za-z0-9][A-Za-z0-9_-]*:\s*' -or
            $nextLine -match '^\s*output-rules:\s*' -or
            $nextLine -match '^\s*##\s+') {
            continue
        }
        throw 'C25 EvidencePackRequiredOutputInvalid：required-output 宣告後不可出現未標記的續行。'
    }
    $requiredOutputValue = $requiredOutputMatches[0].Groups['value'].Value.Trim()
    $requiredOutput = @($requiredOutputValue.Split(';') | ForEach-Object { $_.Trim() })
    if ([string]::IsNullOrWhiteSpace($requiredOutputValue) -or $requiredOutput.Count -eq 0 -or @($requiredOutput | Where-Object { $_ -notmatch '^#{1,6}[ \t]+\S' }).Count -gt 0) {
        throw 'C25 EvidencePackRequiredOutputInvalid：required-output 必須由半形分號分隔的非空 Markdown heading 組成。'
    }
    $requiredOutputSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($heading in $requiredOutput) {
        if (-not $requiredOutputSet.Add($heading)) {
            throw "C25 EvidencePackRequiredOutputInvalid：required-output 不可重複：$heading"
        }
    }
    if ($sectionBodies['待答問題'] -notmatch '(?m)^\s*output-rules:\s*\S+') {
        throw 'C25 EvidencePackRequiredOutputInvalid：待答問題必須包含非空 output-rules。'
    }

    $hash = Get-FileSha256 -Path $fullPath
    $sandboxRoot = Join-Path -Path $ExecutionRoot -ChildPath ('.local\ai-sessions\scratch\advisor-consult\' + $DispatchSlug)
    $sandboxPath = Resolve-DispatchOutputPath -CandidatePath (Join-Path -Path $sandboxRoot -ChildPath 'evidence-pack.md') -SourceRoot '' -ExecutionRoot $ExecutionRoot -TargetPath @()
    if (-not [string]::Equals($fullPath, (Resolve-AbsolutePath -Path $sandboxPath), [System.StringComparison]::OrdinalIgnoreCase)) {
        $null = New-DispatchOutputDirectory -Path $sandboxRoot -SourceRoot '' -ExecutionRoot $ExecutionRoot
        $sandboxPath = Resolve-DispatchOutputPath -CandidatePath $sandboxPath -SourceRoot '' -ExecutionRoot $ExecutionRoot -TargetPath @()
        Copy-Item -LiteralPath $fullPath -Destination $sandboxPath -Force
    }

    return [ordered]@{
        path        = $fullPath
        sandboxPath = Resolve-AbsolutePath -Path $sandboxPath
        sha256      = $hash
        length      = [int64](Get-Item -LiteralPath $fullPath).Length
        content     = $content
        required_output = $requiredOutput
        requiredOutput = $requiredOutput
        question_units  = @($questionUnits)
    }
}

function Get-ThreadIdsFromEventStream {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $ids = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }
        if ((Get-OptionalObjectProperty -Object $event -Name 'type') -ne 'thread.started') {
            continue
        }
        $threadId = Get-OptionalObjectProperty -Object $event -Name 'thread_id'
        if ($threadId -is [string] -and -not [string]::IsNullOrWhiteSpace($threadId)) {
            $parsedThreadId = [guid]::Empty
            if (-not [guid]::TryParse($threadId, [ref]$parsedThreadId)) {
                throw "事件流 thread.started.thread_id 必須為 UUID：$threadId"
            }
            $ids.Add($threadId)
        }
    }
    return @($ids.ToArray())
}

function Set-ThreadIdFromEventStream {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ThreadPath,

        [switch]$RequireThreadId
    )

    $threadPathValue = Resolve-DispatchOutputPathFromContext -CandidatePath $ThreadPath
    $eventIds = @(Get-ThreadIdsFromEventStream -Path $EventPath)
    $existingId = ''
    if (Test-Path -LiteralPath $threadPathValue -PathType Leaf) {
        $existingId = (Get-Content -LiteralPath $threadPathValue -Raw -Encoding UTF8).Trim()
        if (-not [string]::IsNullOrWhiteSpace($existingId)) {
            $parsedExistingId = [guid]::Empty
            if (-not [guid]::TryParse($existingId, [ref]$parsedExistingId)) {
                throw "既有 thread id 檔案內容必須為 UUID：$existingId"
            }
        }
    }
    $distinctIds = @($eventIds | Sort-Object -Unique)
    if ($distinctIds.Count -gt 1) {
        throw "事件流包含不同 thread id：$($distinctIds -join ',')"
    }
    if ($distinctIds.Count -eq 0) {
        if ($RequireThreadId) {
            throw 'thread.started.thread_id 尚未取得。'
        }
        return [ordered]@{
            threadId         = $existingId
            existingThreadId = $existingId
            relayed          = $false
            ready            = $false
            eventObserved    = $false
            source           = 'existing-or-not-ready'
        }
    }
    $eventId = $distinctIds[0]
    if (-not [string]::IsNullOrWhiteSpace($existingId) -and $existingId -ne $eventId) {
        throw "thread id 衝突：既有=$existingId；事件流=$eventId"
    }
    if ([string]::IsNullOrWhiteSpace($existingId)) {
        $threadPathValue = Resolve-DispatchOutputPathFromContext -CandidatePath $threadPathValue
        Write-Utf8NoBom -Path $threadPathValue -Content ($eventId + "
") -SourceRoot ([string](Get-DispatchScriptVariableValue -Name 'SourceRoot')) -ExecutionRoot ([string](Get-DispatchScriptVariableValue -Name 'ExecutionRoot')) -TargetPath @((Get-DispatchScriptVariableValue -Name 'TargetPath'))
        return [ordered]@{
            threadId         = $eventId
            existingThreadId = ''
            relayed          = $true
            ready            = $true
            eventObserved    = $true
            source           = 'thread.started'
        }
    }
    return [ordered]@{
        threadId         = $existingId
        existingThreadId = $existingId
        relayed          = $false
        ready            = $true
        eventObserved    = $true
        source           = 'existing'
    }
}

function Add-ThreadRelayDiagnostics {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Relay,

        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ThreadPath,

        [Parameter(Mandatory)]
        [DateTimeOffset]$StartedAt,

        [Parameter(Mandatory)]
        [DateTimeOffset]$DeadlineAt,

        [Parameter(Mandatory)]
        [int]$AttemptCount,

        [Parameter(Mandatory)]
        [bool]$TerminalEventObserved
    )

    $result = [ordered]@{}
    if ($Relay -is [System.Collections.IDictionary]) {
        foreach ($key in $Relay.Keys) {
            $result[[string]$key] = $Relay[$key]
        }
    }
    elseif ($null -ne $Relay) {
        foreach ($property in $Relay.PSObject.Properties) {
            $result[[string]$property.Name] = $property.Value
        }
    }
    $eventBytes = 0L
    if (Test-Path -LiteralPath $EventPath -PathType Leaf) {
        $eventBytes = [int64](Get-Item -LiteralPath $EventPath).Length
    }
    $observedAt = if ($eventBytes -gt 0) { [DateTimeOffset]::UtcNow.ToString('o') } else { $null }
    $result['relay_diagnostics'] = [ordered]@{
        launch_started_at_utc = $StartedAt.ToString('o')
        deadline_at_utc = $DeadlineAt.ToString('o')
        observed_at_utc = $observedAt
        event_path = $EventPath
        thread_path = $ThreadPath
        event_bytes = $eventBytes
        attempt_count = $AttemptCount
        ready = [bool](Get-DispatchJsonProperty -Object $Relay -Name 'ready')
        timed_out = [bool](Get-DispatchJsonProperty -Object $Relay -Name 'timedOut')
        terminal_event_observed = $TerminalEventObserved
    }
    return $result
}

function Wait-ForThreadRelay {
    param(
        [Parameter(Mandatory)]
        [string]$EventPath,

        [Parameter(Mandatory)]
        [string]$ThreadPath,

        [int]$TimeoutSeconds = 5
    )

    $startedAt = [DateTimeOffset]::UtcNow
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $attemptCount = 0
    $terminalEventObserved = $false
    do {
        $attemptCount++
        $relay = Set-ThreadIdFromEventStream -EventPath $EventPath -ThreadPath $ThreadPath
        if ([bool](Get-DispatchJsonProperty -Object $relay -Name 'ready')) {
            return Add-ThreadRelayDiagnostics -Relay $relay -EventPath $EventPath -ThreadPath $ThreadPath -StartedAt $startedAt -DeadlineAt $deadline -AttemptCount $attemptCount -TerminalEventObserved $terminalEventObserved
        }
        if (Test-Path -LiteralPath $EventPath -PathType Leaf) {
            $eventContent = Get-Content -LiteralPath $EventPath -Raw -Encoding UTF8
            if ($eventContent -match '(?m)"type"\s*:\s*"turn\.(completed|failed)"') {
                $terminalEventObserved = $true
                break
            }
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $attemptCount++
    $finalRelay = Set-ThreadIdFromEventStream -EventPath $EventPath -ThreadPath $ThreadPath
    if ([bool](Get-DispatchJsonProperty -Object $finalRelay -Name 'ready')) {
        return Add-ThreadRelayDiagnostics -Relay $finalRelay -EventPath $EventPath -ThreadPath $ThreadPath -StartedAt $startedAt -DeadlineAt $deadline -AttemptCount $attemptCount -TerminalEventObserved $terminalEventObserved
    }
    $notReady = [ordered]@{
        threadId         = ''
        existingThreadId = [string](Get-DispatchJsonProperty -Object $finalRelay -Name 'existingThreadId')
        relayed          = $false
        ready            = $false
        eventObserved    = $false
        source           = 'not-ready'
        timedOut         = $true
        timeoutSeconds   = $TimeoutSeconds
    }
    return Add-ThreadRelayDiagnostics -Relay $notReady -EventPath $EventPath -ThreadPath $ThreadPath -StartedAt $startedAt -DeadlineAt $deadline -AttemptCount $attemptCount -TerminalEventObserved $terminalEventObserved
}

function ConvertTo-DispatchTimestamp {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $null
    }
    $parsed = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $null
    }
    return $parsed.ToUniversalTime()
}

function Protect-MarkdownFencedCodeHeadings {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Message
    )

    $messageLines = [string]$Message -split '\r?\n'
    $protectedMessageLines = New-Object System.Collections.Generic.List[string]
    $activeFenceCharacter = ''
    $activeFenceLength = 0
    foreach ($line in $messageLines) {
        if ([string]::IsNullOrEmpty($activeFenceCharacter)) {
            $openingFencePattern = '^[ \t]{0,3}(?<fence>' + [regex]::Escape([string][char]96) + '{3,}|~{3,})'
            $openingFenceMatch = [regex]::Match($line, $openingFencePattern)
            if ($openingFenceMatch.Success) {
                $activeFenceCharacter = $openingFenceMatch.Groups['fence'].Value.Substring(0, 1)
                $activeFenceLength = $openingFenceMatch.Groups['fence'].Value.Length
            }
            $protectedMessageLines.Add($line)
            continue
        }

        $closingFencePattern = '^[ \t]{0,3}' + [regex]::Escape($activeFenceCharacter) + '{' + $activeFenceLength + ',}[ \t]*$'
        if ([regex]::IsMatch($line, $closingFencePattern)) {
            $activeFenceCharacter = ''
            $activeFenceLength = 0
            $protectedMessageLines.Add($line)
            continue
        }

        if ($line -match '^[ \t]{0,3}#{1,6}[ \t]+') {
            $protectedMessageLines.Add('fenced code content ' + $line)
            continue
        }

        $protectedMessageLines.Add($line)
    }

    return ($protectedMessageLines -join [Environment]::NewLine)
}

function Test-RequiredOutputSections {
    param(
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [object[]]$RequiredOutput
    )

    $required = @($RequiredOutput | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $present = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    $duplicates = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[object]
    $sectionMatchingMessage = Protect-MarkdownFencedCodeHeadings -Message $Message
    foreach ($heading in $required) {
        $headingMatch = [regex]::Match($heading, '^(?<level>#{1,6})[ \t]+')
        $headingLevel = 6
        if ($headingMatch.Success) {
            $headingLevel = $headingMatch.Groups['level'].Value.Length
        }
        $bodyTerminator = '^#{1,' + $headingLevel + '}[ \t]+'
        $pattern = '(?ms)^' + [regex]::Escape($heading) + '[ \t]*\r?\n(?<body>.*?)(?=' + $bodyTerminator + '|\z)'
        $matches = [regex]::Matches($sectionMatchingMessage, $pattern)
        if ($matches.Count -eq 0) {
            $missing.Add($heading)
            $details.Add([ordered]@{ heading = $heading; present = $false; body_non_empty = $false })
            continue
        }
        if ($matches.Count -gt 1) { $duplicates.Add($heading) }
        $body = $matches[0].Groups['body'].Value.Trim()
        $present.Add($heading)
        $details.Add([ordered]@{ heading = $heading; present = $true; body_non_empty = -not [string]::IsNullOrWhiteSpace($body) })
        if ([string]::IsNullOrWhiteSpace($body)) { $missing.Add($heading) }
    }
    return [ordered]@{
        valid = $missing.Count -eq 0 -and $duplicates.Count -eq 0
        required = @($required)
        present = @($present.ToArray())
        missing = @($missing.ToArray() | Sort-Object -Unique)
        duplicate = @($duplicates.ToArray() | Sort-Object -Unique)
        sections = @($details.ToArray())
    }
}

function New-AdvisorInlineEvidenceDirective {
    param(
        [Parameter(Mandatory)]
        [psobject]$EvidencePackInfo
    )

    $content = [string]$EvidencePackInfo.content
    $contentWithLineBreak = $content
    if (-not $contentWithLineBreak.EndsWith("
", [StringComparison]::Ordinal)) {
        $contentWithLineBreak += "`r`n"
    }
    return ('[advisor evidence-only]' + "`r`n" +
        'evidence-pack-sha256=' + [string]$EvidencePackInfo.sha256 + "`r`n" +
        'evidence-pack-length=' + [string]$EvidencePackInfo.length + "`r`n" +
        '---BEGIN INLINE EVIDENCE PACK---' + "`r`n" +
        $contentWithLineBreak +
        '---END INLINE EVIDENCE PACK---' + "`r`n" +
        '執行端只能依上述 inline evidence pack 回答。禁止 repository 探索、檔案掃描、檔案變更與外部派遣。')
}

function Test-AdvisorInlineEvidenceDirective {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$PromptContent,

        [Parameter(Mandatory)]
        [psobject]$EvidencePackInfo
    )

    $content = [string]$EvidencePackInfo.content
    $hashMarker = 'evidence-pack-sha256=' + [string]$EvidencePackInfo.sha256
    $lengthMarker = 'evidence-pack-length=' + [string]$EvidencePackInfo.length
    $beginMarker = '---BEGIN INLINE EVIDENCE PACK---'
    $endMarker = '---END INLINE EVIDENCE PACK---'
    $hasMarkers = $PromptContent.Contains('[advisor evidence-only]') -and
        $PromptContent.Contains($hashMarker) -and
        $PromptContent.Contains($lengthMarker) -and
        $PromptContent.Contains($beginMarker) -and
        $PromptContent.Contains($endMarker)
    $hasFullContent = $PromptContent.Contains($content)
    return [ordered]@{
        valid = $hasMarkers -and $hasFullContent
        has_markers = $hasMarkers
        has_full_content = $hasFullContent
        expected_sha256 = [string]$EvidencePackInfo.sha256
        expected_length = [int64]$EvidencePackInfo.length
        reason = if ($hasMarkers -and $hasFullContent) { $null } else { 'prompt 缺少完整 evidence pack、hash、length 或 inline marker。' }
    }
}

function Get-AdvisorCompletionPartition {
    param(
        [AllowNull()]
        [string]$Message,

        [AllowNull()]
        [object]$SelectedUnits,

        [AllowNull()]
        [object]$DeferredUnits
    )

    $unknownResult = [ordered]@{
        status            = 'unknown'
        completed_units   = @('unknown')
        incomplete_units  = @('unknown')
        reason            = 'safe point 缺少 advisor 的已完成單位欄位，無法推論完成範圍。'
    }
    if ([string]::IsNullOrWhiteSpace($Message) -or -not (Test-SafePointMessage -Message $Message -TaskType 'advisor-consult')) {
        return $unknownResult
    }

    $sectionMatch = [regex]::Match($Message, '(?ms)^##\s+中斷保全結論\s*\r?\n(?<body>.*?)(?=^##\s|\z)')
    if (-not $sectionMatch.Success) {
        return $unknownResult
    }
    $completedFieldPattern = '(?m)^\s*已完成單位\s*[:：]\s*(?<value>[^\r\n]+)\s*$'
    $completedFieldMatches = [regex]::Matches($sectionMatch.Groups['body'].Value, $completedFieldPattern)
    if ($completedFieldMatches.Count -ne 1) {
        return [ordered]@{
            status            = 'invalid'
            completed_units   = @('unknown')
            incomplete_units  = @('unknown')
            reason            = 'advisor safe point 的已完成單位欄位必須恰好宣告一次。'
        }
    }

    $selected = @($SelectedUnits | ForEach-Object { ([string]$_).Trim() })
    $deferred = @($DeferredUnits | ForEach-Object { ([string]$_).Trim() })
    $completedValue = $completedFieldMatches[0].Groups['value'].Value.Trim()
    $completed = New-Object System.Collections.Generic.List[string]
    $completedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (-not [string]::Equals($completedValue, '無', [System.StringComparison]::OrdinalIgnoreCase)) {
        foreach ($unit in @($completedValue -split '[,;；、，\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if ($unit -notmatch '^question-[A-Za-z0-9][A-Za-z0-9_-]*$') {
                return [ordered]@{
                    status            = 'invalid'
                    completed_units   = @('unknown')
                    incomplete_units  = @('unknown')
                    reason            = "advisor safe point 的已完成單位格式無效：$unit"
                }
            }
            if (-not $completedSet.Add($unit)) {
                return [ordered]@{
                    status            = 'invalid'
                    completed_units   = @('unknown')
                    incomplete_units  = @('unknown')
                    reason            = "advisor safe point 的已完成單位不可重複：$unit"
                }
            }
            $completed.Add($unit)
        }
    }

    $selectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $deferredSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($unit in $selected) { $null = $selectedSet.Add($unit) }
    foreach ($unit in $deferred) { $null = $deferredSet.Add($unit) }
    foreach ($unit in $completed) {
        if ($deferredSet.Contains($unit)) {
            return [ordered]@{
                status            = 'invalid'
                completed_units   = @('unknown')
                incomplete_units  = @('unknown')
                reason            = "advisor safe point 不可將 deferred 單位標記為已完成：$unit"
            }
        }
        if (-not $selectedSet.Contains($unit)) {
            return [ordered]@{
                status            = 'invalid'
                completed_units   = @('unknown')
                incomplete_units  = @('unknown')
                reason            = "advisor safe point 的已完成單位不在 selected units：$unit"
            }
        }
    }

    $incomplete = @($selected | Where-Object { -not $completedSet.Contains([string]$_) }) + @($deferred)
    return [ordered]@{
        status            = 'valid'
        completed_units   = @($completed.ToArray())
        incomplete_units  = @($incomplete)
        reason            = '已完成單位僅依 safe point 欄位解析，且符合 selected／deferred partition。'
    }
}

function Write-AdvisorConsultReport {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$EvidencePackPath,

        [Parameter(Mandatory)]
        [string]$EvidencePackSha256,

        [Nullable[int64]]$EvidencePackLength,

        [Parameter(Mandatory)]
        [string]$FinalMessage,

        [Parameter(Mandatory)]
        [string]$Status,

        [AllowNull()]
        [object]$BudgetMonitor,

        [AllowNull()]
        [object]$RequiredOutputGate,

        [AllowNull()]
        [object]$ScopePlan,

        [AllowNull()]
        [object]$InterruptionStatus
    )

    $fullPath = Get-AdvisorConsultReportPath -Path $Path -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $reportParent = Split-Path -Parent $fullPath
    $null = New-DispatchOutputDirectory -Path $reportParent -SourceRoot $ExecutionRoot -ExecutionRoot $ExecutionRoot
    $fullPath = Get-AdvisorConsultReportPath -Path $fullPath -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $message = if ([string]::IsNullOrWhiteSpace($FinalMessage)) { '尚未取得執行端結案訊息。' } else { $FinalMessage.Trim() }
    $declaredOutput = @()
    $presentOutput = @()
    $missingOutput = @()
    $gateValid = $false
    if ($null -ne $RequiredOutputGate) {
        $declaredProperty = $RequiredOutputGate.PSObject.Properties['required']
        $presentProperty = $RequiredOutputGate.PSObject.Properties['present']
        $missingProperty = $RequiredOutputGate.PSObject.Properties['missing']
        $validProperty = $RequiredOutputGate.PSObject.Properties['valid']
        if ($null -ne $declaredProperty) { $declaredOutput = @($declaredProperty.Value) }
        if ($null -ne $presentProperty) { $presentOutput = @($presentProperty.Value) }
        if ($null -ne $missingProperty) { $missingOutput = @($missingProperty.Value) }
        if ($null -ne $validProperty) { $gateValid = [bool]$validProperty.Value }
    }
    $gateObject = [ordered]@{
        declared = $declaredOutput
        present = $presentOutput
        missing = $missingOutput
        valid = $gateValid
    }
    $requestedUnits = if ($null -eq $ScopePlan) { @() } else { @($ScopePlan.requested_units) }
    $selectedUnits = if ($null -eq $ScopePlan) { @() } else { @($ScopePlan.selected_units) }
    $deferredUnits = if ($null -eq $ScopePlan) { @() } else { @($ScopePlan.deferred_units) }
    $completionPartition = Get-AdvisorCompletionPartition -Message $FinalMessage -SelectedUnits $selectedUnits -DeferredUnits $deferredUnits
    $completedUnits = @($completionPartition.completed_units)
    $incompleteUnits = @($completionPartition.incomplete_units)
    $activationMode = if ($null -eq $ScopePlan) { 'none' } else { [string]$ScopePlan.activation_mode }
    $authorizationSource = if ($null -eq $ScopePlan) { $null } else { $ScopePlan.authorization_source }
    $content = @(
        ('# Advisor consult report')
        ''
        ('- line-slug: ' + $LineSlug)
        ('- dispatch-slug: ' + $DispatchSlug)
        ('- status: ' + $Status)
        ('- evidence-pack: ' + $EvidencePackPath)
        ('- evidence-pack-sha256: ' + $EvidencePackSha256)
        ('- evidence-pack-length: ' + $(if ($null -eq $EvidencePackLength) { '<unknown>' } else { [string]$EvidencePackLength }))
        ('- activation-mode: ' + $activationMode)
        ('- authorization-source: ' + $(if ($null -eq $authorizationSource) { '<null>' } else { [string]$authorizationSource }))
        ''
        '## 中斷保全結論'
        ''
        $message
        ''
        '## 證據支持'
        ''
        ('- evidence pack 已通過 schema、line slug、dispatch slug 與 SHA-256 驗證：' + $EvidencePackSha256)
        ''
        '## 推論'
        ''
        '- 僅依 evidence pack 與執行端訊息整理，未加入 repository 探索結果。'
        ''
        '## 未決問題'
        ''
        '- 由 Claude 端依證據支持內容決定是否採用本報告。'
        ''
        '## Required output gate'
        ''
        ('- declared: ' + (($declaredOutput -join '; ')))
        ('- present: ' + (($presentOutput -join '; ')))
        ('- missing: ' + (($missingOutput -join '; ')))
        ('- valid: ' + [string]$gateValid)
        ''
        '## ScopePlan units'
        ''
        ('- requested: ' + (($requestedUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- selected: ' + (($selectedUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- deferred: ' + (($deferredUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- completion-partition-status: ' + [string]$completionPartition.status)
        ('- completion-partition-reason: ' + [string]$completionPartition.reason)
        ('- completed: ' + (($completedUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- incomplete: ' + (($incompleteUnits | ForEach-Object { [string]$_ }) -join '; '))
        ('- decision: ' + $(if ($null -eq $ScopePlan) { '<null>' } else { [string]$ScopePlan.decision }))
        ''
        '## Interruption status'
        ''
        (($InterruptionStatus | ConvertTo-Json -Depth 20))
        ''
        '## Quota observations'
        ''
        ('```json')
        (($BudgetMonitor | ConvertTo-Json -Depth 20))
        '```'
        ''
    ) -join "`r`n"
    $fullPath = Get-AdvisorConsultReportPath -Path $fullPath -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    Write-Utf8NoBom -Path $fullPath -Content $content -SourceRoot $ExecutionRoot -ExecutionRoot $ExecutionRoot -TargetPath @()
    return $fullPath
}
