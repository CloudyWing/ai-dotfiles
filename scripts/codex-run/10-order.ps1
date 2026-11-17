#Requires -Version 7.0
# 派遣檔解析與啟動前檢查。依賴 00-common.ps1。

function Get-RunTaskTypeSetting {
    [CmdletBinding()]
    param(
        [string]$TaskType
    )

    # 新入口受理的 task_type 與各自的差異。不帶參數時回傳全部設定，帶參數且不受理時回傳 $null。
    # search：在 exec 前加 --search（Codex 的官方查證工具，不開 shell 網路）。
    # generated_images：把選定帳號 CODEX_HOME 下的 generated_images 列為可讀，影像先產在該處再由 Codex 複製到輸出目錄。
    # report_check：成功後對報告做的結構檢查，review-manifest 為 Test-RunReviewReport，$null 為只檢查報告存在且非空。
    # executor_label：prompt 中標明實際執行者那一行的標籤，由執行端照抄到報告。
    # evidence_only：資料全文內嵌 prompt、不開放工作目錄（可讀可寫根目錄只有輸出目錄，--cd 指向輸出目錄）、最後訊息存成報告、派遣檔須宣告
    #   advisor_request_source、evidence_file、question_ids，結束時檢查報告含每個題號。其他類型不得出現這三個鍵。
    # exclusive_profile：該類型只接受的檔位；$null 表示不限，但不得使用其他類型的專屬檔位。
    $settings = [ordered]@{
        review = [pscustomobject]@{ search = $false; generated_images = $false; report_check = 'review-manifest'; executor_label = '審查者'; evidence_only = $false; exclusive_profile = $null }
        factcheck = [pscustomobject]@{ search = $true; generated_images = $false; report_check = $null; executor_label = '執行者'; evidence_only = $false; exclusive_profile = $null }
        generate = [pscustomobject]@{ search = $false; generated_images = $true; report_check = $null; executor_label = '執行者'; evidence_only = $false; exclusive_profile = $null }
        advise = [pscustomobject]@{ search = $false; generated_images = $false; report_check = $null; executor_label = '執行者'; evidence_only = $true; exclusive_profile = 'advisor' }
    }
    if (-not $PSBoundParameters.ContainsKey('TaskType')) { return $settings }
    # OrderedDictionary 的鍵查詢不分大小寫，先以區分大小寫的比對確認受理。
    if ([string]::IsNullOrEmpty($TaskType) -or @($settings.Keys) -cnotcontains $TaskType) { return $null }
    return $settings[$TaskType]
}

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
    $knownKeys = @('schema', 'line_slug', 'dispatch_slug', 'task_type', 'profile', 'role_file', 'execution_root', 'report_line_root', 'report_name', 'targets', 'required_reads', 'cycle', 'advisor_request_source', 'evidence_file', 'question_ids')
    $evidenceKeys = @('advisor_request_source', 'evidence_file', 'question_ids')
    $requiredKeys = @($knownKeys | Where-Object { $_ -cne 'cycle' -and $evidenceKeys -cnotcontains $_ })
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
    # 型別先檢查：-cne 對陣列是篩選而不是比較，陣列值會被當成不成立而放行。
    if ($presentKeys -ccontains 'schema' -and ($schemaValue -isnot [string] -or $schemaValue -cne 'ai-agents.codex-run-order.v1')) {
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
    if ($presentKeys -ccontains 'profile') {
        # 檔位名稱只由登錄表決定（依賴 45-profile-sync.ps1，由入口一併載入）。
        $profileNames = @()
        try { $profileNames = @(Get-CodexProfileName -RegistryPath (Get-CodexProfileRegistryPath)) }
        catch { $errors.Add('無法由登錄表取得檔位清單：' + $_.Exception.Message) }
        if ($profileNames.Count -gt 0 -and $profileNames -cnotcontains $profile) {
            $errors.Add('profile 必須是登錄表內的檔位之一（' + ($profileNames -join '、') + '）。')
        }
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
    $taskSetting = Get-RunTaskTypeSetting -TaskType $taskType
    if ($null -eq $taskSetting) {
        throw (New-RunError -Code 'RunTaskTypeUnsupported' -Message ('task_type 只接受 ' + (@((Get-RunTaskTypeSetting).Keys) -join '、') + '，收到：' + $taskType) -ExitCode 2)
    }
    # 類型與檔位綁定：專屬檔位只接受對應類型，其他類型不得使用任何類型的專屬檔位。
    $exclusiveProfiles = @((Get-RunTaskTypeSetting).Values | Where-Object { $null -ne $_.exclusive_profile } | ForEach-Object { [string]$_.exclusive_profile })
    if ($null -ne $taskSetting.exclusive_profile -and [string]$profile -cne [string]$taskSetting.exclusive_profile) {
        throw (New-RunError -Code 'RunTaskProfileMismatch' -Message ('task_type ' + $taskType + ' 只接受檔位 ' + $taskSetting.exclusive_profile + '，收到：' + $profile) -ExitCode 2)
    }
    if ($null -eq $taskSetting.exclusive_profile -and $exclusiveProfiles -ccontains [string]$profile) {
        throw (New-RunError -Code 'RunTaskProfileMismatch' -Message ('檔位 ' + $profile + ' 只接受專屬的 task_type，收到：' + $taskType) -ExitCode 2)
    }
    if ($taskSetting.evidence_only) {
        # 授權：顧問每次都要使用者當輪授權，缺少或不是 user-explicit 時停止，不啟動 Codex。
        $source = Get-FieldValue 'advisor_request_source'
        if ($presentKeys -cnotcontains 'advisor_request_source' -or $source -isnot [string] -or $source -cne 'user-explicit') {
            throw (New-RunError -Code 'RunAdvisorAuthorizationRequired' -Message ('task_type ' + $taskType + ' 須由使用者當輪授權：advisor_request_source 必須是 user-explicit。') -ExitCode 2)
        }
        $evidenceErrors = New-Object 'System.Collections.Generic.List[string]'
        foreach ($key in @('evidence_file', 'question_ids')) {
            if ($presentKeys -cnotcontains $key) { $evidenceErrors.Add('缺少欄位：' + $key) }
        }
        $evidenceFile = Get-FieldValue 'evidence_file'
        if ($presentKeys -ccontains 'evidence_file' -and ($evidenceFile -isnot [string] -or [string]::IsNullOrWhiteSpace($evidenceFile))) { $evidenceErrors.Add('evidence_file 必須是非空字串。') }
        $questionValue = Get-FieldValue 'question_ids'
        if ($presentKeys -ccontains 'question_ids') {
            if ($questionValue -isnot [array] -or @($questionValue).Count -eq 0 -or @($questionValue | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) -or $_ -match '\s' }).Count -gt 0) {
                $evidenceErrors.Add('question_ids 必須是非空陣列，每個元素是不含空白的非空字串。')
            }
        }
        if (@($document.required_reads).Count -gt 0) { $evidenceErrors.Add('task_type ' + $taskType + ' 不開放讀檔，required_reads 必須是空陣列。') }
        if ($evidenceErrors.Count -gt 0) {
            throw (New-RunError -Code 'RunDispatchFileInvalid' -Message ('派遣檔無效：' + ($evidenceErrors -join '；')) -ExitCode 2 -Details @($evidenceErrors.ToArray()))
        }
    }
    else {
        $strayKeys = @($evidenceKeys | Where-Object { $presentKeys -ccontains $_ })
        if ($strayKeys.Count -gt 0) {
            throw (New-RunError -Code 'RunDispatchFileInvalid' -Message ('派遣檔無效：task_type ' + $taskType + ' 不得出現欄位 ' + ($strayKeys -join '、') + '。') -ExitCode 2 -Details @($strayKeys | ForEach-Object { '不適用欄位：' + $_ }))
        }
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
        advisor_request_source = if ($taskSetting.evidence_only) { [string](Get-FieldValue 'advisor_request_source') } else { $null }
        evidence_file = if ($taskSetting.evidence_only) { [string](Get-FieldValue 'evidence_file') } else { $null }
        question_ids = if ($taskSetting.evidence_only) { [string[]]@($document.question_ids) } else { [string[]]@() }
        dispatch_file_path = $Path
        task_setting = $taskSetting
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
    if ($Order.task_setting.evidence_only) {
        # evidence 檔只檢查存在且非空，不驗證內容格式。
        $evidencePath = [string]$Order.evidence_file
        $checkedPaths.Add($evidencePath)
        if ((Test-Absolute $evidencePath) -and [IO.File]::Exists($evidencePath) -and (New-Object System.IO.FileInfo -ArgumentList @($evidencePath)).Length -eq 0) { Add-Problem $evidencePath 'empty' }
    }
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
