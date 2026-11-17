#Requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$moduleRoot = Join-Path $scriptsRoot 'codex-run'
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
. (Join-Path $moduleRoot '00-common.ps1')
. (Join-Path $moduleRoot '10-order.ps1')
. (Join-Path $moduleRoot '45-profile-sync.ps1')
. (Join-Path $moduleRoot '70-run.ps1')

try {
    $root = New-TestDirectory -Name 'order'
    $exec = Join-Path $root 'exec'
    $aiRoot = Join-Path $root 'ai-agents'
    $reportRoot = Join-Path $root 'report\line-a'
    $outside = Join-Path $root 'outside'
    foreach ($dir in @($exec, $aiRoot, $reportRoot, $outside, (Join-Path $exec 'src'))) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $roleFile = Join-Path $aiRoot 'reviewer.toml'
    $designFile = Join-Path $reportRoot 'design.md'
    $targetFile = Join-Path $exec 'src\a.txt'
    foreach ($file in @($roleFile, $designFile, $targetFile)) { Write-TestUtf8 -Path $file -Text 'x' }

    function New-OrderSetting {
        param([hashtable]$Override = @{}, [string[]]$Remove = @())
        $setting = [ordered]@{
            schema = 'ai-agents.codex-run-order.v1'
            line_slug = 'line-a'
            dispatch_slug = 'review-p1'
            task_type = 'review'
            profile = 'review'
            role_file = $roleFile
            execution_root = $exec
            report_line_root = $reportRoot
            report_name = 'review-report.md'
            targets = @(($exec + '\src\'), $targetFile)
            required_reads = @($designFile)
            cycle = [ordered]@{ id = 'line-a-review'; round = 1; role = 'review' }
        }
        foreach ($key in $Override.Keys) { $setting[$key] = $Override[$key] }
        foreach ($key in $Remove) { $setting.Remove($key) }
        return $setting
    }
    function Write-OrderFile {
        param([hashtable]$Override = @{}, [string[]]$Remove = @(), [string]$Name = 'order.md', [string]$RawJson)
        $json = if ($PSBoundParameters.ContainsKey('RawJson')) { $RawJson } else { ConvertTo-Json -InputObject (New-OrderSetting -Override $Override -Remove $Remove) -Depth 6 }
        $text = "# 派遣檔：review-p1`n`n## 派遣設定`n`n``````json`n$json`n```````n`n## 任務`n`n審查 src。`n"
        $path = Join-Path $reportRoot $Name
        Write-TestUtf8 -Path $path -Text $text
        return $path
    }
    $evidenceFile = Join-Path $reportRoot 'evidence.md'
    Write-TestUtf8 -Path $evidenceFile -Text "# evidence`n`n問題 Q1、Q2。`n"
    $adviseExtra = @{ advisor_request_source = 'user-explicit'; evidence_file = $evidenceFile; question_ids = @('Q1', 'Q2'); required_reads = @(); targets = @($evidenceFile) }
    function Write-AdviseOrder {
        param([hashtable]$Override = @{}, [string[]]$Remove = @(), [string]$Name = 'advise.md')
        $merged = @{ task_type = 'advise'; profile = 'advisor' } + $adviseExtra
        foreach ($key in $Override.Keys) { $merged[$key] = $Override[$key] }
        return (Write-OrderFile -Override $merged -Remove $Remove -Name $Name)
    }
    function Get-PreStartDetails {
        param([string]$Path)
        $order = Read-RunDispatchFile -Path $Path
        $caught = Assert-Throws -Code 'RunPathsInvalid' -Script { Test-RunPreStart -Order $order -AiAgentsRoot $aiRoot }
        return @($caught.Data['Details'])
    }

    Test-Case 'ORDER-PARSE 合法派遣檔解析出全部欄位' {
        $order = Read-RunDispatchFile -Path (Write-OrderFile)
        Assert-Equal 'ai-agents.codex-run-order.v1' $order.schema
        Assert-Equal 'line-a' $order.line_slug
        Assert-Equal 'review-p1' $order.dispatch_slug
        Assert-Equal 'review' $order.task_type
        Assert-Equal 'review' $order.profile
        Assert-Equal $roleFile $order.role_file
        Assert-Equal $exec $order.execution_root
        Assert-Equal $reportRoot $order.report_line_root
        Assert-Equal 'review-report.md' $order.report_name
        Assert-Equal @(($exec + '\src\'), $targetFile) @($order.targets)
        Assert-Equal @($designFile) @($order.required_reads)
        Assert-Equal 'line-a-review' $order.cycle.id
        Assert-Equal 1 ([int]$order.cycle.round)
        Assert-Equal 'review' $order.cycle.role
    }
    Test-Case 'ORDER-CYCLE-ABSENT cycle 缺少時為 null' {
        $order = Read-RunDispatchFile -Path (Write-OrderFile -Remove @('cycle'))
        Assert-True ($null -eq $order.cycle)
    }
    Test-Case 'ORDER-READS-EMPTY required_reads 為空合法' {
        $path = Write-OrderFile -Override @{ required_reads = @() }
        $order = Read-RunDispatchFile -Path $path
        Assert-Equal 0 (@($order.required_reads).Count)
        Test-RunPreStart -Order $order -AiAgentsRoot $aiRoot
    }
    Test-Case 'ORDER-PRESTART-OK 合法派遣檔通過啟動前檢查' {
        $order = Read-RunDispatchFile -Path (Write-OrderFile)
        Test-RunPreStart -Order $order -AiAgentsRoot $aiRoot
    }
    Test-Case 'ORDER-PRESTART-THREE-MISSING 同時缺少 3 個路徑時 details 恰 3 筆且皆為 missing' {
        $missingRole = Join-Path $aiRoot 'absent-role.toml'
        $missingRead = Join-Path $reportRoot 'absent-design.md'
        $missingTarget = Join-Path $exec 'src\absent.txt'
        $path = Write-OrderFile -Override @{ role_file = $missingRole; required_reads = @($missingRead); targets = @($missingTarget) }
        $details = Get-PreStartDetails -Path $path
        Assert-Equal 3 ($details.Count)
        Assert-Equal @('missing', 'missing', 'missing') @($details | ForEach-Object { $_.reason })
        Assert-Equal @($missingRole, $missingRead, $missingTarget) @($details | ForEach-Object { $_.path })
    }
    Test-Case 'ORDER-UNKNOWN-KEY 未知鍵 required_read 以 RunDispatchFileInvalid 拒絕且訊息含鍵名' {
        $setting = New-OrderSetting -Remove @('required_reads')
        $setting['required_read'] = @($designFile)
        $path = Write-OrderFile -RawJson (ConvertTo-Json -InputObject $setting -Depth 6)
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains 'required_read' -Script { Read-RunDispatchFile -Path $path }
    }
    Test-Case 'ORDER-TASK-TYPE task_type 為 test 或未知值以 RunTaskTypeUnsupported 拒絕' {
        foreach ($type in @('test', 'Review', 'edit')) {
            $path = Write-OrderFile -Override @{ task_type = $type } -Name ('type-' + $type + '.md')
            $null = Assert-Throws -Code 'RunTaskTypeUnsupported' -MessageContains $type -Script { Read-RunDispatchFile -Path $path }
        }
    }
    Test-Case 'ORDER-TASK-SETTING review、factcheck、generate、advise 通過解析並帶出各自的設定' {
        $expected = @{
            review = @{ search = $false; generated_images = $false; report_check = 'review-manifest'; executor_label = '審查者'; evidence_only = $false; exclusive_profile = $null }
            factcheck = @{ search = $true; generated_images = $false; report_check = $null; executor_label = '執行者'; evidence_only = $false; exclusive_profile = $null }
            generate = @{ search = $false; generated_images = $true; report_check = $null; executor_label = '執行者'; evidence_only = $false; exclusive_profile = $null }
            advise = @{ search = $false; generated_images = $false; report_check = $null; executor_label = '執行者'; evidence_only = $true; exclusive_profile = 'advisor' }
        }
        Assert-Equal @('review', 'factcheck', 'generate', 'advise') @((Get-RunTaskTypeSetting).Keys)
        foreach ($type in @('review', 'factcheck', 'generate', 'advise')) {
            $override = @{ task_type = $type; profile = $(if ($type -ceq 'review') { 'review' } elseif ($type -ceq 'advise') { 'advisor' } else { 'content' }) }
            if ($type -ceq 'advise') { $override += $adviseExtra }
            $order = Read-RunDispatchFile -Path (Write-OrderFile -Override $override -Name ('setting-' + $type + '.md'))
            Assert-Equal $type $order.task_type
            foreach ($key in $expected[$type].Keys) {
                Assert-Equal $expected[$type][$key] $order.task_setting.$key ($type + '.' + $key)
            }
            Test-RunPreStart -Order $order -AiAgentsRoot $aiRoot
        }
    }
    Test-Case 'ORDER-ADVISE-PARSE 顧問派遣檔解析出授權、evidence 與題號，通過啟動前檢查' {
        $order = Read-RunDispatchFile -Path (Write-AdviseOrder)
        Assert-Equal 'user-explicit' $order.advisor_request_source
        Assert-Equal $evidenceFile $order.evidence_file
        Assert-Equal @('Q1', 'Q2') @($order.question_ids)
        Test-RunPreStart -Order $order -AiAgentsRoot $aiRoot
    }
    Test-Case 'ORDER-ADVISE-AUTH advisor_request_source 缺少或不是 user-explicit 時以 RunAdvisorAuthorizationRequired 拒絕（結束碼 2）' {
        $caught = Assert-Throws -Code 'RunAdvisorAuthorizationRequired' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Remove @('advisor_request_source') -Name 'advise-noauth.md') }
        Assert-Equal 2 ([int]$caught.Data['ExitCode'])
        foreach ($value in @('user-implicit', 'USER-EXPLICIT', 'coordinator', '')) {
            $caught = Assert-Throws -Code 'RunAdvisorAuthorizationRequired' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ advisor_request_source = $value } -Name 'advise-badauth.md') }
            Assert-Equal 2 ([int]$caught.Data['ExitCode'])
        }
    }
    Test-Case 'ORDER-ADVISE-AUTH-TYPES advisor_request_source 為陣列、物件、數字、布林等非字串型別時一律拒絕（-cne 對陣列是篩選，不是比較）' {
        $authValues = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @(@(), @('user-explicit'), @('user-explicit', 'x'))) { $authValues.Add($item); $authValues.Add(@(, $item)) }
        foreach ($item in @(1, $true, [ordered]@{ a = 'user-explicit' })) { $authValues.Add($item) }
        foreach ($value in $authValues) {
            $caught = Assert-Throws -Code 'RunAdvisorAuthorizationRequired' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ advisor_request_source = $value } -Name 'auth-type.md') }
            Assert-Equal 2 ([int]$caught.Data['ExitCode'])
        }
    }
    Test-Case 'ORDER-SCHEMA-TYPE schema 為陣列時拒絕（同類型別漏洞）' {
        $schemaValues = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @(@('ai-agents.codex-run-order.v1'), @())) { $schemaValues.Add($item); $schemaValues.Add(@(, $item)) }
        foreach ($value in $schemaValues) {
            $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains 'schema' -Script { Read-RunDispatchFile -Path (Write-OrderFile -Override @{ schema = $value } -Name 'schema-type.md') }
        }
    }
    Test-Case 'ORDER-ADVISE-FIELD-TYPES evidence_file、question_ids 為非預期型別時拒絕' {
        foreach ($value in @((,@($evidenceFile)), 5, $true)) {
            $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains 'evidence_file' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ evidence_file = $value } -Name 'field-type-1.md') }
        }
        foreach ($value in @('Q1', 5, (,@(1, 2)), (,@('Q1', '')))) {
            $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains 'question_ids' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ question_ids = $value } -Name 'field-type-2.md') }
        }
    }
    Test-Case 'ORDER-CMDLETBINDING 新增的 evidence 與題號函式宣告 CmdletBinding' {
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $moduleRoot '70-run.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Get-RunEvidenceSnapshot', 'Test-RunEvidenceInline', 'Get-RunMissingQuestionId')) {
            $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true)
            Assert-True ($null -ne $function) ($name + ' 不存在')
            Assert-True (@($function.Body.ParamBlock.Attributes | Where-Object { $_.TypeName.Name -ceq 'CmdletBinding' }).Count -eq 1) ($name + ' 缺少 CmdletBinding')
        }
    }
    Test-Case 'ORDER-PROFILE-BINDING advise 只接受檔位 advisor，其他類型不接受檔位 advisor（結束碼 2）' {
        $caught = Assert-Throws -Code 'RunTaskProfileMismatch' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ profile = 'review' } -Name 'bind-1.md') }
        Assert-Equal 2 ([int]$caught.Data['ExitCode'])
        foreach ($type in @('review', 'factcheck', 'generate')) {
            $caught = Assert-Throws -Code 'RunTaskProfileMismatch' -Script { Read-RunDispatchFile -Path (Write-OrderFile -Override @{ task_type = $type; profile = 'advisor' } -Name ('bind-' + $type + '.md')) }
            Assert-Equal 2 ([int]$caught.Data['ExitCode'])
        }
    }
    Test-Case 'ORDER-ADVISE-KEYS 顧問缺 evidence_file 或 question_ids、question_ids 空、required_reads 非空時拒絕；其他類型出現這三個鍵時拒絕' {
        foreach ($remove in @('evidence_file', 'question_ids')) {
            $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains $remove -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Remove @($remove) -Name 'keys-1.md') }
        }
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains 'question_ids' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ question_ids = @() } -Name 'keys-2.md') }
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains 'question_ids' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ question_ids = @('Q 1') } -Name 'keys-3.md') }
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains 'required_reads' -Script { Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ required_reads = @($designFile) } -Name 'keys-4.md') }
        foreach ($key in @('advisor_request_source', 'evidence_file', 'question_ids')) {
            $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains $key -Script { Read-RunDispatchFile -Path (Write-OrderFile -Override @{ $key = $adviseExtra[$key] } -Name ('keys-stray-' + $key + '.md')) }
        }
    }
    Test-Case 'ORDER-ADVISE-EVIDENCE-FILE evidence 檔不存在、為空、在可讀範圍之外時啟動前檢查拒絕；不檢查內容格式' {
        $missing = Join-Path $reportRoot 'absent-evidence.md'
        $details = Get-PreStartDetails -Path (Write-AdviseOrder -Override @{ evidence_file = $missing } -Name 'ev-1.md')
        Assert-True (@($details | Where-Object { $_.path -ceq $missing -and $_.reason -ceq 'missing' }).Count -eq 1) 'missing'
        $empty = Join-Path $reportRoot 'empty-evidence.md'
        Write-TestUtf8 -Path $empty -Text ''
        $details = Get-PreStartDetails -Path (Write-AdviseOrder -Override @{ evidence_file = $empty } -Name 'ev-2.md')
        Assert-True (@($details | Where-Object { $_.path -ceq $empty -and $_.reason -ceq 'empty' }).Count -eq 1) 'empty'
        $outsideFile = Join-Path $outside 'evidence.md'
        Write-TestUtf8 -Path $outsideFile -Text 'x'
        $details = Get-PreStartDetails -Path (Write-AdviseOrder -Override @{ evidence_file = $outsideFile } -Name 'ev-3.md')
        Assert-True (@($details | Where-Object { $_.path -ceq $outsideFile -and $_.reason -ceq 'outside-readable-roots' }).Count -eq 1) 'outside'
        $freeForm = Join-Path $reportRoot 'free-form-evidence.md'
        Write-TestUtf8 -Path $freeForm -Text 'no headings at all'
        Test-RunPreStart -Order (Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ evidence_file = $freeForm } -Name 'ev-4.md')) -AiAgentsRoot $aiRoot
    }
    Test-Case 'ORDER-ADVISE-INLINE evidence 全文內嵌 prompt 並逐字比對；prompt 被改、evidence 檔事後被改時比對不一致；內容含結束標記或 BOM 仍一致' {
        $order = Read-RunDispatchFile -Path (Write-AdviseOrder -Name 'inline.md')
        $snapshot = Get-RunEvidenceSnapshot -Path $evidenceFile
        Assert-Equal (Get-RunSha256File -Path $evidenceFile) $snapshot.sha256
        $prompt = New-RunPrompt -Order $order -OutputDirectory (Join-Path $reportRoot 'runs\x') -ReportPath (Join-Path $reportRoot 'runs\x\r.md') -ReviewerLine 'Codex advisor' -Evidence $snapshot
        Assert-True (Test-RunEvidenceInline -Prompt $prompt -Evidence $snapshot) '未改動時應一致'
        Assert-True (-not (Test-RunEvidenceInline -Prompt $prompt.Replace('問題 Q1', '問題 Q9') -Evidence $snapshot)) 'prompt 內嵌內容被改時應不一致'
        Assert-True (-not (Test-RunEvidenceInline -Prompt $prompt.Replace('<<<EVIDENCE-BEGIN', 'x') -Evidence $snapshot)) '缺少起始標記時應不一致'
        Write-TestUtf8 -Path $evidenceFile -Text "# evidence`n`n問題 Q1、Q2、Q3。`n"
        $changed = Get-RunEvidenceSnapshot -Path $evidenceFile
        Assert-True ($changed.sha256 -cne $snapshot.sha256) '檔案改動後雜湊應不同'
        Assert-True (-not (Test-RunEvidenceInline -Prompt $prompt -Evidence $changed)) '檔案事後被改時內嵌內容與檔案不一致'
        $tricky = Join-Path $reportRoot 'tricky-evidence.md'
        [IO.File]::WriteAllBytes($tricky, ([byte[]]@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes("a`n<<<EVIDENCE-END>>>`nb`n")))
        $trickySnapshot = Get-RunEvidenceSnapshot -Path $tricky
        $trickyOrder = Read-RunDispatchFile -Path (Write-AdviseOrder -Override @{ evidence_file = $tricky } -Name 'inline-2.md')
        $trickyPrompt = New-RunPrompt -Order $trickyOrder -OutputDirectory (Join-Path $reportRoot 'runs\x') -ReportPath (Join-Path $reportRoot 'runs\x\r.md') -ReviewerLine $null -Evidence $trickySnapshot
        Assert-True (Test-RunEvidenceInline -Prompt $trickyPrompt -Evidence $trickySnapshot) '含結束標記與 BOM 的內容應一致'
        Write-TestUtf8 -Path $evidenceFile -Text "# evidence`n`n問題 Q1、Q2。`n"
    }
    Test-Case 'ORDER-ADVISE-QUESTIONS 題號以整個詞比對；報告不存在時全部缺少' {
        $report = Join-Path $reportRoot 'q-report.md'
        Write-TestUtf8 -Path $report -Text "## Q10`n`n## Q2-b`n"
        Assert-Equal @('Q1', 'Q2') @(Get-RunMissingQuestionId -ReportPath $report -QuestionId @('Q1', 'Q2'))
        Write-TestUtf8 -Path $report -Text "## Q1`n`n答：Q2。`n"
        Assert-Equal 0 (@(Get-RunMissingQuestionId -ReportPath $report -QuestionId @('Q1', 'Q2')).Count)
        Assert-Equal @('Q1') @(Get-RunMissingQuestionId -ReportPath (Join-Path $reportRoot 'absent-q.md') -QuestionId @('Q1'))
    }
    Test-Case 'ORDER-INVALID-SHAPES 結構錯誤逐項以 RunDispatchFileInvalid 拒絕' {
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -Script { Read-RunDispatchFile -Path (Join-Path $root 'absent.md') }
        $noHeading = Join-Path $reportRoot 'no-heading.md'
        Write-TestUtf8 -Path $noHeading -Text "# x`n`n## 任務`n"
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -Script { Read-RunDispatchFile -Path $noHeading }
        $noBlock = Join-Path $reportRoot 'no-block.md'
        Write-TestUtf8 -Path $noBlock -Text "# x`n`n## 派遣設定`n`n沒有區塊`n"
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -Script { Read-RunDispatchFile -Path $noBlock }
        $null = Assert-Throws -Code 'RunDispatchFileInvalid' -Script { Read-RunDispatchFile -Path (Write-OrderFile -RawJson '{ not json') }
        foreach ($override in @(
                @{ line_slug = 'Bad_Slug' }, @{ dispatch_slug = 'a b' }, @{ profile = 'deep' }, @{ report_name = 'a\b.md' }, @{ report_name = '..' },
                @{ targets = @() }, @{ targets = 'x' }, @{ required_reads = 'x' }, @{ schema = 'v0' }, @{ cycle = 'x' },
                @{ cycle = [ordered]@{ id = 'x'; round = 0; role = 'review' } }, @{ cycle = [ordered]@{ id = 'x'; round = 1; role = 'review'; extra = 1 } })) {
            $path = Write-OrderFile -Override $override
            $null = Assert-Throws -Code 'RunDispatchFileInvalid' -Script { Read-RunDispatchFile -Path $path }
        }
        foreach ($remove in @('targets', 'required_reads', 'report_name', 'role_file')) {
            $path = Write-OrderFile -Remove @($remove)
            $null = Assert-Throws -Code 'RunDispatchFileInvalid' -MessageContains $remove -Script { Read-RunDispatchFile -Path $path }
        }
    }
    Test-Case 'ORDER-DENIED-PATTERN 路徑為 .env 或 secrets.json 時為 denied-pattern' {
        $envFile = Join-Path $exec '.env'
        $secretsFile = Join-Path $exec 'src\secrets.json'
        Write-TestUtf8 -Path $envFile -Text 'A=1'
        Write-TestUtf8 -Path $secretsFile -Text '{}'
        $details = Get-PreStartDetails -Path (Write-OrderFile -Override @{ required_reads = @($envFile); targets = @($secretsFile) })
        Assert-Equal 2 ($details.Count)
        Assert-Equal @('denied-pattern', 'denied-pattern') @($details | ForEach-Object { $_.reason })
    }
    Test-Case 'ORDER-DENIED-PATTERN-NAMES 五種樣式的檔名判定' {
        foreach ($name in @('.env', '.env.local', 'a.pem', 'b.key', 'secrets.json')) { Assert-True (Test-RunDenyPatternName -Name $name) ($name + ' 應被拒') }
        foreach ($name in @('env.txt', 'readme.md', 'keys.md', 'secret.txt')) { Assert-True (-not (Test-RunDenyPatternName -Name $name)) ($name + ' 不應被拒') }
    }
    Test-Case 'ORDER-UNSAFE-CHAR execution_root 含 & 時為 unsafe-char' {
        $unsafeRoot = Join-Path $root 'a&b'
        $null = New-Item -ItemType Directory -Path $unsafeRoot -Force
        $details = Get-PreStartDetails -Path (Write-OrderFile -Override @{ execution_root = $unsafeRoot; role_file = $roleFile; targets = @($roleFile); required_reads = @() })
        Assert-True (@($details | Where-Object { $_.reason -eq 'unsafe-char' -and $_.path -eq $unsafeRoot }).Count -eq 1) '缺少 unsafe-char'
        Assert-True (-not (Test-RunPathCmdSafe -Path 'C:\a&b')) '& 應不安全'
        Assert-True (Test-RunPathCmdSafe -Path 'C:\Program Files (x86)\a') '括號與空白應安全'
        foreach ($char in @('|', '<', '>', '^', '%', '"', "'")) { Assert-True (-not (Test-RunPathCmdSafe -Path ('C:\a' + $char + 'b'))) ($char + ' 應不安全') }
    }
    Test-Case 'ORDER-UNSAFE-QUOTE 路徑含單引號時在啟動前檢查階段以 unsafe-char 拒絕（execution_root、report_line_root、~\.ai-agents），不建立輸出目錄' {
        $quoteRoot = Join-Path $root "q'uote"
        $null = New-Item -ItemType Directory -Path (Join-Path $quoteRoot 'src') -Force
        $quoteRole = Join-Path $quoteRoot 'role.toml'
        Write-TestUtf8 -Path $quoteRole -Text 'x'
        $execDetails = Get-PreStartDetails -Path (Write-OrderFile -Override @{ execution_root = $quoteRoot; role_file = $quoteRole; targets = @($quoteRole); required_reads = @() })
        Assert-True (@($execDetails | Where-Object { $_.reason -eq 'unsafe-char' -and $_.path -eq $quoteRoot }).Count -eq 1) 'execution_root 缺少 unsafe-char'
        $quoteReport = Join-Path $root "report'q"
        $null = New-Item -ItemType Directory -Path $quoteReport -Force
        $reportDetails = Get-PreStartDetails -Path (Write-OrderFile -Override @{ report_line_root = $quoteReport; required_reads = @() })
        Assert-True (@($reportDetails | Where-Object { $_.reason -eq 'unsafe-char' -and $_.path -eq $quoteReport }).Count -eq 1) 'report_line_root 缺少 unsafe-char'
        $quoteAi = Join-Path $root "ai'q"
        $null = New-Item -ItemType Directory -Path $quoteAi -Force
        $order = Read-RunDispatchFile -Path (Write-OrderFile -Override @{ required_reads = @() })
        $caught = Assert-Throws -Code 'RunPathsInvalid' -Script { Test-RunPreStart -Order $order -AiAgentsRoot $quoteAi }
        Assert-True (@($caught.Data['Details'] | Where-Object { $_.reason -eq 'unsafe-char' -and $_.path -eq $quoteAi }).Count -eq 1) 'ai-agents 路徑缺少 unsafe-char'
        Assert-Equal 2 ($caught.Data['ExitCode'])
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $reportRoot 'runs'))) '不應建立輸出目錄'
    }
    Test-Case 'ORDER-OUTSIDE-ROOTS 路徑在三個可讀根目錄之外時為 outside-readable-roots' {
        $outsideFile = Join-Path $outside 'x.txt'
        Write-TestUtf8 -Path $outsideFile -Text 'x'
        $details = Get-PreStartDetails -Path (Write-OrderFile -Override @{ required_reads = @($outsideFile) })
        Assert-Equal 1 ($details.Count)
        Assert-Equal 'outside-readable-roots' $details[0].reason
        Assert-Equal $outsideFile $details[0].path
    }
    Test-Case 'ORDER-NOT-ABSOLUTE 相對路徑為 not-absolute' {
        $details = Get-PreStartDetails -Path (Write-OrderFile -Override @{ required_reads = @('docs\design.md') })
        Assert-Equal 1 ($details.Count)
        Assert-Equal 'not-absolute' $details[0].reason
    }
    Test-Case 'ORDER-ROOTS-MISSING execution_root 與 report_line_root 不存在時為 missing' {
        $ghostExec = Join-Path $root 'ghost-exec'
        $path = Write-OrderFile -Override @{ execution_root = $ghostExec; role_file = $roleFile; targets = @($roleFile); required_reads = @() }
        $details = Get-PreStartDetails -Path $path
        Assert-True (@($details | Where-Object { $_.reason -eq 'missing' -and $_.path -eq $ghostExec }).Count -eq 1) 'execution_root 缺少 missing'
    }
    Test-Case 'ORDER-NO-OUTPUT-DIR 啟動前檢查不建立任何輸出目錄' {
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $reportRoot 'runs'))) 'report_line_root 下出現 runs'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $exec 'runs'))) 'execution_root 下出現 runs'
    }
    Test-Case 'ORDER-ROLES 三個審查角色的派遣檔都通過解析與啟動前檢查，角色規則檔以輸出目錄與 manifest 為契約' {
        $agentsDirectory = Join-Path (Split-Path -Parent $scriptsRoot) 'agents\codex'
        foreach ($role in @(@('reviewer', 'review-report.md'), @('frontend-reviewer', 'frontend-reviewer-report.md'), @('contract-auditor', 'contract-auditor-report.md'))) {
            $roleCopy = Join-Path $aiRoot ($role[0] + '.toml')
            Copy-Item -LiteralPath (Join-Path $agentsDirectory ($role[0] + '.toml')) -Destination $roleCopy -Force
            $order = Read-RunDispatchFile -Path (Write-OrderFile -Override @{ role_file = $roleCopy; report_name = $role[1] } -Name ($role[0] + '.md'))
            Assert-Equal $role[1] $order.report_name
            Test-RunPreStart -Order $order -AiAgentsRoot $aiRoot
            $toml = [IO.File]::ReadAllText($roleCopy)
            Assert-True ($toml.Contains('輸出目錄')) ($role[0] + '.toml 未宣告寫入範圍為輸出目錄')
            Assert-True ($toml.Contains('Finding manifest')) ($role[0] + '.toml 未宣告 Finding manifest')
            Assert-True ($toml.Contains('報告檔:')) ($role[0] + '.toml 未宣告報告檔落點')
        }
    }
    Test-Case 'ORDER-NO-LEGACY-REFERENCE 新模組不引用現行模組' {
        $hits = @(Get-ChildItem -LiteralPath $moduleRoot -File | Select-String -Pattern 'scripts/dispatch|dispatch-evidence|common-runtime')
        Assert-Equal 0 ($hits.Count) ('發現引用：' + (@($hits | ForEach-Object { $_.Path + ':' + $_.LineNumber }) -join '; '))
    }
    Test-Case 'COMMON-HELPERS 通用函式行為' {
        Assert-True ((New-RunId) -cmatch '^\d{8}T\d{9}Z-[0-9a-f]{6}$') 'runId 格式'
        Assert-True ((New-RunId) -cne (New-RunId)) 'runId 應不重複'
        Assert-Equal '\u4e2d\u6587' ((ConvertTo-AsciiJson -InputObject '中文' -Compress).Trim('"')) 'ASCII 跳脫'
        Assert-Equal (Get-RunSha256Text -Text 'abc') 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        $hashFile = Join-Path $root 'h.txt'
        [IO.File]::WriteAllBytes($hashFile, [Text.Encoding]::ASCII.GetBytes('abc'))
        Assert-Equal (Get-RunSha256File -Path $hashFile) (Get-RunSha256Text -Text 'abc')
        Assert-True (Test-RunPathUnder -Path 'C:\a\b\c' -Root 'C:\A\B') 'under'
        Assert-True (Test-RunPathUnder -Path 'C:\a\b' -Root 'C:\a\b\') 'equal'
        Assert-True (-not (Test-RunPathUnder -Path 'C:\a\bc' -Root 'C:\a\b')) 'prefix 不算 under'
        $jsonPath = Join-Path $root 'out\x.json'
        Write-RunJsonAtomic -Path $jsonPath -InputObject ([ordered]@{ a = 1 })
        Write-RunJsonAtomic -Path $jsonPath -InputObject ([ordered]@{ a = 2 })
        Assert-Equal 2 ((Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json).a)
        Assert-Equal 1 (@(Get-ChildItem -LiteralPath (Join-Path $root "out")).Count) '不應殘留暫存檔'
        $error = New-RunError -Code 'X' -Message 'm' -ExitCode 3 -Details @('d')
        Assert-Equal 'X' $error.Data['Code']
        Assert-Equal 3 $error.Data['ExitCode']
    }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
