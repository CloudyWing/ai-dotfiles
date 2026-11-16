#Requires -Version 7.0
# 本機路徑檢查的測試：函式庫、排除規則，以及 .githooks/Test-StagedDocPath.ps1 在 temp git repo 的 staged 與 -All 情境。
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$libraryPath = Join-Path $repoRoot 'claude-plugins\ai-agents-hooks\hooks\lib\doc-path-check.ps1'
$stagedScript = Join-Path $repoRoot '.githooks\Test-StagedDocPath.ps1'
# PostToolUse 提醒 hook 的判定在 hooks\core\doc-path.ts，由 tests\run-hook.ts 以命令型 hook 的 stdin 與 stdout 形式執行。
$runHook = Join-Path $repoRoot 'claude-plugins\ai-agents-hooks\tests\run-hook.ts'
$hookCore = Join-Path $repoRoot 'claude-plugins\ai-agents-hooks\hooks\core\doc-path.ts'
. $libraryPath

# 偵測規則有 PowerShell 與 TypeScript 兩份實作。下列包裝記下本測試交給 PowerShell 函式庫的每一筆輸入，
# 測試結尾把同一組輸入交給 TypeScript 實作，逐筆比對結果相同。
$script:parityCases = [System.Collections.Generic.List[object]]::new()
$script:findOriginal = ${function:Find-LocalPathViolation}
$script:excludedOriginal = ${function:Test-LocalPathExcludedFile}
function Find-LocalPathViolation {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $script:parityCases.Add([ordered]@{ kind = 'find'; input = $Text })
    & $script:findOriginal -Text $Text
}
function Test-LocalPathExcludedFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)
    $script:parityCases.Add([ordered]@{ kind = 'excluded'; input = $Path })
    & $script:excludedOriginal -Path $Path
}

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$assertCount = 0

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:assertCount++
    if ($Actual -cne $Expected) {
        throw "FAIL: $Message`n  expected: [$Expected]`n  actual:   [$Actual]"
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertCount++
    if (-not $Condition) {
        throw "FAIL: $Message"
    }
}

# ---------------------------------------------------------------------------
# 1. Find-LocalPathViolation
# ---------------------------------------------------------------------------

$violationSamples = @(
    'C:\Users\Alice\a.md',
    'D:\Programming\Projects\X',
    'c:/users/bob/x',
    'C:\\Users\\Alice\\.codex',
    'E:\Work\repo',
    'C:\專案\文件.md'
)
foreach ($sample in $violationSamples) {
    $found = @(Find-LocalPathViolation -Text $sample)
    Assert-Equal $found.Count 1 "違規範例應回報 1 個 token：$sample"
    Assert-Equal $found[0] $sample "違規範例的 token 應為整段路徑：$sample"
}

$cleanSamples = @(
    'C:\Users\<使用者>\.ai-agents',
    'c:\users\<使用者>\x',
    'C:\\Users\\<使用者>\\.codex-account-a',
    'C:\<專案目錄>\x',
    'C:/<專案根目錄>/src/app.cs',
    'C:\Users\{name}\x',
    'D:\%USERPROFILE%\x',
    '%USERPROFILE%\x',
    'https://example.com',
    'http://localhost:3000/a/b',
    'C:\',
    'C:/',
    '',
    '一般文字沒有路徑，只有 src/app 與 docs\guide'
)
foreach ($sample in $cleanSamples) {
    $found = @(Find-LocalPathViolation -Text $sample)
    Assert-Equal $found.Count 0 "不應回報：[$sample]"
}

Assert-Equal @(Find-LocalPathViolation -Text $null).Count 0 '$null 不回報'

# token 終點：反引號、全形標點與句尾標點不屬於路徑。
$inline = @(Find-LocalPathViolation -Text '見 `C:\Users\Alice\a.md`，與（D:\x\y）。')
Assert-Equal $inline.Count 2 '同一行的兩個路徑皆回報'
Assert-Equal $inline[0] 'C:\Users\Alice\a.md' '反引號終止 token'
Assert-Equal $inline[1] 'D:\x\y' '全形括號終止 token'

$sentence = @(Find-LocalPathViolation -Text 'Open E:\Work\repo. Then see (D:\x\y).')
Assert-Equal $sentence.Count 2 '句尾標點前的路徑皆回報'
Assert-Equal $sentence[0] 'E:\Work\repo' '句尾句點不計入 token'
Assert-Equal $sentence[1] 'D:\x\y' '句尾括號與句點不計入 token'

# 修剪後只剩磁碟機根目錄的 token 不回報；有實際路徑片段者仍回報。
Assert-Equal @(Find-LocalPathViolation -Text '(C:\)').Count 0 '括號內的單純磁碟機根目錄不回報'
Assert-Equal @(Find-LocalPathViolation -Text '見 C:\].').Count 0 '修剪句尾括號與句點後只剩磁碟機根目錄時不回報'
$parenPath = @(Find-LocalPathViolation -Text '(C:\Users\Alice\x)')
Assert-Equal $parenPath.Count 1 '括號內的實際路徑仍回報'
Assert-Equal $parenPath[0] 'C:\Users\Alice\x' '括號內的實際路徑去除句尾括號'

# 佔位符豁免只看開頭：佔位符之前出現真實片段仍為違規。
$partial = @(Find-LocalPathViolation -Text 'D:\Programming\<x>')
Assert-Equal $partial.Count 1 '真實根目錄後接佔位符仍為違規'

# 路徑內嵌於 JSON 跳脫字串。
$json = @(Find-LocalPathViolation -Text '{"path":"C:\\Users\\Alice\\.codex"}')
Assert-Equal $json.Count 1 'JSON 字串中的跳脫路徑回報'

# 空白終止字元以明確列舉寫出：U+0085、U+00A0、U+3000、U+2028 終止 token，U+FEFF 不終止。這些輸入也進入第 6 節的兩份實作比對。
foreach ($separator in @([char]0x0085, [char]0x00A0, [char]0x3000, [char]0x2028)) {
    $split = @(Find-LocalPathViolation -Text ('C:\one' + $separator + 'D:\two'))
    Assert-Equal ($split -join '|') 'C:\one|D:\two' ('空白終止 token：U+{0:X4}' -f [int]$separator)
}
$joined = @(Find-LocalPathViolation -Text ('C:\one' + [char]0xFEFF + 'D:\two'))
Assert-Equal ($joined -join '|') ('C:\one' + [char]0xFEFF + 'D:\two') 'U+FEFF 不終止 token'

# ---------------------------------------------------------------------------
# 2. Test-LocalPathExcludedFile
# ---------------------------------------------------------------------------

$excluded = @(
    '.local/x.md', '.local\ai-sessions\handoff\a.md', 'docs/.LOCAL/x.md',
    'AGENTS.local.md', 'sub/CONTEXT.local.md', 'sub\agents.LOCAL.MD', 'C:\p\.local\x.md'
)
foreach ($path in $excluded) {
    Assert-True (Test-LocalPathExcludedFile -Path $path) "應排除：$path"
}
$included = @('docs/a.md', 'AGENTS.md', 'local.md', '.localx/a.md', 'docs/mylocal.md', 'agents/x.toml', 'a.local.txt')
foreach ($path in $included) {
    Assert-True (-not (Test-LocalPathExcludedFile -Path $path)) "不應排除：$path"
}

# ---------------------------------------------------------------------------
# 3. 新增的 .ps1 皆為 UTF-8 with BOM
# ---------------------------------------------------------------------------

foreach ($file in @($libraryPath, $stagedScript, $PSCommandPath)) {
    $bytes = [System.IO.File]::ReadAllBytes($file)
    Assert-True ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "缺少 UTF-8 BOM：$file"
}
$coreBytes = [System.IO.File]::ReadAllBytes($hookCore)
Assert-True (-not ($coreBytes.Length -ge 3 -and $coreBytes[0] -eq 239 -and $coreBytes[1] -eq 187 -and $coreBytes[2] -eq 191)) "TypeScript 檔不應有 BOM：$hookCore"

# ---------------------------------------------------------------------------
# 4. Test-StagedDocPath.ps1（temp git repo）
# ---------------------------------------------------------------------------

$tempBase = Join-Path ([System.IO.Path]::GetTempPath()) ('doc-path-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempBase | Out-Null
$emptyHooks = Join-Path $tempBase '_nohooks'
New-Item -ItemType Directory -Path $emptyHooks | Out-Null

function Invoke-TestGit {
    param([string]$Repo, [string[]]$GitArgument)
    $output = & git -C $Repo -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false -c core.autocrlf=false -c "core.hooksPath=$emptyHooks" @GitArgument 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "test git failed ($($GitArgument -join ' ')): $output"
    }
}

function New-TestRepo {
    param([string]$Name)
    $repo = Join-Path $tempBase $Name
    New-Item -ItemType Directory -Path $repo | Out-Null
    Invoke-TestGit -Repo $repo -GitArgument @('init', '-q')
    return $repo
}

function Write-RepoFile {
    param([string]$Repo, [string]$RelativePath, [string[]]$Line)
    $full = Join-Path $Repo $RelativePath
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($full, (($Line -join "`n") + "`n"), $utf8NoBom)
}

function Invoke-PathCheck {
    param([string]$Repo, [string[]]$ExtraArgument = @())
    $output = & pwsh -NoProfile -NonInteractive -File $stagedScript -RepoRoot $Repo @ExtraArgument 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (@($output | ForEach-Object { [string]$_ }) -join "`n") }
}

try {
    # 4.1 staged：新增行含路徑時阻擋，並輸出相對路徑與行號。
    $repo = New-TestRepo 'staged-bad'
    Write-RepoFile $repo 'docs/bad.md' @('# 標題', '路徑 C:\Users\Alice\x 在此')
    Invoke-TestGit $repo @('add', '--', 'docs/bad.md')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 1 'staged .md 含路徑應退出碼 1'
    Assert-True ($result.Output -match 'docs/bad\.md:2: C:\\Users\\Alice\\x') "輸出應含 docs/bad.md:2 與 token：$($result.Output)"
    Assert-True ($result.Output -match 'doc-placement') '輸出應含修正指引'

    # 4.2 staged：agents/*.toml 同樣檢查。
    $repo = New-TestRepo 'staged-toml'
    Write-RepoFile $repo 'agents/x.toml' @('name = "x"', 'note = "see D:\Programming\x"')
    Invoke-TestGit $repo @('add', '--', 'agents/x.toml')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 1 'staged .toml 含路徑應退出碼 1'
    Assert-True ($result.Output -match 'agents/x\.toml:2: D:\\Programming\\x') "輸出應含 agents/x.toml:2：$($result.Output)"

    # 4.3 負向：.local 與 *.local.md 以 git add -f 加入，含真實路徑仍放行。
    $repo = New-TestRepo 'staged-excluded'
    Write-RepoFile $repo '.local/x.md' @('C:\Users\Alice\secret')
    Write-RepoFile $repo 'AGENTS.local.md' @('D:\Programming\Projects\X')
    Write-RepoFile $repo 'sub/CONTEXT.local.md' @('E:\Work\repo')
    Invoke-TestGit $repo @('add', '-f', '--', '.local/x.md', 'AGENTS.local.md', 'sub/CONTEXT.local.md')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 0 '.local 與 *.local.md 不檢查'
    Assert-Equal $result.Output '' '排除檔案不輸出'

    # 4.4 負向：佔位符、URL、單純磁碟機不回報；非 .md/.toml 副檔名不檢查。
    $repo = New-TestRepo 'staged-ok'
    Write-RepoFile $repo 'docs/ok.md' @('# 無路徑', '設定位於 C:\Users\<使用者>\.x 與 C:\<專案目錄>\x', '見 https://a.b 與 C:\')
    Write-RepoFile $repo 'scripts/run.ps1' @('$p = ''C:\Users\Alice\x''')
    Write-RepoFile $repo 'src/app.ts' @('const p = "D:\\Programming\\x"')
    Invoke-TestGit $repo @('add', '--', 'docs/ok.md', 'scripts/run.ps1', 'src/app.ts')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 0 '佔位符、URL 與 .ps1/.ts 路徑不阻擋'
    Assert-Equal $result.Output '' '無違規時無輸出'

    # 4.5 staged 只看新增行，存量行不回報；-All 回報存量行。
    $repo = New-TestRepo 'staged-baseline'
    Write-RepoFile $repo 'docs/old.md' @('# 舊文件', '舊路徑 D:\Old\path 保留')
    Invoke-TestGit $repo @('add', '--', 'docs/old.md')
    Invoke-TestGit $repo @('commit', '-q', '-m', 'baseline')
    Write-RepoFile $repo 'docs/old.md' @('# 舊文件', '舊路徑 D:\Old\path 保留', '新增一行乾淨內容')
    Invoke-TestGit $repo @('add', '--', 'docs/old.md')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 0 '未被本次改動的存量行不回報'
    Assert-Equal $result.Output '' '存量行不輸出'
    $result = Invoke-PathCheck $repo @('-All')
    Assert-Equal $result.ExitCode 1 '-All 回報存量行'
    Assert-True ($result.Output -match 'docs/old\.md:2: D:\\Old\\path') "-All 輸出應含 docs/old.md:2：$($result.Output)"

    # 4.6 staged 新增行位於既有檔案後段時，行號為新檔行號。
    Write-RepoFile $repo 'docs/old.md' @('# 舊文件', '舊路徑 D:\Old\path 保留', '新增一行乾淨內容', '第四行 E:\New\leak')
    Invoke-TestGit $repo @('add', '--', 'docs/old.md')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 1 '既有檔案新增含路徑行應阻擋'
    Assert-True ($result.Output -match 'docs/old\.md:4: E:\\New\\leak') "行號應為 4：$($result.Output)"
    Assert-True ($result.Output -notmatch 'D:\\Old') '同次輸出不含存量行'

    # 4.7 -All 不檢查 .local 與 *.local.md，也不檢查 .ps1。
    $repo = New-TestRepo 'all-excluded'
    Write-RepoFile $repo '.local/x.md' @('C:\Users\Alice\secret')
    Write-RepoFile $repo 'AGENTS.local.md' @('D:\Programming\Projects\X')
    Write-RepoFile $repo 'a.ps1' @('E:\Work\repo')
    Write-RepoFile $repo 'docs/ok.md' @('乾淨')
    Invoke-TestGit $repo @('add', '-f', '--', '.local/x.md', 'AGENTS.local.md', 'a.ps1', 'docs/ok.md')
    Invoke-TestGit $repo @('commit', '-q', '-m', 'excluded')
    $result = Invoke-PathCheck $repo @('-All')
    Assert-Equal $result.ExitCode 0 '-All 對排除檔案與 .ps1 不回報'
    Assert-Equal $result.Output '' '-All 無違規時無輸出'

    # 4.8 -Extension 限縮檢查範圍。
    $repo = New-TestRepo 'extension'
    Write-RepoFile $repo 'docs/bad.md' @('C:\Users\Alice\x')
    Write-RepoFile $repo 'agents/x.toml' @('p = "D:\Programming\x"')
    Invoke-TestGit $repo @('add', '--', 'docs/bad.md', 'agents/x.toml')
    $result = Invoke-PathCheck $repo @('-Extension', '.toml')
    Assert-Equal $result.ExitCode 1 '-Extension .toml 仍回報 toml 違規'
    Assert-True ($result.Output -match 'agents/x\.toml') '輸出含 agents/x.toml'
    Assert-True ($result.Output -notmatch 'docs/bad\.md') '-Extension .toml 不檢查 .md'

    # 4.9 無 staged 變更與空 repo。
    $repo = New-TestRepo 'empty'
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 0 '無 staged 變更退出碼 0'
    Assert-Equal $result.Output '' '無 staged 變更無輸出'
    $result = Invoke-PathCheck $repo @('-All')
    Assert-Equal $result.ExitCode 0 '-All 在無受控檔時退出碼 0'
    Assert-Equal $result.Output '' '-All 無受控檔無輸出'

    # 4.10 刪除檔案不被掃描（--diff-filter=ACMR）。
    $repo = New-TestRepo 'deleted'
    Write-RepoFile $repo 'docs/gone.md' @('C:\Users\Alice\x')
    Invoke-TestGit $repo @('add', '--', 'docs/gone.md')
    Invoke-TestGit $repo @('commit', '-q', '-m', 'add')
    Invoke-TestGit $repo @('rm', '-q', '--', 'docs/gone.md')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 0 '刪除含路徑的檔案不阻擋'

    # 4.11 git 失敗時退出碼非 0，且不輸出違規行。
    $notRepo = Join-Path $tempBase 'not-a-repo'
    New-Item -ItemType Directory -Path $notRepo | Out-Null
    $result = Invoke-PathCheck $notRepo
    Assert-True ($result.ExitCode -ne 0) 'git 失敗時退出碼非 0'
    Assert-True ($result.Output -notmatch '\.md:\d+:') 'git 失敗時不輸出違規行'

    # 4.12 檔名含空白時 git 於 +++ 行尾附加 Tab，仍須正確解析並阻擋。
    $repo = New-TestRepo 'space-name'
    Write-RepoFile $repo 'docs/my file.md' @('# 標題', '路徑 C:\Users\Alice\x 在此')
    Invoke-TestGit $repo @('add', '--', 'docs/my file.md')
    $result = Invoke-PathCheck $repo
    Assert-Equal $result.ExitCode 1 '檔名含空白的 staged .md 含路徑應退出碼 1'
    Assert-True ($result.Output -match 'docs/my file\.md:2: C:\\Users\\Alice\\x') "輸出應含檔名 docs/my file.md：$($result.Output)"

    # -----------------------------------------------------------------------
    # 5. doc-path 提醒 hook（PostToolUse，經 tests\run-hook.ts 以子行程送 stdin JSON）
    # -----------------------------------------------------------------------

    function Invoke-PathHook {
        param([string]$StdinText, [string]$Mode = 'doc-path')
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new('node')
        foreach ($argument in @('--no-warnings', $runHook, $Mode)) { $startInfo.ArgumentList.Add($argument) }
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stdinBytes = $utf8NoBom.GetBytes($StdinText)
            $process.StandardInput.BaseStream.Write($stdinBytes, 0, $stdinBytes.Length)
            $process.StandardInput.Close()
            $buffer = [System.IO.MemoryStream]::new()
            $process.StandardOutput.BaseStream.CopyTo($buffer)
            [void]$process.StandardError.ReadToEnd()
            $process.WaitForExit()
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Bytes = $buffer.ToArray() }
        }
        finally {
            $process.Dispose()
        }
    }

    function New-HookInput {
        param([string]$Tool, [string]$FilePath, [string]$Content, [string]$NewString, [string]$OldString)
        $toolInput = [ordered]@{ file_path = $FilePath }
        if ($Tool -eq 'Write') { $toolInput['content'] = $Content }
        if ($Tool -eq 'Edit') { $toolInput['old_string'] = $OldString; $toolInput['new_string'] = $NewString }
        return ([ordered]@{ tool_name = $Tool; tool_input = $toolInput } | ConvertTo-Json -Compress -Depth 4)
    }

    function Assert-HookSilent {
        param($Result, [string]$Message)
        Assert-Equal $Result.ExitCode 0 "$Message（退出碼）"
        Assert-Equal $Result.Bytes.Length 0 "$Message（無輸出）"
    }

    $hookRepo = New-TestRepo 'hook-repo'
    Write-RepoFile $hookRepo '.gitignore' @('ignored.md')
    Write-RepoFile $hookRepo 'docs/a.md' @('x')
    $trackedMd = Join-Path $hookRepo 'docs\a.md'

    # 5.1 Write 含路徑：單一 ASCII JSON 物件、無 BOM，additionalContext 含檔案、行號、token 與 doc-placement。
    $result = Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath $trackedMd -Content "第一行`n第二行 D:\x\y 結尾")
    Assert-Equal $result.ExitCode 0 'Write 含路徑：退出碼 0'
    Assert-True ($result.Bytes.Length -gt 0 -and $result.Bytes[0] -eq 123) 'Write 含路徑：輸出以 { 開頭且無 BOM'
    Assert-True (@($result.Bytes | Where-Object { $_ -ge 128 }).Count -eq 0) 'Write 含路徑：輸出為純 ASCII'
    $payload = [System.Text.Encoding]::ASCII.GetString($result.Bytes) | ConvertFrom-Json
    Assert-Equal @($payload.PSObject.Properties.Name).Count 1 'Write 含路徑：頂層只有 hookSpecificOutput'
    Assert-Equal $payload.hookSpecificOutput.hookEventName 'PostToolUse' 'hookEventName 為 PostToolUse'
    $context = [string]$payload.hookSpecificOutput.additionalContext
    Assert-True ($context.Contains($trackedMd)) "additionalContext 含檔案路徑：$context"
    Assert-True ($context.Contains('line 2: D:\x\y')) "additionalContext 含行號與 token：$context"
    Assert-True ($context.Contains('doc-placement')) 'additionalContext 含 doc-placement'

    # 5.2 Edit 的 new_string 含路徑時同。
    $result = Invoke-PathHook (New-HookInput -Tool 'Edit' -FilePath $trackedMd -OldString '乾淨' -NewString '新內容 E:\Work\repo')
    $payload = [System.Text.Encoding]::ASCII.GetString($result.Bytes) | ConvertFrom-Json
    $context = [string]$payload.hookSpecificOutput.additionalContext
    Assert-True ($context.Contains('line 1: E:\Work\repo') -and $context.Contains('doc-placement')) "Edit 的 new_string 含路徑應提醒：$context"

    # 5.3 負向：以下情境皆退出 0 且無輸出。
    Write-RepoFile $hookRepo '.local/x.md' @('x')
    Write-RepoFile $hookRepo 'AGENTS.local.md' @('x')
    Write-RepoFile $hookRepo 'ignored.md' @('x')
    Write-RepoFile $hookRepo 'scripts/run.ps1' @('x')
    $dirty = 'C:\Users\Alice\x'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath (Join-Path $hookRepo '.local\x.md') -Content $dirty)) '.local 不提醒'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath (Join-Path $hookRepo 'AGENTS.local.md') -Content $dirty)) '*.local.md 不提醒'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath (Join-Path $hookRepo 'ignored.md') -Content $dirty)) '被 .gitignore 忽略的 .md 不提醒'
    $noGit = Join-Path $tempBase 'hook-no-git'
    New-Item -ItemType Directory -Path $noGit | Out-Null
    Write-RepoFile $noGit 'a.md' @('x')
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath (Join-Path $noGit 'a.md') -Content $dirty)) '非 git 目錄的 .md 不提醒'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath $trackedMd -Content 'C:\Users\<使用者>\x 與 C:\<專案目錄>\y')) '只含佔位符不提醒'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath (Join-Path $hookRepo 'scripts\run.ps1') -Content $dirty)) '.ps1 不提醒'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Edit' -FilePath $trackedMd -OldString $dirty -NewString '乾淨')) 'old_string 含路徑但 new_string 乾淨不提醒'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Read' -FilePath $trackedMd)) 'tool_name 為 Read 不提醒'
    Assert-HookSilent (Invoke-PathHook (New-HookInput -Tool 'Write' -FilePath $trackedMd -Content '')) 'Write 內容為空不提醒'
    Assert-HookSilent (Invoke-PathHook 'not json') 'stdin 非 JSON 不提醒'
    Assert-HookSilent (Invoke-PathHook '{"tool_name":"Write"}') '缺少 tool_input 不提醒'

    # 6. 兩份實作的一致性：本測試交給 PowerShell 函式庫的全部輸入，逐筆比對 TypeScript 實作的結果

    $cases = @($script:parityCases | ForEach-Object { [pscustomobject]@{ kind = $_.kind; input = $_.input } })
    Assert-True ($cases.Count -gt 0) '一致性比對沒有收集到任何輸入'
    $expected = @(foreach ($case in $cases) {
        if ($case.kind -eq 'excluded') { [bool](& $script:excludedOriginal -Path $case.input) } else { , @(& $script:findOriginal -Text $case.input) }
    })
    $parityInput = ConvertTo-Json -InputObject $cases -Compress -Depth 4
    $parityResult = Invoke-PathHook -StdinText $parityInput -Mode 'lib-parity'
    Assert-Equal $parityResult.ExitCode 0 '一致性比對的轉接器退出碼'
    $actual = @([System.Text.Encoding]::ASCII.GetString($parityResult.Bytes) | ConvertFrom-Json -NoEnumerate)
    if ($actual.Count -eq 1 -and $actual[0] -is [array]) { $actual = @($actual[0]) }
    Assert-Equal $actual.Count $cases.Count '一致性比對的結果筆數'
    for ($i = 0; $i -lt $cases.Count; $i++) {
        $expectedJson = ConvertTo-Json -InputObject $expected[$i] -Compress
        $actualJson = ConvertTo-Json -InputObject $actual[$i] -Compress
        Assert-Equal $actualJson $expectedJson ("兩份實作結果不同（{0}）：{1}" -f $cases[$i].kind, $cases[$i].input)
    }
    Write-Host "parity cases: $($cases.Count)"

    Write-Host "assertions: $assertCount"
    Write-Host 'Doc local path check tests passed.'
}
finally {
    try { Remove-Item -LiteralPath $tempBase -Recurse -Force -ErrorAction Stop } catch { Write-Warning "temp cleanup failed: $tempBase" }
}
exit 0
