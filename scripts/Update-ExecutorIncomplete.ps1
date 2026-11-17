#Requires -Version 7.0
<#
.SYNOPSIS
保存同一任務各執行者的未完成次數，並輸出可直接帶給選派入口 -Incomplete 的值。

.DESCRIPTION
次數存在 <WorkRoot>\.local\ai-sessions\report\<LineSlug>\executor-incomplete.json，一條線可有多個任務（-Task）。
腳本只保存與輸出，不判斷該不該計次；計次規則見 rules\claude\30-dispatch.md「執行者轉移」。
Select-DispatchExecutor.ps1 不讀這個檔，協調者把本腳本輸出的 incomplete_argument 傳給它。

-Action Add：把 -ExecutorId 的次數加一，並記錄原因類別與證據位置。執行者 id 必須存在於登錄表。
-Action Show：不寫檔，輸出目前各執行者的次數。
-Action Reset：任務收下後移除該任務的紀錄，次數歸零。

stdout 輸出 ASCII 跳脫的 JSON：
counts：各執行者的次數，依執行者 id 的序數排序，輸出順序固定。
incomplete_argument：可直接作為 -Incomplete 的值，例如 haiku:3,sonnet:1；沒有任何次數時為 null，此時 pass_incomplete 為 false，呼叫選派入口不必帶 -Incomplete。

線識別的驗證：handoff\<LineSlug>\line.json 必須存在且其 line-slug 等於 -LineSlug，缺少或不符時以結束碼 2 拒絕；一次性工作也須先登記為 kind 為 adhoc 的線。
結束碼：0 成功；2 輸入無效；1 其他錯誤。

.PARAMETER Action
Add、Show 或 Reset。

.PARAMETER WorkRoot
線所在的 work-root。

.PARAMETER LineSlug
線識別。

.PARAMETER Task
任務識別（小寫英數與連字號），同一線內以此區分任務。Workflow 的 Developer 派工整體算一個任務。

.PARAMETER ExecutorId
Add 時必填，登錄表內的執行者 id。

.PARAMETER Reason
Add 時必填，未完成的原因類別：acceptance-failed（驗收條件未通過）、collect-returned（回收退回）、review-rejected（審查以未閉合的 Critical 或 Major 退回）、self-reported（執行者自述無法完成）。

.PARAMETER Evidence
Add 時必填，證據位置（檔案與行號，或命令原文與輸出位置）。

.PARAMETER RegistryPath
執行者登錄表路徑，測試與診斷用。預設為 scripts\dispatch\executor-registry.json。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Add', 'Show', 'Reset')]
    [string]$Action,

    [Parameter(Mandatory)]
    [string]$WorkRoot,

    [Parameter(Mandatory)]
    [string]$LineSlug,

    [Parameter(Mandatory)]
    [string]$Task,

    [string]$ExecutorId,

    [ValidateSet('acceptance-failed', 'collect-returned', 'review-rejected', 'self-reported')]
    [string]$Reason,

    [string]$Evidence,

    [string]$RegistryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)

. (Join-Path $PSScriptRoot 'codex-run\00-common.ps1')
. (Join-Path $PSScriptRoot 'lib\executor-registry.ps1')

$slugPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'
$schema = 'ai-agents.executor-incomplete.v1'

function ConvertTo-IncompleteOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ActionName,
        [Parameter(Mandatory)][string]$FilePath,
        [AllowNull()][System.Collections.IDictionary]$Counts
    )

    $ordered = New-Object 'System.Collections.Generic.List[object]'
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $Counts) {
        $ids = [string[]]@($Counts.Keys)
        [Array]::Sort($ids, [StringComparer]::Ordinal)
        foreach ($id in $ids) {
            $count = [int]$Counts[$id]
            if ($count -le 0) { continue }
            $ordered.Add([ordered]@{ executor = [string]$id; count = $count })
            $parts.Add(([string]$id) + ':' + $count)
        }
    }
    $argument = if ($parts.Count -gt 0) { $parts -join ',' } else { $null }
    return [ordered]@{
        schema = $schema
        action = $ActionName
        line_slug = $LineSlug
        task = $Task
        file = $FilePath
        counts = @($ordered.ToArray())
        incomplete_argument = $argument
        pass_incomplete = ($null -ne $argument)
        note = if ($null -ne $argument) { '呼叫選派入口時帶 -Incomplete ' + $argument } else { '所有執行者的未完成次數皆為 0，呼叫選派入口不必帶 -Incomplete。' }
    }
}

function Read-IncompleteState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Slug
    )

    # 讀取並逐層驗證計次檔，回傳 tasks（每個任務為 counts 與 events）。檔案不存在回傳空集合；任何一層結構不符都拒絕，呼叫端不得在此狀態下寫檔。
    $tasks = [ordered]@{}
    if (-not [IO.File]::Exists($Path)) { return $tasks }
    $invalid = { param([string]$Why) New-RunError -Code 'IncompleteFileInvalid' -Message ('executor-incomplete.json 結構不符（' + $Why + '），未改動：' + $Path) -ExitCode 2 }
    try {
        $document = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))) -AsHashtable -Depth 20
    }
    catch { throw (New-RunError -Code 'IncompleteFileInvalid' -Message ('executor-incomplete.json 無法解析，未改動：' + $Path + '；' + $_.Exception.Message) -ExitCode 2) }
    if ($document -isnot [System.Collections.IDictionary] -or $document['schema'] -cne $schema -or $document['line_slug'] -cne $Slug -or $document['tasks'] -isnot [System.Collections.IDictionary]) {
        throw (& $invalid 'schema、line_slug 或 tasks')
    }
    foreach ($taskKey in $document['tasks'].Keys) {
        $entry = $document['tasks'][$taskKey]
        if ([string]$taskKey -cnotmatch $slugPattern) { throw (& $invalid ('任務名稱 ' + $taskKey)) }
        if ($entry -isnot [System.Collections.IDictionary] -or $entry['counts'] -isnot [System.Collections.IDictionary] -or $null -eq $entry['events'] -or $entry['events'] -is [string] -or $entry['events'] -isnot [System.Collections.IEnumerable] -or $entry['events'] -is [System.Collections.IDictionary]) {
            throw (& $invalid ('任務 ' + $taskKey + ' 的 counts 或 events'))
        }
        $counts = [ordered]@{}
        foreach ($executorKey in $entry['counts'].Keys) {
            $value = $entry['counts'][$executorKey]
            if ([string]$executorKey -cnotmatch $slugPattern -or ($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt [int]::MaxValue) {
                throw (& $invalid ('任務 ' + $taskKey + ' 的次數 ' + $executorKey))
            }
            $counts[[string]$executorKey] = [int]$value
        }
        $events = New-Object 'System.Collections.Generic.List[object]'
        foreach ($event in $entry['events']) {
            if ($event -isnot [System.Collections.IDictionary]) { throw (& $invalid ('任務 ' + $taskKey + ' 的事件')) }
            $events.Add($event)
        }
        $tasks[[string]$taskKey] = [ordered]@{ counts = $counts; events = @($events.ToArray()) }
    }
    return $tasks
}

try {
    if ($LineSlug -cnotmatch $slugPattern) { throw (New-RunError -Code 'IncompleteLineSlugInvalid' -Message ('LineSlug 格式無效：' + $LineSlug) -ExitCode 2) }
    if ($Task -cnotmatch $slugPattern) { throw (New-RunError -Code 'IncompleteTaskInvalid' -Message ('Task 必須符合 ' + $slugPattern + '：' + $Task) -ExitCode 2) }
    if (-not [IO.Directory]::Exists($WorkRoot)) { throw (New-RunError -Code 'IncompleteWorkRootMissing' -Message ('WorkRoot 不存在：' + $WorkRoot) -ExitCode 2) }
    if ($Action -cne 'Add') {
        foreach ($name in @('ExecutorId', 'Reason', 'Evidence')) {
            if ($PSBoundParameters.ContainsKey($name)) { throw (New-RunError -Code 'IncompleteParameterUnexpected' -Message ('-' + $name + ' 只在 -Action Add 使用。') -ExitCode 2) }
        }
    }

    $sessions = Join-Path (Join-Path $WorkRoot '.local') 'ai-sessions'
    $lineJson = Join-Path (Join-Path (Join-Path $sessions 'handoff') $LineSlug) 'line.json'
    if (-not [IO.File]::Exists($lineJson)) { throw (New-RunError -Code 'IncompleteLineManifestMissing' -Message ('找不到同線的 line.json：' + $lineJson + '。請先登記線（一次性工作登記為 kind 為 adhoc 的線）。') -ExitCode 2) }
    try {
        $manifest = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($lineJson, (New-Object System.Text.UTF8Encoding -ArgumentList @($false))))
    }
    catch { throw (New-RunError -Code 'IncompleteLineManifestInvalid' -Message ('line.json 無法解析：' + $lineJson + '；' + $_.Exception.Message) -ExitCode 2) }
    $slugProperty = $manifest.PSObject.Properties['line-slug']
    $manifestSlug = if ($null -ne $slugProperty) { [string]$slugProperty.Value } else { $null }
    if ($manifestSlug -cne $LineSlug) { throw (New-RunError -Code 'IncompleteLineManifestMismatch' -Message ('line.json 的 line-slug（' + $manifestSlug + '）與 -LineSlug（' + $LineSlug + '）不一致：' + $lineJson) -ExitCode 2) }

    $reportRoot = Join-Path (Join-Path $sessions 'report') $LineSlug
    $filePath = Join-Path $reportRoot 'executor-incomplete.json'

    # 讀改寫全程持有線層排他鎖；目錄不存在時（尚無任何紀錄）Show 與 Reset 不需要鎖，也不建立目錄。
    $registry = $null
    if ($Action -ceq 'Add') {
        foreach ($name in @('ExecutorId', 'Reason', 'Evidence')) {
            if (-not $PSBoundParameters.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string](Get-Variable -Name $name -ValueOnly))) {
                throw (New-RunError -Code 'IncompleteParameterMissing' -Message ('-Action Add 必須提供 -' + $name + '。') -ExitCode 2)
            }
        }
        $registryFile = $RegistryPath
        if ([string]::IsNullOrWhiteSpace($registryFile)) { $registryFile = Join-Path $PSScriptRoot 'dispatch\executor-registry.json' }
        try { $registry = Read-ExecutorRegistry -Path $registryFile }
        catch { throw (New-RunError -Code 'IncompleteRegistryInvalid' -Message ('無法讀取執行者登錄表：' + $_.Exception.Message) -ExitCode 2) }
        if (-not $registry.ById.ContainsKey($ExecutorId)) { throw (New-RunError -Code 'IncompleteExecutorUnknown' -Message ('登錄表沒有執行者：' + $ExecutorId) -ExitCode 2) }
        $null = [IO.Directory]::CreateDirectory($reportRoot)
    }
    $lock = $null
    $counts = [ordered]@{}
    try {
        if ([IO.Directory]::Exists($reportRoot)) { $lock = Enter-RunFileLock -Path (Join-Path $reportRoot 'executor-incomplete.lock') }
        $tasks = Read-IncompleteState -Path $filePath -Slug $LineSlug
        $taskEntry = if ($tasks.Contains($Task)) { $tasks[$Task] } else { $null }
        if ($null -ne $taskEntry) { $counts = $taskEntry['counts'] }

        if ($Action -ceq 'Add') {
            $current = if ($counts.Contains($ExecutorId)) { [int]$counts[$ExecutorId] } else { 0 }
            if ($current -ge $registry.IncompleteLimit) { throw (New-RunError -Code 'IncompleteCountOverflow' -Message ('執行者 ' + $ExecutorId + ' 的次數已達上限 ' + $registry.IncompleteLimit) -ExitCode 2) }
            $counts[$ExecutorId] = $current + 1
            $events = @(if ($null -ne $taskEntry) { $taskEntry['events'] })
            $events += [ordered]@{ at_utc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture); executor = $ExecutorId; reason = $Reason; evidence = $Evidence }
            $tasks[$Task] = [ordered]@{ counts = $counts; events = $events }
            Write-RunJsonAtomic -Path $filePath -InputObject ([ordered]@{ schema = $schema; line_slug = $LineSlug; tasks = $tasks }) -Depth 8
        }
        elseif ($Action -ceq 'Reset') {
            if ($tasks.Contains($Task)) {
                $tasks.Remove($Task)
                Write-RunJsonAtomic -Path $filePath -InputObject ([ordered]@{ schema = $schema; line_slug = $LineSlug; tasks = $tasks }) -Depth 8
            }
            $counts = [ordered]@{}
        }
    }
    finally { if ($null -ne $lock) { $lock.Dispose() } }
    [Console]::Out.WriteLine((ConvertTo-AsciiJson -InputObject (ConvertTo-IncompleteOutput -ActionName $Action -FilePath $filePath -Counts $counts) -Depth 6 -Compress))
    exit 0
}
catch {
    $exception = $_.Exception
    if ($exception.Data.Contains('Code')) {
        [Console]::Error.WriteLine('[executor-incomplete] ' + $exception.Message)
        exit ([int]$exception.Data['ExitCode'])
    }
    [Console]::Error.WriteLine('[executor-incomplete] 未預期的錯誤：' + $exception.Message)
    exit 1
}
