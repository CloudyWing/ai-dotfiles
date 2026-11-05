#Requires -Version 5.1

function New-DispatchInputFinding {
    [CmdletBinding()]
    param([string]$CheckId, [string]$Severity, [string]$Code, [string]$Field, [string]$Message, [string]$Expected, [string]$Received, [string]$Source)
    [pscustomobject]@{ check_id = $CheckId; severity = $Severity; code = $Code; field = $Field; message = $Message; expected = $Expected; received = $Received; source = $Source }
}

function Get-DispatchOrderLocation {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug)
    $name = 'dispatch-order-' + $DispatchSlug + '.md'
    [pscustomobject]@{
        source = Join-Path $SourceRoot ('.local\ai-sessions\handoff\' + $LineSlug + '\' + $name)
        worktree = Join-Path $ExecutionRoot ('.local\ai-sessions\handoff\' + $LineSlug + '\' + $name)
        legacy_root_path = Join-Path $SourceRoot (Join-Path '.local\ai-sessions\handoff' $name)
    }
}

function Resolve-DispatchOrderLocation {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug, [ValidateSet('Source', 'Execution')][string]$Side)
    $root = if ($Side -eq 'Source') { $SourceRoot } else { $ExecutionRoot }
    $locations = Get-DispatchOrderLocation -SourceRoot $root -ExecutionRoot $root -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $path = [IO.Path]::GetFullPath($locations.source)
    $legacy = [IO.Path]::GetFullPath($locations.legacy_root_path)
    $state = 'missing'
    $code = 'DispatchInputOrderMissing'
    $message = '派遣單不存在：' + $path
    try {
        if (Test-Path -LiteralPath $legacy -PathType Leaf -ErrorAction Stop) {
            $state = 'legacy-root'
            $code = 'DispatchInputOrderLocationInvalid'
            $message = '派遣單位於根目錄：' + $legacy + '；請移至正確路徑並移除根目錄檔案：' + $path
        }
        elseif (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) {
            $state = 'ok'
            $code = ''
            $message = '派遣單位置：' + $path
        }
    }
    catch { $message += '；' + $_.Exception.Message }
    [pscustomobject]@{ side = $Side; path = $path; legacy_root_path = $legacy; state = $state; code = $code; message = $message }
}

function Get-DispatchOrderLocationFinding {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug, [ValidateSet('Source', 'Execution')][string]$Side)
    $result = Resolve-DispatchOrderLocation -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Side $Side
    if ($result.state -ne 'ok') {
        $id = if ($Side -eq 'Source') { 'DI-ORDERLOC-A' } else { 'DI-ORDERLOC' }
        New-DispatchInputFinding -CheckId $id -Severity 'error' -Code $result.code -Field 'order' -Message $result.message -Expected $result.path -Received '' -Source $result.path
    }
}

function Test-DispatchOrderRequiresDesign {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$TaskBody, [string]$LineSlug)
    return $TaskBody -match ('(?i)handoff[\\/]' + [regex]::Escape($LineSlug) + '[\\/]design\.md\b')
}

function Test-DispatchRequiredIdentifierResolvable {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ConfiguredIdentifier, [string]$DispatchKind, [AllowEmptyString()][string]$TaskType, [AllowEmptyString()][string]$EvidencePackPath, [AllowEmptyCollection()][string[]]$TargetPath)
    try {
        $null = Get-DispatchRequiredIdentifier -ConfiguredIdentifier $ConfiguredIdentifier -DispatchKind $DispatchKind -TaskType $TaskType -EvidencePackPath $EvidencePackPath -TargetPath $TargetPath
        return $true
    }
    catch { return $false }
}

function Get-DispatchReferenceFindings {
    [CmdletBinding()]
    param([object]$Order, [string]$Stage, [string]$DispatchRoot)
    if ($null -eq $Order) { return }
    $pathPattern = '(?i)(?<![a-z0-9_.\-\\/])(?:`(?<quoted>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^`\r\n]+)`|"(?<quoted>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^"\r\n]+)"|(?<bare>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^\s`"''<>|、（，；：\]]+))'
    foreach ($line in ([string]$Order.TaskBody -split '\r?\n')) {
        foreach ($pathMatch in [regex]::Matches($line, $pathPattern)) {
            $path = if ($pathMatch.Groups['quoted'].Success) { $pathMatch.Groups['quoted'].Value } else { $pathMatch.Groups['bare'].Value.TrimEnd('.', ',', '，', '。', '）', ')') }
            $path = $path -replace ':\d+(?::\d+)?$', ''
            $underDispatch = Test-PathWithinRoot -Path $path -Root $DispatchRoot
            if (($Stage -eq 'Request' -and $underDispatch) -or ($Stage -eq 'Worktree' -and -not $underDispatch)) { continue }
            try { if (Test-Path -LiteralPath $path -ErrorAction Stop) { continue } }
            catch {
                $id = if ($Stage -eq 'Worktree') { 'DI-REF-B' } else { 'DI-REF-A' }
                New-DispatchInputFinding -CheckId $id -Severity 'error' -Code 'DispatchInputReferenceMissing' -Field 'task_body' -Message ('無法檢查派遣單引用路徑：' + $path + '；' + $_.Exception.Message) -Expected $path -Received '' -Source ([string]$Order.Path)
                continue
            }
            $prefix = $line.Substring(0, $pathMatch.Index)
            $verbs = [regex]::Matches($prefix, '(?i)必讀|讀取|參考|依據|比對|審查|新增|建立|產生|輸出|寫入|\bread\b|\bcreate\b|\bwrite\b|\boutput\b')
            $verb = if ($verbs.Count -gt 0) { $verbs[$verbs.Count - 1].Value } else { '' }
            $severity = if ($Stage -eq 'Worktree' -or $verb -match '(?i)必讀|讀取|參考|依據|比對|審查|\bread\b') { 'error' } else { 'warning' }
            $id = if ($Stage -eq 'Worktree') { 'DI-REF-B' } else { 'DI-REF-A' }
            New-DispatchInputFinding -CheckId $id -Severity $severity -Code 'DispatchInputReferenceMissing' -Field 'task_body' -Message ('派遣單引用路徑不存在：' + $path) -Expected $path -Received '' -Source ([string]$Order.Path)
        }
    }
    if ($Stage -eq 'Request') {
        $acceptance = [regex]::Match([string]$Order.Content, '(?ms)^##\s*5\..*?\r?\n(?<body>.*?)(?=^##\s*6\.|\z)')
        foreach ($pathMatch in [regex]::Matches($acceptance.Groups['body'].Value, $pathPattern)) {
            $path = if ($pathMatch.Groups['quoted'].Success) { $pathMatch.Groups['quoted'].Value } else { $pathMatch.Groups['bare'].Value.TrimEnd('.', ',', '，', '。', '）', ')') }
            $path = $path -replace ':\d+(?::\d+)?$', ''
            try {
                if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
                    New-DispatchInputFinding -CheckId 'DI-REF-A' -Severity 'warning' -Code 'DispatchInputReferenceMissing' -Field 'acceptance' -Message ('驗收命令引用路徑不存在：' + $path) -Expected $path -Received '' -Source ([string]$Order.Path)
                }
            }
            catch {
                New-DispatchInputFinding -CheckId 'DI-REF-A' -Severity 'error' -Code 'DispatchInputReferenceMissing' -Field 'acceptance' -Message ('無法檢查驗收命令引用路徑：' + $path + '；' + $_.Exception.Message) -Expected $path -Received '' -Source ([string]$Order.Path)
            }
        }
    }
}

function Test-DispatchDirectoryContainsCsharp {
    [CmdletBinding()]
    param([string]$Path)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    $count = 0
    while ($pending.Count -gt 0) {
        $directoryPath = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop) {
            $count++
            if ($count -gt 10000) { throw 'DispatchInputDirectoryScanLimit：目錄掃描超過 10000 個項目。' }
            if ($item.PSIsContainer) {
                if ($item.Name -notin @('bin', 'obj', '.git', '.local', 'node_modules') -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($item.FullName) }
            }
            elseif ($item.Extension -in @('.cs', '.csx')) { return $true }
        }
    }
    return $false
}

function Invoke-DispatchInputChecks {
    [CmdletBinding()]
    param([ValidateSet('Request', 'Worktree')][string]$Stage, [Parameter(Mandatory)][object]$Context)
    $promptPath = [string](Get-DispatchJsonProperty -Object $Context -Name 'PromptPath')
    $contextValues = @{}
    $promptText = ''
    $promptExists = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($promptPath) -and (Test-Path -LiteralPath $promptPath -PathType Leaf -ErrorAction Stop)) {
            $promptText = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8 -ErrorAction Stop
            $promptExists = $true
        }
    }
    catch {
        $id = if ($Stage -eq 'Worktree') { 'DI-LINECTX-B' } else { 'DI-LINECTX-A' }
        $code = if ($Stage -eq 'Worktree') { 'DispatchInputLineContextMismatch' } else { 'DispatchInputLineContextMissing' }
        New-DispatchInputFinding -CheckId $id -Severity 'error' -Code $code -Field 'prompt_path' -Message ('無法讀取 prompt：' + $promptPath + '；' + $_.Exception.Message) -Expected $promptPath -Received '' -Source $promptPath
    }
    if ($promptExists) {
        foreach ($label in @('lineSlug', 'sourceLineRoot', 'dispatchLineRoot', 'reportLineRoot', 'sourceRoot', 'dispatchRoot')) {
            $match = [regex]::Match($promptText, '(?im)^\s*(?:-\s*)?' + $label + '\s*[:=]\s*[`"'']?(?<value>[^\r\n`"'']+)', [Text.RegularExpressions.RegexOptions]::None)
            if ($match.Success) { $contextValues[$label] = $match.Groups['value'].Value.Trim() }
        }
    }
    if ($Stage -eq 'Worktree') {
        $executionRoot = [string]$Context.ExecutionRoot
        $expected = @{
            dispatchRoot = $executionRoot
            dispatchLineRoot = Join-Path $executionRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug)
            reportLineRoot = Join-Path $executionRoot ('.local\ai-sessions\report\' + $Context.LineSlug)
        }
        foreach ($label in $expected.Keys) {
            if (-not $contextValues.ContainsKey($label) -or -not [string]::Equals($contextValues[$label], $expected[$label], [StringComparison]::OrdinalIgnoreCase)) {
                New-DispatchInputFinding -CheckId 'DI-LINECTX-B' -Severity 'error' -Code 'DispatchInputLineContextMismatch' -Field $label -Message ('LineContext 不符實際執行目錄：' + $label) -Expected $expected[$label] -Received ([string]$contextValues[$label]) -Source $promptPath
            }
        }
        if ($Context.DispatchKind -eq 'resource' -and $Context.TaskType -ne 'advisor-consult') {
            Get-DispatchOrderLocationFinding -SourceRoot $Context.SourceRoot -ExecutionRoot $executionRoot -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug -Side Execution
        }
        if (-not [string]::Equals($executionRoot, $Context.SourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Get-DispatchReferenceFindings -Order $Context.ResourceOrder -Stage $Stage -DispatchRoot $executionRoot
        }
        return
    }
    if ($Context.DispatchKind -eq 'resource' -and $Context.TaskType -ne 'advisor-consult') {
        Get-DispatchOrderLocationFinding -SourceRoot $Context.SourceRoot -ExecutionRoot $Context.SourceRoot -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug -Side Source
    }
    $sourceLineRoot = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug)
    if (-not $promptExists -or $promptText -notmatch '(?i)LineContext') {
        New-DispatchInputFinding -CheckId 'DI-LINECTX-A' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field 'LineContext' -Message ('prompt 缺少 LineContext 區塊：' + $promptPath) -Expected 'LineContext 區塊' -Received '' -Source $promptPath
    }
    $expectedSource = @{ lineSlug = [string]$Context.LineSlug; sourceRoot = [string]$Context.SourceRoot; sourceLineRoot = $sourceLineRoot }
    foreach ($label in @('lineSlug', 'sourceLineRoot', 'dispatchLineRoot', 'reportLineRoot', 'sourceRoot', 'dispatchRoot')) {
        if (-not $contextValues.ContainsKey($label) -or ($expectedSource.ContainsKey($label) -and -not [string]::Equals($contextValues[$label], $expectedSource[$label], [StringComparison]::OrdinalIgnoreCase))) {
            New-DispatchInputFinding -CheckId 'DI-LINECTX-A' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field $label -Message ('LineContext 欄位缺少或不符：' + $label) -Expected ([string]$expectedSource[$label]) -Received ([string]$contextValues[$label]) -Source $promptPath
        }
    }
    if ($contextValues.ContainsKey('dispatchRoot') -and $contextValues.ContainsKey('dispatchLineRoot') -and $contextValues.ContainsKey('reportLineRoot')) {
        $possibleRoot = Join-Path $Context.SourceRoot ('.local\ai-sessions\worktrees\' + $Context.DispatchSlug)
        $rootValue = $contextValues['dispatchRoot']
        $validRoot = [string]::Equals($rootValue, $Context.SourceRoot, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($rootValue, $possibleRoot, [StringComparison]::OrdinalIgnoreCase)
        $validHandoff = [string]::Equals($contextValues['dispatchLineRoot'], (Join-Path $rootValue ('.local\ai-sessions\handoff\' + $Context.LineSlug)), [StringComparison]::OrdinalIgnoreCase)
        $validReport = [string]::Equals($contextValues['reportLineRoot'], (Join-Path $rootValue ('.local\ai-sessions\report\' + $Context.LineSlug)), [StringComparison]::OrdinalIgnoreCase)
        if (-not ($validRoot -and $validHandoff -and $validReport)) {
            New-DispatchInputFinding -CheckId 'DI-LINECTX-A' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field 'dispatchRoot' -Message 'LineContext 的執行根目錄與交接、報告目錄不一致。' -Expected '同一來源樹或派遣 worktree' -Received $rootValue -Source $promptPath
        }
    }
    $evidenceCheckPath = [string](Get-DispatchJsonProperty -Object $Context -Name 'EvidenceCheckPath')
    if ([string]::IsNullOrWhiteSpace($evidenceCheckPath)) { $evidenceCheckPath = [string]$Context.EvidencePackPath }
    if ($Context.TaskType -eq 'advisor-consult') {
        try {
            if ([string]::IsNullOrWhiteSpace($evidenceCheckPath) -or -not (Test-Path -LiteralPath $evidenceCheckPath -PathType Leaf -ErrorAction Stop)) { throw '找不到 evidence pack。' }
            $evidenceContent = Get-Content -LiteralPath $evidenceCheckPath -Raw -Encoding UTF8 -ErrorAction Stop
            $missingRules = @(Test-AdvisorEvidencePackContent -Content $evidenceContent -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug)
            foreach ($rule in $missingRules) {
                New-DispatchInputFinding -CheckId 'DI-EVID' -Severity 'error' -Code 'EvidencePackInvalid' -Field 'evidence_pack_path' -Message ('evidence pack 缺少必要內容；要求的完整內容：' + $rule.Display) -Expected $rule.Display -Received '' -Source $evidenceCheckPath
            }
        }
        catch {
            New-DispatchInputFinding -CheckId 'DI-EVID' -Severity 'error' -Code 'EvidencePackInvalid' -Field 'evidence_pack_path' -Message ('無法讀取 evidence pack：' + $evidenceCheckPath + '；' + $_.Exception.Message) -Expected $evidenceCheckPath -Received '' -Source $evidenceCheckPath
        }
    }
    $order = $Context.ResourceOrder
    $referenceRoot = Join-Path $Context.SourceRoot ('.local\ai-sessions\worktrees\' + $Context.DispatchSlug)
    Get-DispatchReferenceFindings -Order $order -Stage $Stage -DispatchRoot $referenceRoot
    if ($null -ne $order) {
        if ([string](Get-DispatchJsonProperty -Object $Context -Name 'WriteMode') -eq 'write' -and $order.Role -match '(?i)維護工程師|值班工程師|除錯工程師|Maintainer|debug|除錯' -and ($order.TaskBody + ' ' + $order.Boundary) -match '(?i)(不|禁止|不得|不可)\s*(派生|使用)\s*subagent') {
            New-DispatchInputFinding -CheckId 'DI-ROLE' -Severity 'error' -Code 'DispatchInputRoleConflict' -Field 'role' -Message 'Maintainer 與禁止派生 subagent 衝突，請改用 Support Engineer 或移除禁止字樣。' -Expected '相容的角色與邊界' -Received ([string]$order.Role) -Source ([string]$order.Path)
        }
        $summaryPath = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\requirement-summary.md')
        if ($order.Role -match '(?i)Reviewer|Frontend Reviewer|Contract Auditor|review|審查') {
            try {
                if ((Test-Path -LiteralPath $summaryPath -PathType Leaf -ErrorAction Stop) -and $order.TaskBody -notmatch '(?i)requirement-summary\.md') {
                    New-DispatchInputFinding -CheckId 'DI-REV4' -Severity 'error' -Code 'DispatchInputReviewerSummaryUnlisted' -Field 'task_body' -Message ('派遣單第 4 欄缺少需求摘要：' + $summaryPath) -Expected $summaryPath -Received '' -Source ([string]$order.Path)
                }
            }
            catch {
                New-DispatchInputFinding -CheckId 'DI-REV4' -Severity 'error' -Code 'DispatchInputReviewerSummaryUnlisted' -Field 'task_body' -Message ('無法檢查需求摘要：' + $summaryPath + '；' + $_.Exception.Message) -Expected $summaryPath -Received '' -Source ([string]$order.Path)
            }
        }
    }
    $hasCsharpTarget = $false
    $targetScanError = ''
    if ([string](Get-DispatchJsonProperty -Object $Context -Name 'WriteMode') -eq 'write') {
        foreach ($target in @($Context.TargetPath)) {
            if ([string]$target -match '(?i)\.csx?$') { $hasCsharpTarget = $true; break }
            try {
                if ((Test-Path -LiteralPath $target -PathType Container -ErrorAction Stop) -and (Test-DispatchDirectoryContainsCsharp -Path $target)) { $hasCsharpTarget = $true; break }
            }
            catch {
                $targetScanError = $_.Exception.Message
                if ($targetScanError.StartsWith('DispatchInputDirectoryScanLimit', [StringComparison]::Ordinal)) {
                    New-DispatchInputFinding -CheckId 'DI-STYLE' -Severity 'error' -Code 'DispatchInputDirectoryScanLimit' -Field 'target_path' -Message '目錄項目超過 10000 個，無法確認是否含 C# 檔；請將 target_path 縮小到實際要修改的子目錄或檔案。' -Expected '不超過 10000 個項目的目標目錄' -Received '' -Source ([string]$target)
                }
                else {
                    New-DispatchInputFinding -CheckId 'DI-STYLE' -Severity 'error' -Code 'DispatchInputProfileKeyMissing' -Field 'target_path' -Message ('無法檢查目標目錄：' + $target + '；' + $targetScanError) -Expected '可讀取的目標目錄' -Received '' -Source ([string]$target)
                }
            }
        }
    }
    if ($hasCsharpTarget) {
        $profilePath = Join-Path $Context.SourceRoot 'AGENTS.local.md'
        $style = ''
        $structureError = ''
        try {
            if (Test-Path -LiteralPath $profilePath -PathType Leaf -ErrorAction Stop) {
                $profile = [string](Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 -ErrorAction Stop)
                $begins = [regex]::Matches($profile, '(?m)^<!-- AI-PROFILE:BEGIN -->\r?$')
                $ends = [regex]::Matches($profile, '(?m)^<!-- AI-PROFILE:END -->\r?$')
                if ($begins.Count -ne $ends.Count -or $begins.Count -gt 1 -or ($begins.Count -eq 1 -and $begins[0].Index -ge $ends[0].Index) -or ([regex]::Matches($profile, 'AI-PROFILE:(BEGIN|END)').Count -ne ($begins.Count + $ends.Count))) { $structureError = 'AI-PROFILE 標記結構無效。' }
                elseif ($begins.Count -eq 1) {
                    $keys = @{}
                    $body = $profile.Substring($begins[0].Index + $begins[0].Length, $ends[0].Index - $begins[0].Index - $begins[0].Length)
                    foreach ($lineText in ($body -split '\r?\n')) {
                        if ([string]::IsNullOrWhiteSpace($lineText)) { continue }
                        if ($lineText -cnotmatch '^\s*([a-z0-9.-]+)\s*:\s*(\S.*?)\s*$' -or $keys.ContainsKey($Matches[1])) { $structureError = 'AI-PROFILE 鍵值格式無效或重複。'; break }
                        $keys[$Matches[1]] = $Matches[2]
                    }
                    if ($keys.ContainsKey('code-style.csharp')) { $style = $keys['code-style.csharp'] }
                }
            }
        }
        catch { $structureError = '無法讀取 AI-PROFILE：' + $_.Exception.Message }
        if ($structureError -ne '' -or $style -cnotin @('personal', 'standard', 'project')) {
            $code = if ($structureError -ne '') { 'AiProfileStructureInvalid' } else { 'DispatchInputProfileKeyMissing' }
            New-DispatchInputFinding -CheckId 'DI-STYLE' -Severity 'error' -Code $code -Field 'code-style.csharp' -Message ('AI-PROFILE 的 code-style.csharp 缺少或無效：' + $profilePath + ' ' + $structureError) -Expected 'personal、standard 或 project' -Received $style -Source $profilePath
        }
    }
    $linePath = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\line.json')
    try {
        $line = Get-Content -LiteralPath $linePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $kind = [string](Get-DispatchJsonProperty -Object $line -Name 'kind')
        if ((Get-DispatchJsonProperty -Object $line -Name 'schema') -cne 'ai-sessions.line.v1' -or (Get-DispatchJsonProperty -Object $line -Name 'line-slug') -cne $Context.LineSlug -or ($kind -ne '' -and $kind -notin @('workflow', 'adhoc'))) { throw 'line.json 欄位不符。' }
    }
    catch {
        New-DispatchInputFinding -CheckId 'DI-LINEJSON' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field 'line.json' -Message ('line.json 缺少或無效：' + $linePath + '；' + $_.Exception.Message) -Expected $linePath -Received '' -Source $linePath
    }
    if (-not (Test-DispatchRequiredIdentifierResolvable -ConfiguredIdentifier ([string]$Context.RequiredIdentifier) -DispatchKind ([string]$Context.DispatchKind) -TaskType ([string]$Context.TaskType) -EvidencePackPath ([string]$Context.EvidencePackPath) -TargetPath @($Context.TargetPath))) {
        New-DispatchInputFinding -CheckId 'DI-IDENT' -Severity 'error' -Code 'DispatchRequestMissingField' -Field 'required_identifier' -Message '無法從 target_path 推導 required_identifier，請提供該欄位。' -Expected 'required_identifier 或具有檔名的 target_path' -Received '' -Source 'request'
    }
    if ($Context.DispatchKind -eq 'resource' -and $null -ne $Context.ResourceOrder -and (Test-DispatchOrderRequiresDesign -TaskBody ([string]$Context.ResourceOrder.TaskBody) -LineSlug ([string]$Context.LineSlug))) {
        $designPath = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\design.md')
        if (-not (Test-Path -LiteralPath $designPath -PathType Leaf)) {
            New-DispatchInputFinding -CheckId 'DI-DESIGN' -Severity 'error' -Code 'DispatchInputDesignMissing' -Field 'design.md' -Message ('找不到派遣單要求的設計文件：' + $designPath) -Expected $designPath -Received '' -Source ([string]$Context.ResourceOrder.Path)
        }
    }
}

function Assert-DispatchInputFindings {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Findings, [string]$RequestPathValue)
    $errors = @($Findings | Where-Object { $_.severity -eq 'error' })
    if ($errors.Count -gt 0) {
        $detail = [ordered]@{ findings = @($Findings) }
        if (@($errors | Where-Object { $_.check_id -eq 'DI-STYLE' -and $_.field -eq 'code-style.csharp' -and $_.code -eq 'DispatchInputProfileKeyMissing' }).Count -gt 0) { $detail.missing_keys = @('code-style.csharp') }
        Throw-DispatchRequestFailure -Code $errors[0].code -Message (($errors | ForEach-Object { $_.message }) -join '；') -RequestPathValue $RequestPathValue -Field $errors[0].field -Detail $detail
    }
}
