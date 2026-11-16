#Requires -Version 7.0
<#
.SYNOPSIS
檔位設定檔產生、連結建立與比對的測試（scripts\codex-run\45-profile-sync.ps1 與 .githooks\Update-CodexProfiles.ps1）。

.DESCRIPTION
全部在系統暫存目錄的假 repo 與假帳號目錄內執行，不碰任何真實帳號目錄、不呼叫 Codex。
需要建立 Symbolic Link 的案例在沒有權限時輸出 SKIP。派工前比對的端對端案例在 Test-CodexRunEntry.ps1。
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
$scriptsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptsRoot
. (Join-Path $PSScriptRoot 'codex-run-fixtures\TestHelpers.ps1')
. (Join-Path $scriptsRoot 'codex-run\45-profile-sync.ps1')
$hookPath = Join-Path $repoRoot '.githooks\Update-CodexProfiles.ps1'
$hostPath = [Environment]::ProcessPath
$realRegistry = Get-CodexProfileRegistryPath -RepoRoot $repoRoot
$realSpecs = @(Read-CodexProfileSpec -RegistryPath $realRegistry)

function Skip-Case {
    param([string]$Id, [string]$Reason)
    Write-Output ('SKIP ' + $Id + ' ' + $Reason)
}

function Get-FakeCodex {
    param($Registry, [int]$Index)
    # 登錄表內第 $Index 個 platform 為 codex 的執行者（依登錄表順序）。
    return @($Registry.executors | Where-Object { $_.platform -ceq 'codex' })[$Index]
}

function New-FixtureRegistryObject {
    # 測試自建的完整假登錄表（不讀出貨登錄表）：一個 Claude 執行者與四個 Codex 執行者（alpha、beta、gamma、delta，固定設定值）。
    # 出貨登錄表增減檔位、改名或改設定都不影響以它為基礎的測試。
    $registryJson = @'
{
  "schema": "ai-agents.executor-registry.v1",
  "tags": { "hard": ["write"], "constraint": ["family"] },
  "flags": ["E", "T"],
  "codexEfforts": ["low", "medium", "high"],
  "retiredProfiles": ["retired-one", "retired-two"],
  "maxIncomplete": 3,
  "types": { "survey": { "requiredFlags": [], "impliedTags": [], "forbiddenTags": [] } },
  "executors": [
    { "id": "claude-one", "display": "Claude one", "platform": "claude", "model": "claude-model", "family": "claude", "accepts": ["survey"], "tags": [], "when": {}, "order": 90, "gated": false }
  ]
}
'@
    $registry = ConvertFrom-Json -InputObject $registryJson -Depth 30
    $nodes = @($registry.executors)
    $order = 10
    foreach ($name in @('alpha', 'beta', 'gamma', 'delta')) {
        $order++
        $nodes += [pscustomobject]@{
            id = 'codex-' + $name; display = 'Codex ' + $name; platform = 'codex'; profile = $name; family = 'codex'; entry = 'scripts/Invoke-CodexRun.ps1'
            profileSettings = [pscustomobject]@{ model = 'm-' + $name; effort = 'medium'; subagentModel = 'sub-' + $name; subagentEffort = 'medium' }
            accepts = @('survey'); tags = @(); when = [pscustomobject]@{}; order = $order; gated = $false
        }
    }
    $registry.executors = $nodes
    return $registry
}

function New-FakeRepo {
    param([string]$Name, [scriptblock]$Mutate, [switch]$Shipped)
    # 假 repo 根目錄：預設使用測試自建的假登錄表（與出貨登錄表隔離）；-Shipped 才複製出貨登錄表。可用 $Mutate 改 JSON 物件。尚未產生檔位設定檔。
    $root = New-TestDirectory -Name $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts\dispatch') -Force
    if ($Shipped) { $registry = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($realRegistry)) -Depth 30 }
    else { $registry = New-FixtureRegistryObject }
    if ($null -ne $Mutate) { & $Mutate $registry }
    Write-TestUtf8 -Path (Join-Path $root 'scripts\dispatch\executor-registry.json') -Text (ConvertTo-Json -InputObject $registry -Depth 30)
    return $root
}

function Get-FileSha {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Test-CanSymlink {
    $directory = New-TestDirectory -Name 'symlink-probe'
    Write-TestUtf8 -Path (Join-Path $directory 'target.txt') -Text 'x'
    try { $null = New-Item -ItemType SymbolicLink -Path (Join-Path $directory 'link.txt') -Target (Join-Path $directory 'target.txt') -ErrorAction Stop; return $true }
    catch { return $false }
}

$canSymlink = Test-CanSymlink

try {
    # ---------- 產生器：決定性與欄位對映 ----------
    Test-Case 'GEN-DETERMINISTIC 同一份登錄表產生的檔案位元組相同，UTF-8 無 BOM、CRLF、首行為請勿手改註解' {
        $rootA = New-FakeRepo -Name 'det-a' -Shipped
        $rootB = New-FakeRepo -Name 'det-b' -Shipped
        $null = Sync-CodexProfileGeneratedFile -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $rootA) -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $rootA)
        $null = Sync-CodexProfileGeneratedFile -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $rootB) -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $rootB)
        $namesA = @(Get-ChildItem -LiteralPath (Get-CodexProfileGeneratedDirectory -RepoRoot $rootA) | ForEach-Object { $_.Name } | Sort-Object)
        Assert-Equal (@($realSpecs | ForEach-Object { $_.FileName } | Sort-Object)) $namesA
        foreach ($name in $namesA) {
            $pathA = Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $rootA) $name
            $pathB = Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $rootB) $name
            Assert-Equal (Get-FileSha -Path $pathA) (Get-FileSha -Path $pathB) ($name + ' 位元組應相同')
            $bytes = [IO.File]::ReadAllBytes($pathA)
            Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) ($name + ' 不得有 BOM')
            $text = [Text.Encoding]::UTF8.GetString($bytes)
            Assert-True ($text.StartsWith('# 此檔由 ') -and $text.Contains('請勿手動編輯')) ($name + ' 首行應為產生檔註解')
            Assert-True ($text.Contains("`r`n") -and -not [regex]::IsMatch($text, "(?<!`r)`n")) ($name + ' 應全為 CRLF')
            Assert-True ($text.EndsWith("`r`n")) ($name + ' 結尾應有換行')
        }
    }
    Test-Case 'GEN-FIELDS 登錄表的 model、effort、子代理設定逐欄對映到檔位檔（固定檔位的假登錄表）' {
        $root = New-FakeRepo -Name 'fields' -Mutate {
            param($r)
            $settings = (Get-FakeCodex -Registry $r -Index 0).profileSettings
            $settings.model = 'm-test-1'
            $settings.effort = [string]@($r.codexEfforts)[1]
            $settings.subagentModel = 'sub-test-2'
            $settings.subagentEffort = [string]@($r.codexEfforts)[2]
        }
        $registryPath = Get-CodexProfileRegistryPath -RepoRoot $root
        $null = Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $root)
        $efforts = @((ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath)) -Depth 30).codexEfforts)
        $text = Read-CodexProfileFileText -Path (Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $root) 'alpha.config.toml')
        $lines = @($text -split "`n" | Where-Object { $_ -notmatch '^\s*(#|$)' })
        Assert-Equal @('model = "m-test-1"', ('model_reasoning_effort = "' + $efforts[1] + '"'), '[agents]', 'enabled = true', 'default_subagent_model = "sub-test-2"', ('default_subagent_reasoning_effort = "' + $efforts[2] + '"')) $lines
        $other = Read-CodexProfileFileText -Path (Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $root) 'beta.config.toml')
        Assert-True ($other.Contains('model = "m-beta"')) '其他檔位不受影響'
    }
    Test-Case 'GEN-FALLBACK-MODELS 登錄表宣告備援 model 時產生檔多一行註解列出清單，未宣告的檔位沒有；model 設定行不變' {
        $root = New-FakeRepo -Name 'fallback' -Mutate {
            param($r)
            (Get-FakeCodex -Registry $r -Index 0).profileSettings | Add-Member -NotePropertyName fallbackModels -NotePropertyValue @('fb-one', 'fb-two')
        }
        $registryPath = Get-CodexProfileRegistryPath -RepoRoot $root
        $spec = @(Read-CodexProfileSpec -RegistryPath $registryPath)
        Assert-Equal @('fb-one', 'fb-two') @($spec[0].FallbackModels)
        Assert-Equal 0 (@($spec[1].FallbackModels).Count)
        $null = Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $root)
        $alpha = Read-CodexProfileFileText -Path (Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $root) 'alpha.config.toml')
        $beta = Read-CodexProfileFileText -Path (Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $root) 'beta.config.toml')
        $comments = @($alpha -split "`n" | Where-Object { $_ -match '^#' })
        Assert-Equal 2 $comments.Count
        Assert-True ($comments[1].Contains('fb-one、fb-two')) ('備援 model 註解不含清單：' + $comments[1])
        Assert-True ($alpha.Contains('model = "m-alpha"')) 'model 設定行應維持主要 model'
        Assert-Equal 1 (@($beta -split "`n" | Where-Object { $_ -match '^#' }).Count) '未宣告備援 model 的檔位只有一行註解'
        # 備援清單改動後產生檔隨之過期，派工前比對因此涵蓋備援清單。
        $raw = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($registryPath)) -Depth 30
        (Get-FakeCodex -Registry $raw -Index 0).profileSettings.fallbackModels = @('fb-two')
        [IO.File]::WriteAllText($registryPath, (ConvertTo-Json -InputObject $raw -Depth 30))
        $changes = @(Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $root) -CheckOnly)
        Assert-Equal @('updated') @($changes | ForEach-Object { $_.action })
    }
    Test-Case 'GEN-REGISTRY-MAPPING 出貨登錄表的每個 Codex 執行者都對映到 repo 內的產生檔，欄位值取自登錄表（不寫死任何值）' {
        $raw = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($realRegistry)) -Depth 30
        $codexNodes = @($raw.executors | Where-Object { $_.platform -ceq 'codex' })
        Assert-Equal $codexNodes.Count $realSpecs.Count
        foreach ($node in $codexNodes) {
            $generated = Join-Path (Get-CodexProfileGeneratedDirectory -RepoRoot $repoRoot) ($node.profile + '.config.toml')
            $text = Read-CodexProfileFileText -Path $generated
            Assert-True ($null -ne $text) ($node.profile + ' 缺產生檔')
            $lines = @($text -split "`n" | Where-Object { $_ -notmatch '^\s*(#|$)' })
            Assert-Equal @(('model = "' + $node.profileSettings.model + '"'), ('model_reasoning_effort = "' + $node.profileSettings.effort + '"'), '[agents]', 'enabled = true', ('default_subagent_model = "' + $node.profileSettings.subagentModel + '"'), ('default_subagent_reasoning_effort = "' + $node.profileSettings.subagentEffort + '"')) $lines
        }
    }
    Test-Case 'GEN-RETIRED-FROM-REGISTRY 已退役檔位名稱只來自登錄表 retiredProfiles，腳本內沒有第二份清單' {
        $raw = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($realRegistry)) -Depth 30
        Assert-Equal @($raw.retiredProfiles) @(Get-CodexRetiredProfileName -RegistryPath $realRegistry)
        foreach ($file in @((Join-Path $scriptsRoot 'Select-DispatchExecutor.ps1'), (Join-Path $scriptsRoot 'lib\executor-registry.ps1'), (Join-Path $scriptsRoot 'codex-run\45-profile-sync.ps1'), (Join-Path $scriptsRoot 'Setup-AIGlobalConfig.ps1'))) {
            $text = [IO.File]::ReadAllText($file)
            foreach ($retired in @($raw.retiredProfiles)) {
                Assert-True (-not $text.Contains("'" + $retired + "'")) ($file + ' 不得內建退役名稱 ' + $retired)
            }
        }
    }
    Test-Case 'GEN-EXPECTED-NEWLINE 產生檔內容的任何欄位值含換行時拒絕' {
        $spec = [pscustomobject]@{ ExecutorId = "evil`n[x]"; Model = 'm'; Effort = 'low'; SubagentModel = 's'; SubagentEffort = 'low' }
        $guard = { $null = Get-CodexProfileExpectedContent -Spec $spec }.GetNewClosure()
        $null = Assert-Throws -Script $guard -Code 'CodexProfileSpecInvalid'
    }
    Test-Case 'GEN-IN-SYNC repo 內進版控的產生檔與登錄表一致' {
        $changes = @(Sync-CodexProfileGeneratedFile -RegistryPath $realRegistry -OutputDirectory (Get-CodexProfileGeneratedDirectory -RepoRoot $repoRoot) -CheckOnly)
        Assert-Equal 0 $changes.Count ('產生檔過期：' + (($changes | ForEach-Object { $_.action + ' ' + $_.path }) -join '; '))
    }
    Test-Case 'GEN-IDEMPOTENT 重複產生不改檔；移除登錄表未列出的產生檔；-CheckOnly 不寫入' {
        $root = New-FakeRepo -Name 'idem'
        $registryPath = Get-CodexProfileRegistryPath -RepoRoot $root
        $output = Get-CodexProfileGeneratedDirectory -RepoRoot $root
        $check = @(Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $output -CheckOnly)
        $specCount = @(Read-CodexProfileSpec -RegistryPath $registryPath).Count
        $firstFile = @(Read-CodexProfileSpec -RegistryPath $registryPath)[0].FileName
        Assert-Equal $specCount $check.Count
        Assert-True (-not (Test-Path -LiteralPath $output)) '-CheckOnly 不得建立目錄或檔案'
        $first = @(Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $output)
        Assert-Equal $specCount $first.Count
        Assert-Equal 0 @(Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $output).Count
        Write-TestUtf8 -Path (Join-Path $output 'ghost.config.toml') -Text 'x'
        Write-TestUtf8 -Path (Join-Path $output $firstFile) -Text 'x'
        $fix = @(Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $output)
        Assert-Equal @('removed', 'updated') @($fix | ForEach-Object { $_.action } | Sort-Object)
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $output 'ghost.config.toml'))) '多餘的產生檔應被移除'
    }
    Test-Case 'GEN-ADD-REMOVE 登錄表增減檔位時，產生檔隨之增減，不需改其他程式' {
        $root = New-FakeRepo -Name 'addremove' -Mutate {
            param($r)
            $extra = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject (Get-FakeCodex -Registry $r -Index 0) -Depth 20) -Depth 20
            $extra.id = 'codex-extra'
            $extra.profile = 'extra'
            $extra.order = 77
            $r.executors = @($r.executors) + @($extra)
        }
        $registryPath = Get-CodexProfileRegistryPath -RepoRoot $root
        $output = Get-CodexProfileGeneratedDirectory -RepoRoot $root
        $null = Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $output
        Assert-True (Test-Path -LiteralPath (Join-Path $output 'extra.config.toml')) '新增檔位應產生檔案'
        Assert-Equal 5 @(Read-CodexProfileSpec -RegistryPath $registryPath).Count
    }

    # ---------- 登錄表缺欄位或值不合法（驗證由共用函式檔 scripts\lib\executor-registry.ps1 提供，選派入口、產生器與派工前比對共用） ----------
    $invalidCases = @(
        @{ id = 'no-settings'; message = 'profileSettings'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).PSObject.Properties.Remove('profileSettings') } },
        @{ id = 'no-effort'; message = 'effort'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 1).profileSettings.PSObject.Properties.Remove('effort') } },
        @{ id = 'no-subagent-model'; message = 'subagentModel'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 2).profileSettings.PSObject.Properties.Remove('subagentModel') } },
        @{ id = 'quote-injection'; message = 'model'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings.model = 'x"; [evil]' } },
        @{ id = 'empty-model'; message = 'model'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings.model = '' } },
        @{ id = 'non-string'; message = 'effort'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings.effort = 5 } },
        @{ id = 'effort-not-allowed'; message = 'codexEfforts'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings.effort = 'turbo' } },
        @{ id = 'subagent-effort-not-allowed'; message = 'codexEfforts'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings.subagentEffort = 'turbo' } },
        @{ id = 'unknown-key'; message = 'unexpected'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings | Add-Member -NotePropertyName unexpected -NotePropertyValue 'x' } },
        @{ id = 'dup-profile'; message = '被多個執行者使用'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 1).profile = (Get-FakeCodex -Registry $r -Index 0).profile } },
        @{ id = 'bad-profile-name'; message = 'profile'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profile = '..\evil' } },
        @{ id = 'retired-name'; message = '已退役'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).profile = [string]@($r.retiredProfiles)[0] } },
        @{ id = 'platform-case-variant'; message = 'platform'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).platform = 'Codex' } },
        @{ id = 'missing-id'; message = 'id'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).PSObject.Properties.Remove('id') } },
        @{ id = 'newline-id'; message = 'id'; mutate = { param($r) (Get-FakeCodex -Registry $r -Index 0).id = "codex-x`n[evil]" } },
        @{ id = 'no-efforts-list'; message = 'codexEfforts'; mutate = { param($r) $r.PSObject.Properties.Remove('codexEfforts') } }
    )
    foreach ($case in $invalidCases) {
        $caseCopy = $case
        Test-Case ('SPEC-INVALID-' + $caseCopy.id + ' 登錄表缺欄位或值不合法時以 CodexProfileSpecInvalid 拒絕') {
            $root = New-FakeRepo -Name ('invalid-' + $caseCopy.id) -Mutate $caseCopy.mutate
            $readScript = { $null = Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $root) }.GetNewClosure()
            $caught = Assert-Throws -Script $readScript -Code 'CodexProfileSpecInvalid' -MessageContains $caseCopy.message
            Assert-True ($caught.Message.Contains('SelectorRegistryInvalid')) ('應由共用驗證擋下：' + $caught.Message)
        }
    }
    Test-Case 'SPEC-INVALID-hook 登錄表無效時產生器結束碼 1、不寫任何產生檔（與選派入口同一組共用函式驗證）' {
        $root = New-FakeRepo -Name 'invalid-hook' -Mutate { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings.effort = 'turbo' }
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -NoStage 2>&1
        Assert-Equal 1 $LASTEXITCODE
        Assert-True (-not (Test-Path -LiteralPath (Get-CodexProfileGeneratedDirectory -RepoRoot $root))) '不得產生任何檔案'
    }
    Test-Case 'SPEC-INVALID-file 登錄表不存在或不是 JSON 時以 CodexProfileSpecInvalid 拒絕' {
        $root = New-TestDirectory -Name 'badjson'
        $absentScript = { $null = Read-CodexProfileSpec -RegistryPath (Join-Path $root 'absent.json') }.GetNewClosure()
        $null = Assert-Throws -Script $absentScript -Code 'CodexProfileSpecInvalid'
        Write-TestUtf8 -Path (Join-Path $root 'bad.json') -Text '{ not json'
        $badScript = { $null = Read-CodexProfileSpec -RegistryPath (Join-Path $root 'bad.json') }.GetNewClosure()
        $null = Assert-Throws -Script $badScript -Code 'CodexProfileSpecInvalid'
    }

    # ---------- 共用函式檔的載入：45-profile-sync.ps1 以自身位置為基準載入 scripts\lib\executor-registry.ps1 ----------
    function Invoke-ProfileSyncLoad {
        param([string]$Root)
        # 在子行程 dot-source 複製到 $Root 的 45-profile-sync.ps1，回傳結束碼與 stderr。
        $modulePath = Join-Path $Root 'scripts\codex-run\45-profile-sync.ps1'
        $command = '$ErrorActionPreference = ''Stop''; try { . ''' + $modulePath.Replace("'", "''") + '''; exit 0 } catch { $code = if ($_.Exception.Data.Contains(''Code'')) { $_.Exception.Data[''Code''] } else { ''(none)'' }; [Console]::Error.WriteLine($code + ''|'' + $_.Exception.Message); exit 7 }'
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $hostPath
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-Command', $command)) { [void]$startInfo.ArgumentList.Add($argument) }
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardError = $true
        $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
        $process = [System.Diagnostics.Process]::Start($startInfo)
        try {
            $stderr = $process.StandardError.ReadToEnd()
            $process.WaitForExit()
            return [pscustomobject]@{ ExitCode = $process.ExitCode; StdErr = $stderr }
        }
        finally { $process.Dispose() }
    }
    Test-Case 'LIB-LOAD-MISSING 共用函式檔不存在時 45-profile-sync.ps1 以 CodexProfileSpecInvalid 明確失敗' {
        $root = New-TestDirectory -Name 'lib-missing'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts\codex-run') -Force
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'codex-run\45-profile-sync.ps1') -Destination (Join-Path $root 'scripts\codex-run\45-profile-sync.ps1')
        $result = Invoke-ProfileSyncLoad -Root $root
        Assert-Equal 7 $result.ExitCode
        Assert-True ($result.StdErr.StartsWith('CodexProfileSpecInvalid|') -and $result.StdErr.Contains('lib\executor-registry.ps1')) ('訊息應指出共用函式檔：' + $result.StdErr)
    }
    Test-Case 'LIB-LOAD-SYNTAX 共用函式檔有語法錯誤時 45-profile-sync.ps1 以 CodexProfileSpecInvalid 明確失敗' {
        $root = New-TestDirectory -Name 'lib-syntax'
        $null = New-Item -ItemType Directory -Path (Join-Path $root 'scripts\codex-run') -Force
        Copy-Item -LiteralPath (Join-Path $scriptsRoot 'codex-run\45-profile-sync.ps1') -Destination (Join-Path $root 'scripts\codex-run\45-profile-sync.ps1')
        Write-TestUtf8 -Path (Join-Path $root 'scripts\lib\executor-registry.ps1') -Text 'function Read-ExecutorRegistry { '
        $result = Invoke-ProfileSyncLoad -Root $root
        Assert-Equal 7 $result.ExitCode
        Assert-True ($result.StdErr.StartsWith('CodexProfileSpecInvalid|')) ('應以 CodexProfileSpecInvalid 失敗：' + $result.StdErr)
    }
    Test-Case 'LIB-SINGLE-VALIDATION 45-profile-sync.ps1 不以子行程執行選派入口，登錄表驗證只來自共用函式 Read-ExecutorRegistry' {
        $text = [IO.File]::ReadAllText((Join-Path $scriptsRoot 'codex-run\45-profile-sync.ps1'))
        Assert-True (-not $text.Contains('-Describe')) '不得以選派入口的 -Describe 取得驗證結果'
        Assert-True (-not $text.Contains('ProcessStartInfo') -and -not $text.Contains('Start-Process')) '不得啟動子行程'
        Assert-True ($text.Contains('Read-ExecutorRegistry -Path')) '應呼叫共用函式'
        $libraryCommand = Get-Command -Name 'Read-ExecutorRegistry' -CommandType Function
        Assert-Equal ([IO.Path]::GetFullPath((Join-Path $scriptsRoot 'lib\executor-registry.ps1'))) $libraryCommand.ScriptBlock.File
    }
    # ---------- pre-commit 腳本 ----------
    Test-Case 'HOOK-GENERATE 腳本在假 repo 寫出產生檔；-Check 一致時結束碼 0，過期時 1 且不寫檔；登錄表無效時 1' {
        $root = New-FakeRepo -Name 'hook'
        $output = Get-CodexProfileGeneratedDirectory -RepoRoot $root
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -NoStage
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal @(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $root)).Count @(Get-ChildItem -LiteralPath $output -Filter '*.config.toml').Count
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -Check
        Assert-Equal 0 $LASTEXITCODE
        $review = Join-Path $output @(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $root))[0].FileName
        Write-TestUtf8 -Path $review -Text 'stale'
        $shaBefore = Get-FileSha -Path $review
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -Check
        Assert-Equal 1 $LASTEXITCODE
        Assert-Equal $shaBefore (Get-FileSha -Path $review) '-Check 不得寫檔'
        Write-TestUtf8 -Path (Get-CodexProfileRegistryPath -RepoRoot $root) -Text '{ bad'
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -NoStage 2>&1
        Assert-Equal 1 $LASTEXITCODE
        Assert-Equal $shaBefore (Get-FileSha -Path $review) '登錄表無效時不得改產生檔'
    }
    Test-Case 'HOOK-STAGE 腳本寫檔後以 git add 暫存輸出目錄' {
        $root = New-FakeRepo -Name 'hookstage'
        $null = & git -C $root init -q
        Assert-Equal 0 $LASTEXITCODE
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root
        Assert-Equal 0 $LASTEXITCODE
        $staged = @(& git -C $root diff --cached --name-only)
        Assert-Equal @(@(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $root)) | ForEach-Object { 'scripts/codex-profiles/' + $_.FileName } | Sort-Object) @($staged | Sort-Object)
    }

    # ---------- 連結：比對現況（唯讀）與建立 ----------
    function New-LinkEnvironment {
        param([string]$Name)
        $root = New-FakeRepo -Name $Name
        $registryPath = Get-CodexProfileRegistryPath -RepoRoot $root
        $generated = Get-CodexProfileGeneratedDirectory -RepoRoot $root
        $null = Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $generated
        $accountHome = Join-Path $root 'account'
        $null = New-Item -ItemType Directory -Path $accountHome -Force
        return [pscustomobject]@{ Root = $root; Registry = $registryPath; Generated = $generated; Account = $accountHome; Specs = @(Read-CodexProfileSpec -RegistryPath $registryPath) }
    }
    Test-Case 'LINK-STATE-READONLY 比對現況只讀：不存在、一般檔案、目錄各自判定，且不改任何東西' {
        $e = New-LinkEnvironment -Name 'state'
        Write-TestUtf8 -Path (Join-Path $e.Account 'beta.config.toml') -Text 'hand'
        $null = New-Item -ItemType Directory -Path (Join-Path $e.Account 'gamma.config.toml')
        $before = @(Get-ChildItem -LiteralPath $e.Account -Force | ForEach-Object { $_.Name }) -join '|'
        $states = @(Get-CodexProfileAccountState -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
        $byProfile = @{}
        foreach ($state in $states) { $byProfile[$state.profile] = $state }
        Assert-Equal 'missing' $byProfile['alpha'].state
        Assert-Equal 'not-link' $byProfile['beta'].state
        Assert-Equal 'File' $byProfile['beta'].kind
        Assert-Equal 'not-link' $byProfile['gamma'].state
        Assert-Equal 'Directory' $byProfile['gamma'].kind
        Assert-True ((@($byProfile['alpha'].fix_commands) -join "`n").Contains('New-Item -ItemType SymbolicLink')) '缺連結時應附建立命令'
        Assert-True ((@($byProfile['beta'].fix_commands) -join "`n").Contains('Move-Item')) '一般檔案時應附移走命令'
        Assert-Equal $before ((@(Get-ChildItem -LiteralPath $e.Account -Force | ForEach-Object { $_.Name }) -join '|')) '比對不得改動帳號目錄'
    }
    if ($canSymlink) {
        Test-Case 'LINK-CREATE 不存在時建立指向 repo 產生檔的連結；重複執行為 ok；比對現況全為 ok' {
            $e = New-LinkEnvironment -Name 'create'
            $first = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
            Assert-Equal $e.Specs.Count @($first | Where-Object { $_.action -ceq 'created' }).Count
            foreach ($spec in $e.Specs) {
                $item = Get-Item -LiteralPath (Join-Path $e.Account $spec.FileName) -Force
                Assert-Equal 'SymbolicLink' ([string]$item.LinkType)
                Assert-Equal (Join-Path $e.Generated $spec.FileName) (@($item.Target) -join '')
            }
            $second = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
            Assert-Equal $e.Specs.Count @($second | Where-Object { $_.action -ceq 'ok' }).Count
            $states = @(Get-CodexProfileAccountState -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
            Assert-Equal $e.Specs.Count @($states | Where-Object { $_.state -ceq 'ok' }).Count
        }
        Test-Case 'LINK-REGULAR-FILE 帳號目錄已有一般檔案：不覆蓋、action=blocked、附命令，內容不變' {
            $e = New-LinkEnvironment -Name 'regular'
            $path = Join-Path $e.Account 'alpha.config.toml'
            Write-TestUtf8 -Path $path -Text 'model = "hand-edited"'
            $sha = Get-FileSha -Path $path
            $results = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
            $review = @($results | Where-Object { $_.profile -ceq 'alpha' })[0]
            Assert-Equal 'blocked' $review.action
            Assert-Equal 'not-link' $review.state
            Assert-True ((@($review.fix_commands) -join "`n").Contains($path)) '命令應含該檔案路徑'
            Assert-Equal $sha (Get-FileSha -Path $path) '一般檔案內容不得改變'
            Assert-Equal ($e.Specs.Count - 1) @($results | Where-Object { $_.action -ceq 'created' }).Count '其他檔位仍照常建立'
        }
        Test-Case 'LINK-WRONG-TARGET 連結指向別處：不覆蓋、action=blocked、state=wrong-target，連結目標不變' {
            $e = New-LinkEnvironment -Name 'wrong'
            $other = Join-Path $e.Root 'elsewhere.toml'
            Write-TestUtf8 -Path $other -Text 'x'
            $path = Join-Path $e.Account 'beta.config.toml'
            $null = New-Item -ItemType SymbolicLink -Path $path -Target $other
            $results = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
            $scan = @($results | Where-Object { $_.profile -ceq 'beta' })[0]
            Assert-Equal 'blocked' $scan.action
            Assert-Equal 'wrong-target' $scan.state
            Assert-Equal $other $scan.actual_target
            Assert-True ((@($scan.fix_commands) -join "`n").Contains('Remove-Item -LiteralPath')) '命令應只移除連結本身'
            Assert-Equal $other (@((Get-Item -LiteralPath $path -Force).Target) -join '') '連結目標不得改變'
        }
        Test-Case 'LINK-TARGET-MISSING repo 產生檔不存在時不建立連結，action=target-missing' {
            $e = New-LinkEnvironment -Name 'notarget'
            Remove-Item -LiteralPath (Join-Path $e.Generated 'delta.config.toml') -Force
            $results = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
            $advisor = @($results | Where-Object { $_.profile -ceq 'delta' })[0]
            Assert-Equal 'target-missing' $advisor.action
            Assert-True ($null -eq (Get-Item -LiteralPath (Join-Path $e.Account 'delta.config.toml') -Force -ErrorAction SilentlyContinue)) '不得建立指向不存在檔案的連結'
        }
        Test-Case 'LINK-WHATIF -WhatIf 只回報 would-create，不建立' {
            $e = New-LinkEnvironment -Name 'whatif'
            $results = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs -WhatIf)
            Assert-Equal $e.Specs.Count @($results | Where-Object { $_.action -ceq 'would-create' }).Count
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $e.Account -Force).Count
        }
    }
    else {
        foreach ($id in @('CONSIST-LINK-SAME-CONTENT-WRONG-TARGET', 'LINK-CREATE', 'LINK-REGULAR-FILE', 'LINK-WRONG-TARGET', 'LINK-TARGET-MISSING', 'LINK-WHATIF')) { Skip-Case $id '沒有建立 Symbolic Link 的權限' }
    }
    Test-Case 'LINK-CREATE-LOGIC 建立分支（不需 Symbolic Link 權限，以替身 New-Item 驗證呼叫引數與結果判定）' {
        $e = New-LinkEnvironment -Name 'mock-create'
        $created = New-Object 'System.Collections.Generic.List[string]'
        function New-Item {
            [CmdletBinding()]
            param([string]$ItemType, [string]$Path, [string]$Target, [switch]$Force)
            if ($ItemType -ceq 'SymbolicLink') {
                $created.Add($Path + '=>' + $Target)
                [IO.File]::WriteAllText($Path, 'stand-in')
                return
            }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }
        $results = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
        Assert-Equal $e.Specs.Count @($results | Where-Object { $_.action -ceq 'created' }).Count
        $expected = @($e.Specs | ForEach-Object { (Join-Path $e.Account $_.FileName) + '=>' + (Join-Path $e.Generated $_.FileName) } | Sort-Object)
        Assert-Equal $expected @($created.ToArray() | Sort-Object)
        # 第二次執行時 LinkPath 已存在（替身為一般檔案），不得再次建立。
        $before = $created.Count
        $second = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
        Assert-Equal $before $created.Count
        Assert-Equal $e.Specs.Count @($second | Where-Object { $_.action -ceq 'blocked' }).Count
    }
    Test-Case 'LINK-CREATE-FAILED 建立連結失敗（例如權限不足）：action=create-failed 並帶錯誤訊息，不拋出、不建立任何檔案' {
        $e = New-LinkEnvironment -Name 'mock-fail'
        function New-Item {
            [CmdletBinding()]
            param([string]$ItemType, [string]$Path, [string]$Target, [switch]$Force)
            if ($ItemType -ceq 'SymbolicLink') { throw '用戶端沒有所需的權限。' }
            Microsoft.PowerShell.Management\New-Item @PSBoundParameters
        }
        $results = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
        Assert-Equal $e.Specs.Count @($results | Where-Object { $_.action -ceq 'create-failed' -and $_.error.Contains('權限') }).Count
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $e.Account -Force).Count
    }
    Test-Case 'LINK-JUNCTION 帳號目錄內是指向別處的 Junction（不需要 Symbolic Link 權限即可建立）：不覆蓋、state=wrong-target、action=blocked' {
        $e = New-LinkEnvironment -Name 'junction'
        $elsewhere = Join-Path $e.Root 'elsewhere-dir'
        $null = New-Item -ItemType Directory -Path $elsewhere
        $path = Join-Path $e.Account 'beta.config.toml'
        $null = New-Item -ItemType Junction -Path $path -Target $elsewhere
        $results = @(New-CodexProfileAccountLink -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs -WhatIf)
        $scan = @($results | Where-Object { $_.profile -ceq 'beta' })[0]
        Assert-Equal 'wrong-target' $scan.state
        Assert-Equal 'blocked' $scan.action
        Assert-Equal 'Junction' $scan.kind
        Assert-Equal 'Junction' ([string](Get-Item -LiteralPath $path -Force).LinkType) '連結不得被改動'
    }
    Test-Case 'FIX-LINES 修正命令每個獨立成行、只含命令（說明在 fix_note），Format 後的說明以 # 開頭可整段貼上' {
        $e = New-LinkEnvironment -Name 'fixlines'
        Write-TestUtf8 -Path (Join-Path $e.Account 'beta.config.toml') -Text 'hand'
        $other = Join-Path $e.Root 'elsewhere-dir'
        $null = New-Item -ItemType Directory -Path $other
        $null = New-Item -ItemType Junction -Path (Join-Path $e.Account 'gamma.config.toml') -Target $other
        $states = @(Get-CodexProfileAccountState -AccountHome $e.Account -ProfileDirectory $e.Generated -Spec $e.Specs)
        foreach ($state in $states) {
            Assert-True (@($state.fix_commands).Count -ge 1) ($state.profile + ' 應有修正命令')
            foreach ($command in @($state.fix_commands)) {
                Assert-True ($command -cmatch '^(New-Item|Remove-Item|Move-Item) ') ('命令行不得混說明文字：' + $command)
                Assert-True ($command -cnotmatch '[一-鿿]') ('命令行不得含中文說明：' + $command)
            }
            Assert-True (-not [string]::IsNullOrWhiteSpace($state.fix_note)) '說明放在 fix_note'
            $lines = @(Format-CodexProfileFixLine -Command $state.fix_commands -Note $state.fix_note)
            Assert-True ($lines[0].StartsWith('# ')) '說明行以 # 開頭'
            Assert-Equal @($state.fix_commands).Count ($lines.Count - 1)
        }
    }
    Test-Case 'FIX-TARGET-MAIN 修正命令的連結目標取自傳入的產生檔目錄（主 checkout），不是別的路徑' {
        $e = New-LinkEnvironment -Name 'fixmain'
        $findings = @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha')
        $createLine = @($findings[0].fix_commands | Where-Object { $_.StartsWith('New-Item') })[0]
        Assert-True ($createLine.Contains((Join-Path $e.Generated 'alpha.config.toml'))) '建立命令的目標應是產生檔目錄內的檔案'
    }
    Test-Case 'MAIN-CHECKOUT 在 linked worktree 內取得的是主 checkout，在主 checkout 內取得自己' {
        $main = New-TestDirectory -Name 'maincheckout'
        $null = & git -C $main init -q
        $null = & git -C $main -c user.name=t -c user.email=t@t.invalid commit -q --allow-empty -m init
        $worktree = Join-Path (New-TestDirectory -Name 'wtparent') 'wt'
        $null = & git -C $main worktree add -q $worktree
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal ([IO.Path]::GetFullPath($main)) (Get-CodexProfileMainCheckoutRoot -RepoRoot $worktree)
        Assert-Equal ([IO.Path]::GetFullPath($main)) (Get-CodexProfileMainCheckoutRoot -RepoRoot $main)
        $plain = New-TestDirectory -Name 'notgit'
        Assert-Equal $plain (Get-CodexProfileMainCheckoutRoot -RepoRoot $plain)
    }
    Test-Case 'HOOK-INDEX -FromIndex 以暫存區的登錄表產生：登錄表只改工作樹未暫存時不多出暫存變更，暫存後才產生新值' {
        $root = New-FakeRepo -Name 'hookindex'
        $null = & git -C $root init -q
        $null = & git -C $root add -A
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -FromIndex
        Assert-Equal 0 $LASTEXITCODE
        $null = & git -C $root -c user.name=t -c user.email=t@t.invalid commit -q -m base
        $registryFile = Get-CodexProfileRegistryPath -RepoRoot $root
        $original = [IO.File]::ReadAllText($registryFile)
        $changed = ConvertFrom-Json -InputObject $original -Depth 30
        (Get-FakeCodex -Registry $changed -Index 0).profileSettings.model = 'm-index-test'
        [IO.File]::WriteAllText($registryFile, (ConvertTo-Json -InputObject $changed -Depth 30))
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -FromIndex
        Assert-Equal 0 $LASTEXITCODE
        Assert-Equal 0 @(& git -C $root diff --cached --name-only).Count '登錄表未暫存時不得有暫存變更'
        Assert-Equal 0 @(& git -C $root status --porcelain -- scripts/codex-profiles).Count '產生檔不得有任何變動'
        $null = & git -C $root add -- scripts/dispatch/executor-registry.json
        $null = & $hostPath -NoProfile -File $hookPath -RepoRoot $root -FromIndex
        Assert-Equal 0 $LASTEXITCODE
        $staged = @(& git -C $root diff --cached --name-only | Sort-Object)
        Assert-Equal @(('scripts/codex-profiles/' + @(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $root))[0].FileName), 'scripts/dispatch/executor-registry.json' | Sort-Object) $staged
        Assert-True ((& git -C $root show (':scripts/codex-profiles/' + @(Read-CodexProfileSpec -RegistryPath (Get-CodexProfileRegistryPath -RepoRoot $root))[0].FileName)) -join "`n" -match 'm-index-test') '暫存的產生檔應含新值'
        $leftover = @(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Filter 'registry-index-*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) })
        Assert-Equal 0 $leftover.Count '暫存的登錄表複本應被清除'
    }
    Test-Case 'LINK-RESIDUE 列出帳號目錄內已退役的檔位檔，不刪除' {
        $directory = New-TestDirectory -Name 'residue'
        Write-TestUtf8 -Path (Join-Path $directory 'default.config.toml') -Text 'x'
        Write-TestUtf8 -Path (Join-Path $directory 'alpha.config.toml') -Text 'x'
        $found = @(Get-CodexProfileResidue -Directory $directory -RetiredName @('default', 'gone'))
        Assert-Equal @((Join-Path $directory 'default.config.toml')) $found
        Assert-True (Test-Path -LiteralPath (Join-Path $directory 'default.config.toml')) '不得刪除'
    }

    # ---------- 派工前比對（函式層） ----------
    Test-Case 'CONSIST-MATCH 帳號檔位檔是指向產生檔的連結（以替身表示連結正確）且內容相同：無 finding；CRLF 與 LF 視為相同' {
        $e = New-LinkEnvironment -Name 'consist-ok'
        function Get-CodexProfileLinkState {
            param([string]$LinkPath, [string]$TargetPath)
            return [pscustomobject]@{ state = 'ok'; path = $LinkPath; expected_target = $TargetPath; actual_target = $TargetPath; kind = 'SymbolicLink'; fix_commands = [string[]]@(); fix_note = $null }
        }
        $generated = Join-Path $e.Generated 'alpha.config.toml'
        $accountFile = Join-Path $e.Account 'alpha.config.toml'
        Copy-Item -LiteralPath $generated -Destination $accountFile
        Assert-Equal 0 @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha').Count
        [IO.File]::WriteAllText($accountFile, ([IO.File]::ReadAllText($generated)).Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding($false)))
        Assert-Equal 0 @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha').Count
    }
    Test-Case 'CONSIST-REGULAR-FILE 內容相同的一般檔案也判不一致（ProfileFileNotLink），修正命令照連結改接格式，不改檔' {
        $e = New-LinkEnvironment -Name 'consist-regular'
        $accountFile = Join-Path $e.Account 'alpha.config.toml'
        Copy-Item -LiteralPath (Join-Path $e.Generated 'alpha.config.toml') -Destination $accountFile
        $sha = Get-FileSha -Path $accountFile
        $findings = @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha')
        Assert-Equal 1 $findings.Count
        Assert-Equal 'ProfileFileNotLink' $findings[0].code
        $joined = @($findings[0].fix_commands) -join "`n"
        Assert-True ($joined.Contains('Move-Item') -and $joined.Contains('New-Item -ItemType SymbolicLink')) '修正命令應為移走一般檔案後建立連結'
        Assert-Equal $sha (Get-FileSha -Path $accountFile)
    }
    Test-Case 'TREE-REGISTRY 入口所在工作樹的登錄表設定尚未落地到主 checkout 時回報 TreeRegistryNotLanded；已落地則無 finding' {
        $main = New-LinkEnvironment -Name 'tree-main'
        $tree = New-FakeRepo -Name 'tree-wt' -Mutate { param($r) (Get-FakeCodex -Registry $r -Index 0).profileSettings.model = 'm-not-landed' }
        function Get-CodexProfileLinkState {
            param([string]$LinkPath, [string]$TargetPath)
            return [pscustomobject]@{ state = 'ok'; path = $LinkPath; expected_target = $TargetPath; actual_target = $TargetPath; kind = 'SymbolicLink'; fix_commands = [string[]]@(); fix_note = $null }
        }
        Copy-Item -LiteralPath (Join-Path $main.Generated 'alpha.config.toml') -Destination (Join-Path $main.Account 'alpha.config.toml')
        $treeRegistry = Get-CodexProfileRegistryPath -RepoRoot $tree
        $findings = @(Test-CodexProfileConsistency -RegistryPath $main.Registry -GeneratedDirectory $main.Generated -AccountHome @($main.Account) -Profile 'alpha' -TreeRegistryPath $treeRegistry)
        Assert-Equal @('TreeRegistryNotLanded') @($findings | ForEach-Object { $_.code })
        Assert-True ($findings[0].detail.Contains('尚未落地')) '訊息應說明工作樹的登錄表尚未落地'
        Assert-Equal 0 @(Test-CodexProfileConsistency -RegistryPath $main.Registry -GeneratedDirectory $main.Generated -AccountHome @($main.Account) -Profile 'alpha' -TreeRegistryPath $main.Registry).Count
        $sameContentTree = New-FakeRepo -Name 'tree-same'
        Assert-Equal 0 @(Test-CodexProfileConsistency -RegistryPath $main.Registry -GeneratedDirectory $main.Generated -AccountHome @($main.Account) -Profile 'alpha' -TreeRegistryPath (Get-CodexProfileRegistryPath -RepoRoot $sameContentTree)).Count
    }
    Test-Case 'CONSIST-DRIFT 內容不同：ProfileFileDrift，附路徑與修正方式，不改檔' {
        $e = New-LinkEnvironment -Name 'consist-drift'
        $accountFile = Join-Path $e.Account 'alpha.config.toml'
        Write-TestUtf8 -Path $accountFile -Text 'model = "hand"'
        $sha = Get-FileSha -Path $accountFile
        $findings = @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha')
        Assert-Equal 1 $findings.Count
        Assert-Equal 'ProfileFileDrift' $findings[0].code
        Assert-Equal $accountFile $findings[0].path
        Assert-True ((@($findings[0].fix_commands) -join "`n").Contains('Move-Item')) '一般檔案的修正方式應為移走後建立連結'
        Assert-Equal $sha (Get-FileSha -Path $accountFile)
    }
    Test-Case 'CONSIST-MISSING 帳號目錄沒有檔位檔：ProfileFileMissing 附建立連結命令' {
        $e = New-LinkEnvironment -Name 'consist-missing'
        $findings = @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'beta')
        Assert-Equal 'ProfileFileMissing' $findings[0].code
        Assert-True ((@($findings[0].fix_commands) -join "`n").Contains('New-Item -ItemType SymbolicLink')) '應附建立連結命令'
    }
    Test-Case 'CONSIST-STALE-GENERATED repo 產生檔與登錄表不符：GeneratedStale，帳號檔與產生檔相同時仍回報產生檔過期' {
        $e = New-LinkEnvironment -Name 'consist-stale'
        function Get-CodexProfileLinkState {
            param([string]$LinkPath, [string]$TargetPath)
            return [pscustomobject]@{ state = 'ok'; path = $LinkPath; expected_target = $TargetPath; actual_target = $TargetPath; kind = 'SymbolicLink'; fix_commands = [string[]]@(); fix_note = $null }
        }
        $generated = Join-Path $e.Generated 'alpha.config.toml'
        Write-TestUtf8 -Path $generated -Text "model = `"old`"`n"
        Copy-Item -LiteralPath $generated -Destination (Join-Path $e.Account 'alpha.config.toml')
        $findings = @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha')
        Assert-Equal @('GeneratedStale') @($findings | ForEach-Object { $_.code })
    }
    Test-Case 'CONSIST-MISSING-GENERATED 產生檔不存在：GeneratedMissing；檔位不在登錄表：ProfileNotInRegistry' {
        $e = New-LinkEnvironment -Name 'consist-nogen'
        Remove-Item -LiteralPath (Join-Path $e.Generated 'alpha.config.toml') -Force
        Assert-Equal 'GeneratedMissing' @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha')[0].code
        Assert-Equal 'ProfileNotInRegistry' @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'ghost')[0].code
    }
    if ($canSymlink) {
        Test-Case 'CONSIST-LINK-OTHER-CHECKOUT 連結正確但指向別的 checkout 的舊產生檔：ProfileFileDrift 並提示落地' {
            $e = New-LinkEnvironment -Name 'consist-other'
            $otherDirectory = Join-Path $e.Root 'other-generated'
            $null = New-Item -ItemType Directory -Path $otherDirectory
            Write-TestUtf8 -Path (Join-Path $otherDirectory 'alpha.config.toml') -Text "model = `"old`"`n"
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $e.Account 'alpha.config.toml') -Target (Join-Path $otherDirectory 'alpha.config.toml')
            $findings = @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha')
            Assert-Equal 'ProfileFileDrift' $findings[0].code
            Assert-True ($findings[0].detail.Contains('wrong-target')) '應指出連結目標不同'
            Assert-True ((@($findings[0].fix_commands) -join "`
").Contains((Join-Path $e.Generated 'alpha.config.toml'))) '修正命令的目標應是 repo 產生檔（主 checkout）'
        }
        Test-Case 'CONSIST-LINK-SAME-CONTENT-WRONG-TARGET 內容相同但連結指向別的 checkout：ProfileLinkWrongTarget' {
            $e = New-LinkEnvironment -Name 'consist-samecontent'
            $otherDirectory = Join-Path $e.Root 'other-generated'
            $null = New-Item -ItemType Directory -Path $otherDirectory
            Copy-Item -LiteralPath (Join-Path $e.Generated 'alpha.config.toml') -Destination (Join-Path $otherDirectory 'alpha.config.toml')
            $null = New-Item -ItemType SymbolicLink -Path (Join-Path $e.Account 'alpha.config.toml') -Target (Join-Path $otherDirectory 'alpha.config.toml')
            $findings = @(Test-CodexProfileConsistency -RegistryPath $e.Registry -GeneratedDirectory $e.Generated -AccountHome @($e.Account) -Profile 'alpha')
            Assert-Equal 'ProfileLinkWrongTarget' $findings[0].code
            Assert-True ((@($findings[0].fix_commands) -join "`n").Contains((Join-Path $e.Generated 'alpha.config.toml'))) '修正命令的目標應是 repo 產生檔'
        }
    }
    else { Skip-Case 'CONSIST-LINK-OTHER-CHECKOUT' '沒有建立 Symbolic Link 的權限' }
}
finally {
    $exitCode = Complete-TestRun
}
exit $exitCode
