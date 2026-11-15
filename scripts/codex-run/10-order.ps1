#Requires -Version 7.0
# 派遣檔解析與啟動前檢查。依賴 00-common.ps1。

function Read-RunDispatchFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not [IO.File]::Exists($Path)) {
        throw (New-RunError -Code 'RunDispatchFileInvalid' -Message ('派遣檔不存在：' + $Path) -ExitCode 2)
    }
    $text = [IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

    $heading = [regex]::Match($text, '(?m)^##[ \t]+派遣設定[ \t]*\r?$')
    if (-not $heading.Success) {
        throw (New-RunError -Code 'RunDispatchFileInvalid' -Message '派遣檔缺少「## 派遣設定」標題。' -ExitCode 2)
    }
    $section = $text.Substring($heading.Index + $heading.Length)
    $nextHeading = [regex]::Match($section, '(?m)^##[ \t]+')
    if ($nextHeading.Success) { $section = $section.Substring(0, $nextHeading.Index) }
    $block = [regex]::Match($section, '(?ms)^```json[ \t]*\r?\n(?<json>.*?)^```[ \t]*\r?$')
    if (-not $block.Success) {
        throw (New-RunError -Code 'RunDispatchFileInvalid' -Message '「## 派遣設定」之下沒有 json 區塊。' -ExitCode 2)
    }
    try {
        $document = ConvertFrom-Json -InputObject $block.Groups['json'].Value -Depth 20
    }
    catch {
        throw (New-RunError -Code 'RunDispatchFileInvalid' -Message ('派遣設定的 JSON 無法解析：' + $_.Exception.Message) -ExitCode 2)
    }
    if ($document -isnot [pscustomobject]) {
        throw (New-RunError -Code 'RunDispatchFileInvalid' -Message '派遣設定必須是 JSON 物件。' -ExitCode 2)
    }

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $knownKeys = @('schema', 'line_slug', 'dispatch_slug', 'task_type', 'profile', 'role_file', 'execution_root', 'report_line_root', 'report_name', 'targets', 'required_reads', 'cycle')
    $requiredKeys = @($knownKeys | Where-Object { $_ -cne 'cycle' })
    $presentKeys = @($document.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($key in $presentKeys) {
        if ($knownKeys -cnotcontains $key) { $errors.Add('未知欄位：' + $key) }
    }
    foreach ($key in $requiredKeys) {
        if ($presentKeys -cnotcontains $key) { $errors.Add('缺少欄位：' + $key) }
    }

    function Get-FieldValue([string]$Name) {
        $property = $document.PSObject.Properties[$Name]
        if ($null -eq $property) { return $null }
        return , $property.Value
    }
    $slugPattern = '^[a-z0-9]+(?:-[a-z0-9]+)*$'
    $schemaValue = Get-FieldValue 'schema'
    if ($presentKeys -ccontains 'schema' -and $schemaValue -cne 'ai-agents.codex-run-order.v1') {
        $errors.Add('schema 必須是 ai-agents.codex-run-order.v1。')
    }
    foreach ($slugField in @('line_slug', 'dispatch_slug')) {
        $value = Get-FieldValue $slugField
        if ($presentKeys -ccontains $slugField -and ($value -isnot [string] -or $value -cnotmatch $slugPattern)) {
            $errors.Add($slugField + ' 必須符合 ' + $slugPattern)
        }
    }
    $taskType = Get-FieldValue 'task_type'
    if ($presentKeys -ccontains 'task_type' -and ($taskType -isnot [string] -or [string]::IsNullOrWhiteSpace($taskType))) {
        $errors.Add('task_type 必須是非空字串。')
    }
    $profile = Get-FieldValue 'profile'
    if ($presentKeys -ccontains 'profile' -and (@('review', 'scan', 'content', 'advisor') -cnotcontains $profile)) {
        $errors.Add('profile 必須是 review、scan、content、advisor 之一。')
    }
    foreach ($stringField in @('role_file', 'execution_root', 'report_line_root', 'report_name')) {
        $value = Get-FieldValue $stringField
        if ($presentKeys -ccontains $stringField -and ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value))) {
            $errors.Add($stringField + ' 必須是非空字串。')
        }
    }
    $reportName = Get-FieldValue 'report_name'
    if ($reportName -is [string] -and -not [string]::IsNullOrWhiteSpace($reportName) -and
        ($reportName -match '[\\/:]' -or $reportName -ceq '.' -or $reportName -ceq '..')) {
        $errors.Add('report_name 只能是檔名，不含路徑分隔字元。')
    }
    foreach ($arrayField in @('targets', 'required_reads')) {
        if ($presentKeys -cnotcontains $arrayField) { continue }
        $value = Get-FieldValue $arrayField
        if ($value -isnot [array]) {
            $errors.Add($arrayField + ' 必須是陣列。')
            continue
        }
        if (@($value | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            $errors.Add($arrayField + ' 的每個元素必須是非空字串。')
        }
        if ($arrayField -ceq 'targets' -and @($value).Count -eq 0) {
            $errors.Add('targets 不可為空。')
        }
    }
    $cycle = $null
    if ($presentKeys -ccontains 'cycle') {
        $cycleValue = Get-FieldValue 'cycle'
        if ($cycleValue -isnot [pscustomobject]) {
            $errors.Add('cycle 必須是物件。')
        }
        else {
            $cycleKeys = @($cycleValue.PSObject.Properties | ForEach-Object { $_.Name })
            foreach ($key in $cycleKeys) {
                if (@('id', 'round', 'role') -cnotcontains $key) { $errors.Add('cycle 的未知欄位：' + $key) }
            }
            foreach ($key in @('id', 'round', 'role')) {
                if ($cycleKeys -cnotcontains $key) { $errors.Add('cycle 缺少欄位：' + $key) }
            }
            if ($cycleKeys -ccontains 'id' -and ($cycleValue.id -isnot [string] -or [string]::IsNullOrWhiteSpace($cycleValue.id))) { $errors.Add('cycle.id 必須是非空字串。') }
            if ($cycleKeys -ccontains 'role' -and ($cycleValue.role -isnot [string] -or [string]::IsNullOrWhiteSpace($cycleValue.role))) { $errors.Add('cycle.role 必須是非空字串。') }
            if ($cycleKeys -ccontains 'round' -and (($cycleValue.round -isnot [int] -and $cycleValue.round -isnot [long]) -or [long]$cycleValue.round -lt 1)) { $errors.Add('cycle.round 必須是正整數。') }
            $cycle = $cycleValue
        }
    }
    if ($errors.Count -gt 0) {
        throw (New-RunError -Code 'RunDispatchFileInvalid' -Message ('派遣檔無效：' + ($errors -join '；')) -ExitCode 2 -Details @($errors.ToArray()))
    }
    if ($taskType -cne 'review') {
        throw (New-RunError -Code 'RunTaskTypeUnsupported' -Message ('task_type 目前只接受 review，收到：' + $taskType) -ExitCode 2)
    }

    return [pscustomobject]@{
        schema = [string]$schemaValue
        line_slug = [string](Get-FieldValue 'line_slug')
        dispatch_slug = [string](Get-FieldValue 'dispatch_slug')
        task_type = [string]$taskType
        profile = [string]$profile
        role_file = [string](Get-FieldValue 'role_file')
        execution_root = [string](Get-FieldValue 'execution_root')
        report_line_root = [string](Get-FieldValue 'report_line_root')
        report_name = [string]$reportName
        targets = [string[]]@($document.targets)
        required_reads = [string[]]@($document.required_reads)
        cycle = $cycle
        dispatch_file_path = $Path
    }
}

function Test-RunPreStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Order,

        [string]$AiAgentsRoot = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ai-agents')
    )

    # 逐一檢查後一次丟出 RunPathsInvalid。本函式只讀取檔案系統，不建立任何目錄或檔案。
    $problems = New-Object 'System.Collections.Generic.List[object]'
    function Add-Problem([string]$Path, [string]$Reason) {
        if (@($problems | Where-Object { $_.path -ceq $Path -and $_.reason -ceq $Reason }).Count -gt 0) { return }
        $problems.Add([pscustomobject]@{ path = $Path; reason = $Reason })
    }
    function Test-Absolute([string]$Path) {
        return [IO.Path]::IsPathFullyQualified($Path)
    }

    $executionRoot = [string]$Order.execution_root
    $reportLineRoot = [string]$Order.report_line_root
    foreach ($rootEntry in @(@($executionRoot, 'execution_root'), @($reportLineRoot, 'report_line_root'))) {
        $rootPath = [string]$rootEntry[0]
        if (-not (Test-Absolute $rootPath)) { Add-Problem $rootPath 'not-absolute'; continue }
        if (-not [IO.Directory]::Exists($rootPath)) { Add-Problem $rootPath 'missing' }
        if (-not (Test-RunPathCmdSafe -Path $rootPath)) { Add-Problem $rootPath 'unsafe-char' }
    }
    if (-not (Test-RunPathCmdSafe -Path ([string]$Order.report_name))) {
        Add-Problem ([string]$Order.report_name) 'unsafe-char'
    }
    # 權限設定的參數也含 ~\.ai-agents 的路徑，含不安全字元時在此拒絕，不留到建立輸出目錄之後。
    if ((Test-Absolute $AiAgentsRoot) -and -not (Test-RunPathCmdSafe -Path $AiAgentsRoot)) { Add-Problem $AiAgentsRoot 'unsafe-char' }

    $readableRoots = @()
    foreach ($root in @($executionRoot, $AiAgentsRoot, $reportLineRoot)) {
        if (Test-Absolute $root) { $readableRoots += $root }
    }
    $checkedPaths = New-Object 'System.Collections.Generic.List[string]'
    $checkedPaths.Add([string]$Order.role_file)
    foreach ($read in @($Order.required_reads)) { $checkedPaths.Add([string]$read) }
    foreach ($target in @($Order.targets)) { $checkedPaths.Add([string]$target) }
    $checkedPaths.Add([string]$Order.dispatch_file_path)
    foreach ($path in $checkedPaths) {
        if (-not (Test-Absolute $path)) { Add-Problem $path 'not-absolute'; continue }
        $exists = [IO.File]::Exists($path) -or [IO.Directory]::Exists($path)
        if (-not $exists) { Add-Problem $path 'missing' }
        $leaf = [IO.Path]::GetFileName($path.TrimEnd([char[]]@('\', '/')))
        if (Test-RunDenyPatternName -Name $leaf) { Add-Problem $path 'denied-pattern' }
        $inside = $false
        foreach ($root in $readableRoots) {
            if (Test-RunPathUnder -Path $path -Root $root) { $inside = $true; break }
        }
        if (-not $inside) { Add-Problem $path 'outside-readable-roots' }
    }

    if ($problems.Count -gt 0) {
        $lines = @($problems | ForEach-Object { $_.path + ' (' + $_.reason + ')' })
        throw (New-RunError -Code 'RunPathsInvalid' -Message ('啟動前檢查有 ' + $problems.Count + ' 個問題：' + ($lines -join '；')) -ExitCode 2 -Details @($problems.ToArray()))
    }
}
