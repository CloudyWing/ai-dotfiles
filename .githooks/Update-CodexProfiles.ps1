#Requires -Version 7.0
<#
.SYNOPSIS
    由執行者登錄表產生 Codex 檔位設定檔（scripts\codex-profiles\<檔位>.config.toml）並暫存。
.DESCRIPTION
    pre-commit 以 pwsh 呼叫。讀 scripts\dispatch\executor-registry.json，寫出每個 Codex 執行者的檔位設定檔，
    移除輸出目錄內登錄表未列出的 *.config.toml，最後以 git add 暫存輸出目錄。內容未變時不改檔。
    加 -Check 時只比對，有差異就列出並以結束碼 1 結束，不寫檔、不暫存。
    登錄表無效或寫入失敗時輸出原因並以結束碼 1 結束，阻擋 commit。
.PARAMETER RepoRoot
    要處理的 repo 根目錄，預設為本腳本所在 repo。
.PARAMETER Check
    只比對，不寫入、不暫存。
.PARAMETER NoStage
    寫檔但不執行 git add，供測試使用。
.PARAMETER FromIndex
    以暫存區（index）內的登錄表內容產生，而不是工作樹的檔案。pre-commit 使用，使產生檔與這次 commit 內的登錄表一致；
    只暫存其他檔案、登錄表未暫存時，產生結果等於 HEAD 的登錄表，不會多出暫存變更。手動重產生不加此參數。
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,

    [switch]$Check,

    [switch]$NoStage,

    [switch]$FromIndex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

. (Join-Path $PSScriptRoot '..\scripts\codex-run\45-profile-sync.ps1')

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) }
    $registryPath = Get-CodexProfileRegistryPath -RepoRoot $RepoRoot
    if ($FromIndex) {
        $indexText = @(& git -C $RepoRoot show ':scripts/dispatch/executor-registry.json')
        if ($LASTEXITCODE -ne 0) { throw '暫存區內沒有 scripts/dispatch/executor-registry.json，無法依暫存內容產生檔位設定檔。' }
        $indexRegistryPath = Join-Path ([IO.Path]::GetTempPath()) ('registry-index-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($indexRegistryPath, ($indexText -join "`n"), (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
        $registryPath = $indexRegistryPath
    }
    $outputDirectory = Get-CodexProfileGeneratedDirectory -RepoRoot $RepoRoot
    $changes = @(Sync-CodexProfileGeneratedFile -RegistryPath $registryPath -OutputDirectory $outputDirectory -CheckOnly:$Check)
    foreach ($change in $changes) { Write-Host ('[codex-profiles] ' + $change.action + '：' + $change.path) }
    if ($Check) {
        if ($changes.Count -gt 0) {
            Write-Host ('[codex-profiles] 產生檔與登錄表不一致，請執行 pwsh -NoProfile -File .githooks\Update-CodexProfiles.ps1')
            exit 1
        }
        exit 0
    }
    if (-not $NoStage) {
        & git -C $RepoRoot add -A -- 'scripts/codex-profiles'
        if ($LASTEXITCODE -ne 0) { throw ('git add 失敗，結束碼：' + $LASTEXITCODE) }
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine('[codex-profiles] ' + $_.Exception.Message)
    exit 1
}
finally {
    if ($null -ne (Get-Variable -Name indexRegistryPath -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $indexRegistryPath)) { Remove-Item -LiteralPath $indexRegistryPath -Force }
}
