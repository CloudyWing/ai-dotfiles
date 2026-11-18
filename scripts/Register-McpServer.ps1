#Requires -Version 7.0
<#
.SYNOPSIS
把 mcp-lab、infra-lab 與 FlaUI.Mcp 登記到 Claude Code 與 Codex 桌面版的設定，只寫設定。

.DESCRIPTION
腳本不拉 repo、不下載、不安裝、不啟動服務；這三者的安裝與啟動依 README 手動完成。不需要系統管理員身分。

-McpLab     把範本 templates\claude-mcp-servers.json 的 11 個伺服器登記到 Claude Code 使用者層，名稱不變，已存在者不覆寫。
-InfraLab   把 infra-lab 登記到 Claude Code 使用者層。首次登記需要 -InfraLabDistro 與 -InfraLabWslRepo，值取自在 WSL 內執行 task mcp:config 印出的命令；登記後存於 ~\.claude.json，重跑不必再提供。
-FlaUI      把 FlaUI.Mcp 執行檔路徑寫入 Codex 桌面版設定檔（~\.codex\config.toml）的 [mcp_servers.flaui-mcp] 的 command，並同步更新 .local\machine.json 的 codex_accounts 登記的每個派工帳號的 config.toml。
            預設路徑為 %LOCALAPPDATA%\Programs\FlaUI-MCP\FlaUI.Mcp.exe，可用 -FlaUIPath 指定其他路徑（相對路徑會先轉成絕對路徑）。
            桌面版與帳號的 [mcp_servers.flaui-mcp] 已存在時只改 command 那一行，其餘內容（含帳號的 enabled = false）不變；帳號沒有該表時依 Setup 複製的形式追加整張表（含 enabled = false）。
            執行檔不存在或設定檔不存在時不寫入並回報；單一帳號的設定檔不存在、讀不到或寫法無法確定時略過該帳號並回報，其餘帳號照常處理，最後結束碼為 1。沒有登記帳號或沒有 machine.json 時只處理桌面版，不影響結束碼。
            每個檔案寫入前各備份一份到 .local\ai-sessions\backups\<時間戳>\（桌面版為 desktop\config.toml，帳號為 accounts\<帳號名稱>\config.toml）並附 manifest.txt（備份根目錄可用 -BackupRoot 指定）。
            取代檔案前會確認原檔自讀取後未被改動，改動過就不寫入並回報；設定檔是符號連結時寫入連結指向的實際檔案。
            -MachineConfigPath 指定帳號登記檔，預設為本 repo 的 .local\machine.json。
-Check      唯讀檢查，回報所選項目是否已登記，不寫入任何檔案；沒有指定項目時檢查全部三項。infra-lab 另檢查 WSL 是否存在，缺少時結束碼非零。
            FlaUI 另檢查每個派工帳號的 command 是否與桌面版相同，不同時指出帳號名稱並使結束碼非零。
            mcp-lab 服務未啟動與 FlaUI.Mcp 執行檔不存在只在備註提示，不影響結束碼。
-WhatIf     預演，不寫入任何東西。

沒有指定任何項目（且沒有 -Check）時不做任何寫入，印出用法。結束碼：全部完成或符合為 0，否則為 1。

.EXAMPLE
Register-McpServer.ps1 -McpLab

.EXAMPLE
Register-McpServer.ps1 -InfraLab -InfraLabDistro Ubuntu -InfraLabWslRepo /opt/infra-lab

.EXAMPLE
Register-McpServer.ps1 -FlaUI -FlaUIPath D:\Tools\FlaUI-MCP\FlaUI.Mcp.exe -WhatIf

.EXAMPLE
Register-McpServer.ps1 -Check
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$McpLab,
    [switch]$InfraLab,
    [switch]$FlaUI,
    [string]$InfraLabDistro,
    [string]$InfraLabWslRepo,
    [string]$FlaUIPath = (Join-Path $env:LOCALAPPDATA 'Programs\FlaUI-MCP\FlaUI.Mcp.exe'),
    [string]$CodexConfigPath = (Join-Path $env:USERPROFILE '.codex\config.toml'),
    [string]$MachineConfigPath,
    [string]$BackupRoot,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\claude-user-config.ps1')
. (Join-Path $PSScriptRoot 'codex-run\45-profile-sync.ps1')
. (Join-Path $PSScriptRoot 'dispatch\common-runtime.ps1')
. (Join-Path $PSScriptRoot 'dispatch\git-baseline.ps1')
. (Join-Path $PSScriptRoot 'dispatch\dispatch-evidence.ps1')
. (Join-Path $PSScriptRoot 'lib\mcp-registration.ps1')

$targets = @()
if ($McpLab) { $targets += 'mcp-lab' }
if ($InfraLab) { $targets += 'infra-lab' }
if ($FlaUI) { $targets += 'flaui' }

if ($targets.Count -eq 0) {
    if (-not $Check) {
        Write-Host @'
用法：Register-McpServer.ps1 [-McpLab] [-InfraLab] [-FlaUI] [-Check] [-WhatIf]

  -McpLab      登記 mcp-lab 的 11 個伺服器到 Claude Code 使用者層
  -InfraLab    登記 infra-lab 到 Claude Code 使用者層（首次需要 -InfraLabDistro 與 -InfraLabWslRepo）
  -FlaUI       把 FlaUI.Mcp 的執行檔路徑寫入 Codex 桌面版設定檔與各派工帳號的設定檔（預設 %LOCALAPPDATA%\Programs\FlaUI-MCP\FlaUI.Mcp.exe，可用 -FlaUIPath 指定）
  -Check       唯讀檢查所選項目是否已登記；沒有指定項目時檢查全部三項
  -WhatIf      預演，不寫入任何東西

沒有指定任何項目，未做任何事。腳本只寫設定，不拉 repo、不下載、不安裝、不啟動服務；安裝方式見 README.md。
'@
        exit 1
    }
    $targets = @('mcp-lab', 'infra-lab', 'flaui')
}

if (($InfraLabDistro -or $InfraLabWslRepo) -and $targets -notcontains 'infra-lab') {
    Write-Error '-InfraLabDistro 與 -InfraLabWslRepo 只用於 infra-lab，請一併指定 -InfraLab。' -ErrorAction Continue
    exit 1
}
if ($PSBoundParameters.ContainsKey('FlaUIPath') -and $targets -notcontains 'flaui') {
    Write-Error '-FlaUIPath 只用於 FlaUI.Mcp，請一併指定 -FlaUI。' -ErrorAction Continue
    exit 1
}

$mcpTemplatePath = Join-Path $repoRoot 'templates\claude-mcp-servers.json'
$userMcpPath = Join-Path $env:USERPROFILE '.claude.json'
if ([string]::IsNullOrEmpty($BackupRoot)) { $BackupRoot = Join-Path $repoRoot '.local\ai-sessions\backups' }
if ([string]::IsNullOrEmpty($MachineConfigPath)) { $MachineConfigPath = Join-Path $repoRoot '.local\machine.json' }

# 路徑參數一律轉成絕對路徑：相對路徑以目前的工作目錄為基準（含 ~），避免把相對路徑寫進設定檔，
# 之後 Codex 桌面版以不同的工作目錄啟動時找不到執行檔。
function ConvertTo-AbsoluteParameterPath {
    param([string]$Name, [string]$Value)
    try { return [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value)) }
    catch {
        Write-Error ("-{0} 不是有效的路徑：{1}" -f $Name, $Value) -ErrorAction Continue
        exit 1
    }
}
$FlaUIPath = ConvertTo-AbsoluteParameterPath -Name 'FlaUIPath' -Value $FlaUIPath
$CodexConfigPath = ConvertTo-AbsoluteParameterPath -Name 'CodexConfigPath' -Value $CodexConfigPath
$MachineConfigPath = ConvertTo-AbsoluteParameterPath -Name 'MachineConfigPath' -Value $MachineConfigPath
$BackupRoot = ConvertTo-AbsoluteParameterPath -Name 'BackupRoot' -Value $BackupRoot

if ($Check) {
    $checkExitCode = Invoke-McpRegistrationCheck -Target $targets -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcpPath -CodexConfigPath $CodexConfigPath -FlaUIPath $FlaUIPath -InfraLabDistro $InfraLabDistro -InfraLabWslRepo $InfraLabWslRepo -MachineConfigPath $MachineConfigPath
    exit $checkExitCode
}

$registration = Invoke-McpRegistration -Target $targets -McpTemplatePath $mcpTemplatePath -UserMcpPath $userMcpPath -CodexConfigPath $CodexConfigPath -FlaUIPath $FlaUIPath `
    -BackupRoot $BackupRoot -InfraLabDistro $InfraLabDistro -InfraLabWslRepo $InfraLabWslRepo -MachineConfigPath $MachineConfigPath -WhatIf:$WhatIfPreference
if ($registration.Problems -gt 0) { exit 1 }
exit 0
