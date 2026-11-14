#Requires -Version 7.0

# 資源派遣（dispatch_kind=resource、write_mode=readonly）的輸入產生器。
# 一次產出 Request、line.json（不存在時）、prompt 與派遣單（非 advise），並以
# Invoke-CodexDispatch.ps1 -Operation Dispatch -ValidateOnly 自檢；自檢失敗時刪除本次建立的檔案，但保留本次新建的 line.json（它是合法的線 manifest）。
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceRoot,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$LineSlug,

    [Parameter(Mandatory)]
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$DispatchSlug,

    [Parameter(Mandatory)]
    [string]$TaskType,

    [Parameter(Mandatory)]
    [ValidateSet('review', 'scan', 'content', 'advisor')]
    [string]$Profile,

    [AllowNull()]
    [string[]]$TargetPath,

    [string]$Role,

    [string]$Title,

    [string]$TaskBody,

    [AllowNull()]
    [hashtable[]]$Acceptance,

    [string]$Boundary,

    [string]$ReportPath,

    [AllowNull()]
    [AllowEmptyCollection()]
    [AllowEmptyString()]
    [string[]]$RequiredRead,

    [string]$SemanticLabel,

    [ValidateSet('workflow', 'adhoc')]
    [string]$LineKind = 'adhoc',

    [string]$RequiredIdentifier,

    [string]$CallerSessionId,

    [switch]$Background,

    [string]$EvidencePackPath,

    [string]$AdvisorReportPath,

    [ValidateSet('user-explicit')]
    [string]$AdvisorRequestSource = 'user-explicit'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
. (Join-Path $PSScriptRoot 'dispatch\dispatch-input-checks.ps1')

$supportedTaskTypes = @('review', 'test', 'generate', 'factcheck', 'advise')
$createdFiles = New-Object 'System.Collections.Generic.List[string]'

function Throw-DispatchInputFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Classification,
        [Parameter(Mandatory)][string]$Field,
        [Parameter(Mandatory)][string]$Message,
        [AllowNull()][object]$Detail
    )

    $result = [ordered]@{
        operation      = 'NewDispatchInputs'
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

function Test-AbsolutePathText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    return [regex]::IsMatch($Value, '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))')
}

function Test-PathInsideRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or $fullPath.StartsWith($fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

# 以排他建立寫入檔案；已存在時回報 DispatchInputOutputExists。成功建立的檔案登記於 $createdFiles 供回滾。
function New-ExclusiveFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [AllowEmptyString()][string]$Content = '')

    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        if (Test-Path -LiteralPath $Path) {
            Throw-DispatchInputFailure -Code 'DispatchInputOutputExists' -Classification 'InvalidValue' -Field 'OutputPath' -Message ('輸出檔已存在，不覆寫：' + $Path) -Detail ([ordered]@{ path = $Path })
        }
        throw
    }
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    $createdFiles.Add($Path)
}

function Write-OwnedFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Test-GitRepositoryState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)

    # 判定與 Preflight 的 Get-ExistingGitRepositoryState 相同：只以 stdout 判斷 true；exit 非 0 且 stderr 明確回報「不是 repository」才判為非 repository；
    # 其他情形（safe.directory、權限、exit 0 但輸出不是 true 等）不預判，直接回報錯誤。
    $isRepository = $false
    $hasBaseCommit = $false
    $probeRecords = @(& git -C $Root rev-parse --is-inside-work-tree 2>&1)
    $probeExitCode = $LASTEXITCODE
    $probeStdout = (@($probeRecords | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $probeStderr = (@($probeRecords | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ }) -join "`n").Trim()
    $probeText = (($probeStdout + "`n" + $probeStderr)).Trim()
    if ($probeExitCode -eq 0 -and $probeStdout -eq 'true') {
        $isRepository = $true
        $null = & git -C $Root rev-parse --verify 'HEAD^{commit}' 2>$null
        $hasBaseCommit = $LASTEXITCODE -eq 0
    }
    elseif ($probeExitCode -ne 0 -and $probeStderr -match '(?i)not a git repository|不是 git 儲存庫') {
        $isRepository = $false
    }
    else {
        Throw-DispatchInputFailure -Code 'DispatchInputGitProbeFailed' -Classification 'InvalidValue' -Field 'SourceRoot' -Message ('Git 前置探針失敗，無法判定 SourceRoot 是否為 repository。exit code ' + $probeExitCode + '：' + $probeText) -Detail ([ordered]@{ source_root = $Root; exit_code = $probeExitCode; stderr = $probeText })
    }
    return [pscustomobject]@{ IsRepository = $isRepository; HasBaseCommit = $hasBaseCommit }
}

function Invoke-OrderScript {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Parameters)

    $orderScript = Join-Path $PSScriptRoot 'New-DispatchOrder.ps1'
    $originalError = [Console]::Error
    $errorWriter = New-Object System.IO.StringWriter
    [Console]::SetError($errorWriter)
    try {
        $global:LASTEXITCODE = 0
        $null = & $orderScript @Parameters
        $exitCode = $LASTEXITCODE
    }
    finally { [Console]::SetError($originalError) }
    return [pscustomobject]@{ ExitCode = [int]$exitCode; Stderr = $errorWriter.ToString().Trim() }
}

function Invoke-ValidateOnly {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RequestPath)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Process -Id $PID).Path
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $PSScriptRoot 'Invoke-CodexDispatch.ps1'), '-Operation', 'Dispatch', '-RequestPath', $RequestPath, '-ValidateOnly')) {
        $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdoutTask.Wait()
        $stderrTask.Wait()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdoutTask.Result; Stderr = $stderrTask.Result }
    }
    finally { $process.Dispose() }
}

try {
    # 第一段：只驗證，不寫入任何檔案。
    if ($TaskType -cnotin $supportedTaskTypes) {
        Throw-DispatchInputFailure -Code 'DispatchInputTaskTypeUnsupported' -Classification 'InvalidValue' -Field 'TaskType' -Message ("TaskType '{0}' 不受產生器支援；支援值：{1}。" -f $TaskType, ($supportedTaskTypes -join ', ')) -Detail ([ordered]@{ received = $TaskType; supported = $supportedTaskTypes })
    }
    $registryPath = Join-Path $PSScriptRoot 'dispatch\executor-registry.json'
    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $matchedExecutors = @($registry.executors | Where-Object {
            $_.platform -ceq 'codex' -and $null -ne $_.PSObject.Properties['profile'] -and $_.profile -ceq $Profile -and @($_.accepts) -ccontains $TaskType
        })
    if ($matchedExecutors.Count -eq 0) {
        Throw-DispatchInputFailure -Code 'DispatchInputProfileTaskMismatch' -Classification 'InvalidValue' -Field 'Profile' -Message ("檔位 '{0}' 沒有 Codex 執行者受理 TaskType '{1}'；請以 Select-DispatchExecutor.ps1 取得檔位。" -f $Profile, $TaskType) -Detail ([ordered]@{ profile = $Profile; task_type = $TaskType })
    }

    $isAdvise = $TaskType -ceq 'advise'
    $sourceRootPath = [IO.Path]::GetFullPath($SourceRoot)
    if (-not (Test-Path -LiteralPath $sourceRootPath -PathType Container)) {
        Throw-DispatchInputFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'SourceRoot' -Message ('SourceRoot 不存在或不是目錄：' + $sourceRootPath) -Detail ([ordered]@{ received = $sourceRootPath })
    }

    $requiredFields = if ($isAdvise) { @('EvidencePackPath') } else { @('TargetPath', 'Role', 'Title', 'TaskBody', 'Acceptance', 'Boundary', 'ReportPath') }
    foreach ($fieldName in $requiredFields) {
        $fieldValue = Get-Variable -Name $fieldName -ValueOnly
        $missing = $null -eq $fieldValue -or ($fieldValue -is [string] -and [string]::IsNullOrWhiteSpace($fieldValue)) -or ($fieldValue -is [array] -and @($fieldValue).Count -eq 0)
        if ($missing) {
            Throw-DispatchInputFailure -Code 'DispatchRequestMissingField' -Classification 'MissingField' -Field $fieldName -Message ("參數 '{0}' 不可缺少。" -f $fieldName) -Detail $null
        }
    }

    $targetPaths = New-Object 'System.Collections.Generic.List[string]'
    $sourceTargets = @(if ($isAdvise -and ($null -eq $TargetPath -or @($TargetPath).Count -eq 0)) { $EvidencePackPath } else { $TargetPath })
    for ($index = 0; $index -lt $sourceTargets.Count; $index++) {
        $targetValue = [string]$sourceTargets[$index]
        if ([string]::IsNullOrWhiteSpace($targetValue) -or -not (Test-AbsolutePathText -Value $targetValue)) {
            Throw-DispatchInputFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'TargetPath' -Message ("參數 'TargetPath' 第 {0} 項必須是完整絕對路徑。" -f $index) -Detail ([ordered]@{ index = $index; expected = 'fully-qualified path'; received = $targetValue })
        }
        $targetPaths.Add($targetValue)
    }
    if ($isAdvise) {
        if (-not (Test-AbsolutePathText -Value $EvidencePackPath)) {
            Throw-DispatchInputFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'EvidencePackPath' -Message "參數 'EvidencePackPath' 必須是完整絕對路徑。" -Detail ([ordered]@{ expected = 'fully-qualified path'; received = $EvidencePackPath })
        }
        if (-not [string]::IsNullOrWhiteSpace($AdvisorReportPath) -and -not (Test-AbsolutePathText -Value $AdvisorReportPath)) {
            Throw-DispatchInputFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'AdvisorReportPath' -Message "參數 'AdvisorReportPath' 必須是完整絕對路徑。" -Detail ([ordered]@{ expected = 'fully-qualified path'; received = $AdvisorReportPath })
        }
    }
    elseif (-not (Test-AbsolutePathText -Value $ReportPath)) {
        Throw-DispatchInputFailure -Code 'DispatchRequestInvalidPath' -Classification 'InvalidPath' -Field 'ReportPath' -Message "參數 'ReportPath' 必須是完整絕對路徑。" -Detail ([ordered]@{ expected = 'fully-qualified path'; received = $ReportPath })
    }

    $handoffLineRoot = Join-Path $sourceRootPath ('.local\ai-sessions\handoff\' + $LineSlug)
    $historyLineRoot = Join-Path $sourceRootPath ('.local\ai-sessions\history\' + $LineSlug)
    $lineManifestPath = Join-Path $handoffLineRoot 'line.json'
    $orderPath = Join-Path $handoffLineRoot ('dispatch-order-' + $DispatchSlug + '.md')
    $promptPath = Join-Path $handoffLineRoot ('dispatch-prompt-' + $DispatchSlug + '.md')
    $requestPath = Join-Path $historyLineRoot ('dispatch-request-' + $DispatchSlug + '.json')
    $failureReceiptPath = Join-Path $historyLineRoot ('failure-receipt-' + $DispatchSlug + '.json')
    $resultPath = Join-Path $historyLineRoot ('dispatch-result-' + $DispatchSlug + '.json')

    $lineManifestExists = Test-Path -LiteralPath $lineManifestPath -PathType Leaf
    if ($lineManifestExists) {
        $manifestSlug = $null
        try {
            $manifest = Get-Content -LiteralPath $lineManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $slugProperty = $manifest.PSObject.Properties['line-slug']
            if ($null -ne $slugProperty) { $manifestSlug = [string]$slugProperty.Value }
        }
        catch {
            Throw-DispatchInputFailure -Code 'DispatchInputLineManifestMismatch' -Classification 'InvalidValue' -Field 'line.json' -Message ('line.json 無法讀取：' + $lineManifestPath + '；' + $_.Exception.Message) -Detail ([ordered]@{ path = $lineManifestPath })
        }
        if ($manifestSlug -cne $LineSlug) {
            Throw-DispatchInputFailure -Code 'DispatchInputLineManifestMismatch' -Classification 'InvalidValue' -Field 'line.json' -Message ("line.json 的 line-slug '{0}' 與輸入 '{1}' 不一致：{2}" -f $manifestSlug, $LineSlug, $lineManifestPath) -Detail ([ordered]@{ path = $lineManifestPath; expected = $LineSlug; received = $manifestSlug })
        }
    }
    elseif ([string]::IsNullOrWhiteSpace($SemanticLabel)) {
        Throw-DispatchInputFailure -Code 'DispatchRequestMissingField' -Classification 'MissingField' -Field 'SemanticLabel' -Message ("line.json 不存在時必須提供 SemanticLabel：" + $lineManifestPath) -Detail $null
    }

    $plannedOutputs = @($promptPath, $requestPath)
    if (-not $isAdvise) { $plannedOutputs = @($orderPath) + $plannedOutputs }
    foreach ($plannedOutput in $plannedOutputs) {
        if (Test-Path -LiteralPath $plannedOutput) {
            Throw-DispatchInputFailure -Code 'DispatchInputOutputExists' -Classification 'InvalidValue' -Field 'OutputPath' -Message ('輸出檔已存在，不覆寫：' + $plannedOutput) -Detail ([ordered]@{ path = $plannedOutput })
        }
    }

    $gitState = Test-GitRepositoryState -Root $sourceRootPath
    $mode = Get-DispatchExpectedExecutionMode -SourceRoot $sourceRootPath -DispatchSlug $DispatchSlug -WriteMode 'readonly' -IsRepository $gitState.IsRepository -HasBaseCommit $gitState.HasBaseCommit
    if (-not $isAdvise -and $mode.worktreeCreated -and -not (Test-PathInsideRoot -Path $ReportPath -Root $mode.executionRoot)) {
        Throw-DispatchInputFailure -Code 'DispatchReportPathOutsideExecutionRoot' -Classification 'InvalidPath' -Field 'ReportPath' -Message ("ReportPath 必須位於 executionRoot 內（Preflight 會建立 dispatch worktree）；executionRoot={0}；收到：{1}" -f $mode.executionRoot, $ReportPath) -Detail ([ordered]@{ execution_root = $mode.executionRoot; received = $ReportPath })
    }
    $lineContextBlock = Format-DispatchLineContextBlock -LineSlug $LineSlug -SourceRoot $sourceRootPath -ExecutionRoot $mode.executionRoot
    $advisorReportPathValue = if (-not $isAdvise) { $null } elseif (-not [string]::IsNullOrWhiteSpace($AdvisorReportPath)) { $AdvisorReportPath } else { Join-Path $mode.executionRoot ('.local\ai-sessions\report\' + $LineSlug + '\advisor-consult-' + $DispatchSlug + '.md') }

    # 第二段：寫入。先以排他建立保留輸出檔，再填入內容；失敗時由外層 catch 回滾本次建立的檔案。
    $lineManifestCreated = $false
    if (-not $lineManifestExists) {
        $manifestContent = ([ordered]@{
                'schema'         = 'ai-sessions.line.v1'
                'line-slug'      = $LineSlug
                'semantic-label' = $SemanticLabel
                'kind'           = $LineKind
                'created-at-utc' = [DateTime]::UtcNow.ToString('o')
            } | ConvertTo-Json) + "`r`n"
        try {
            New-ExclusiveFile -Path $lineManifestPath -Content $manifestContent
            $lineManifestCreated = $true
            # line.json 是合法的線 manifest，其他產生器可能已依它運作；後續失敗時保留，不列入回滾。
            [void]$createdFiles.Remove($lineManifestPath)
        }
        catch {
            if ($_.Exception.Data['operationResult'] -is [System.Collections.IDictionary]) {
                $lineManifestCreated = $false
                $manifest = Get-Content -LiteralPath $lineManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ([string]$manifest.'line-slug' -cne $LineSlug) {
                    Throw-DispatchInputFailure -Code 'DispatchInputLineManifestMismatch' -Classification 'InvalidValue' -Field 'line.json' -Message ('line.json 的 line-slug 與輸入不一致：' + $lineManifestPath) -Detail ([ordered]@{ path = $lineManifestPath })
                }
            }
            else { throw }
        }
    }
    foreach ($reservedOutput in $plannedOutputs) { New-ExclusiveFile -Path $reservedOutput }

    $orderPathResult = $null
    if (-not $isAdvise) {
        $orderParameters = @{
            Title        = $Title
            Role         = $Role
            TargetPath   = @($targetPaths.ToArray())
            TaskBody     = $TaskBody
            Acceptance   = @($Acceptance)
            Boundary     = $Boundary
            ReportPath   = $ReportPath
            DispatchSlug = $DispatchSlug
            LineSlug     = $LineSlug
            OutputPath   = $orderPath
        }
        $requiredReadItems = @($RequiredRead | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($requiredReadItems.Count -gt 0) { $orderParameters.RequiredRead = $requiredReadItems }
        $orderRun = Invoke-OrderScript -Parameters $orderParameters
        if ($orderRun.ExitCode -ne 0) {
            $forwarded = $null
            try { $forwarded = $orderRun.Stderr | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $forwarded = $null }
            if ($forwarded -is [System.Collections.IDictionary] -and $forwarded.ContainsKey('code')) {
                $exception = New-Object System.InvalidOperationException([string]$forwarded['message'])
                $exception.Data['operationResult'] = $forwarded
                throw $exception
            }
            Throw-DispatchInputFailure -Code 'DispatchInputOrderFailed' -Classification 'InvalidValue' -Field 'order' -Message ('派遣單產生失敗：' + $orderRun.Stderr) -Detail ([ordered]@{ exit_code = $orderRun.ExitCode })
        }
        $orderPathResult = $orderPath
    }

    $roleText = if ($isAdvise) { if ([string]::IsNullOrWhiteSpace($Role)) { 'advisor' } else { $Role } } else { $Role }
    $titleText = if ($isAdvise) { if ([string]::IsNullOrWhiteSpace($Title)) { 'advisor 諮詢：' + $DispatchSlug } else { $Title } } else { $Title }
    $promptLines = New-Object 'System.Collections.Generic.List[string]'
    $promptLines.Add('# ' + $titleText)
    $promptLines.Add('')
    $promptLines.Add('LineContext')
    $promptLines.Add('')
    $promptLines.Add($lineContextBlock)
    $promptLines.Add('')
    $promptLines.Add('執行角色：' + $roleText)
    if ($isAdvise) {
        $promptLines.Add('證據包：' + $EvidencePackPath)
        $promptLines.Add('回報落點：' + $advisorReportPathValue)
        $promptLines.Add('回報格式：依證據包「待答問題」的 required-output 標題逐一回報，區分證據支持、推論與未決問題。')
        $promptLines.Add('驗收條件：每個 question-<id> 皆有回應，且 required-output 的標題皆存在且內容非空。')
    }
    else {
        $promptLines.Add('派遣單：' + $orderPath)
        $promptLines.Add('回報落點：' + $ReportPath)
        $promptLines.Add('回報格式：逐條列出派遣單第 5 欄命令原文、完整 stdout、完整 stderr、exit code、執行時間、執行狀態與判定結果。')
        $promptLines.Add('驗收條件：')
        for ($index = 0; $index -lt @($Acceptance).Count; $index++) {
            $promptLines.Add(('{0}. [{1}] {2}' -f ($index + 1), [string]$Acceptance[$index]['Category'], [string]$Acceptance[$index]['Condition']))
        }
    }
    Write-OwnedFile -Path $promptPath -Content (($promptLines -join "`r`n") + "`r`n")

    $request = [ordered]@{
        schema               = 'ai-sessions.dispatch-request.v1'
        operation            = 'Dispatch'
        line_slug            = $LineSlug
        dispatch_slug        = $DispatchSlug
        source_root          = $sourceRootPath
        dispatch_root        = $mode.dispatchRoot
        target_path          = @($targetPaths.ToArray())
        write_mode           = 'readonly'
        dispatch_kind        = 'resource'
        prompt_path          = $promptPath
        task_type            = if ($isAdvise) { 'advisor-consult' } else { $TaskType }
        session_mode         = 'cold-start'
        unit_kind            = if ($isAdvise) { 'advisor-evidence-question' } else { 'resource-target' }
        profile              = $Profile
        failure_receipt_path = $failureReceiptPath
        result_path          = $resultPath
        background           = [bool]$Background
    }
    if (-not [string]::IsNullOrWhiteSpace($RequiredIdentifier)) { $request['required_identifier'] = $RequiredIdentifier }
    if (-not [string]::IsNullOrWhiteSpace($CallerSessionId)) { $request['caller_session_id'] = $CallerSessionId }
    if ($isAdvise) {
        $request['advisor_request_source'] = $AdvisorRequestSource
        $request['evidence_pack_path'] = $EvidencePackPath
        $request['advisor_consult_report_path'] = $advisorReportPathValue
    }
    Write-OwnedFile -Path $requestPath -Content (($request | ConvertTo-Json -Depth 8) + "`r`n")

    $validateRun = Invoke-ValidateOnly -RequestPath $requestPath
    $validateDocument = $null
    try { $validateDocument = $validateRun.Stdout | ConvertFrom-Json -ErrorAction Stop } catch { $validateDocument = $null }
    $findings = if ($null -ne $validateDocument -and $null -ne $validateDocument.PSObject.Properties['findings']) { @($validateDocument.findings) } else { @() }
    $errorFindings = @($findings | Where-Object { $_.severity -eq 'error' })
    if ($validateRun.ExitCode -ne 0 -or $null -eq $validateDocument -or $errorFindings.Count -gt 0) {
        Throw-DispatchInputFailure -Code 'DispatchInputSelfCheckFailed' -Classification 'InvalidValue' -Field 'request' -Message ('Request 自檢（-ValidateOnly）失敗，本次建立的檔案已刪除（line.json 為合法的線 manifest，若為本次新建則保留）。exit code ' + $validateRun.ExitCode + '；stderr：' + $validateRun.Stderr.Trim() + '；stdout：' + $validateRun.Stdout.Trim()) -Detail ([ordered]@{ exit_code = $validateRun.ExitCode; findings = @($findings); stderr = $validateRun.Stderr })
    }

    [ordered]@{
        request_path          = $requestPath
        prompt_path          = $promptPath
        order_path           = $orderPathResult
        line_manifest_path   = $lineManifestPath
        line_manifest_created = $lineManifestCreated
        validate_only        = [ordered]@{ exit_code = $validateRun.ExitCode; findings = @($findings) }
    } | ConvertTo-Json -Depth 12
    exit 0
}
catch {
    foreach ($createdFile in $createdFiles) {
        if (Test-Path -LiteralPath $createdFile -PathType Leaf) { Remove-Item -LiteralPath $createdFile -Force -ErrorAction SilentlyContinue }
    }
    $operationResult = $_.Exception.Data['operationResult']
    if ($null -ne $operationResult -and $operationResult -is [System.Collections.IDictionary]) {
        [Console]::Error.WriteLine((ConvertTo-Json -InputObject $operationResult -Depth 10 -Compress))
    }
    else {
        [Console]::Error.WriteLine(("New-DispatchInputs.ps1: {0}" -f $_.Exception.Message))
    }
    exit 1
}
