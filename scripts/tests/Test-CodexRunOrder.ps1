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
    Test-Case 'ORDER-TASK-TYPE task_type 為 advise 以 RunTaskTypeUnsupported 拒絕' {
        $path = Write-OrderFile -Override @{ task_type = 'advise' }
        $null = Assert-Throws -Code 'RunTaskTypeUnsupported' -Script { Read-RunDispatchFile -Path $path }
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
