#Requires -Version 7.0

function Get-DispatchMachineConfigPath {
    [CmdletBinding()]
    param()
    return Join-Path (Split-Path -Parent $script:DispatchEntryScriptRoot) '.local\machine.json'
}

function Read-CodexAccountConfiguration {
    [CmdletBinding()]
    param([string]$MachineConfigPath)

    if ([string]::IsNullOrWhiteSpace($MachineConfigPath)) {
        $MachineConfigPath = Get-DispatchMachineConfigPath
    }
    if (-not [IO.File]::Exists($MachineConfigPath)) { return @() }
    try {
        $machine = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($MachineConfigPath, [Text.Encoding]::UTF8))
        $accountsProperty = $machine.PSObject.Properties['codex_accounts']
        if ($null -eq $accountsProperty) { return @() }
        if ([string]$machine.schema -cne 'ai-agents.machine.v1' -or $accountsProperty.Value -isnot [array]) { throw 'codex_accounts 必須是 ai-agents.machine.v1 的陣列。' }
        $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $homes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $accountsProperty.Value) {
            if ($null -eq $entry -or $entry -isnot [pscustomobject] -or @($entry.PSObject.Properties).Count -ne 2 -or
                $null -eq $entry.PSObject.Properties['name'] -or $null -eq $entry.PSObject.Properties['codex_home'] -or
                $entry.name -isnot [string] -or $entry.name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or $entry.codex_home -isnot [string] -or
                -not [IO.Path]::IsPathRooted($entry.codex_home)) { throw '帳號項目須只有合法名稱與絕對 codex_home。' }
            $homePath = Normalize-DispatchRootPath -Path $entry.codex_home
            if (-not [IO.Directory]::Exists($homePath)) { throw ('帳號目錄不存在：' + $entry.name + '; ' + $homePath) }
            Assert-DispatchOutputPathNoReparsePoint -Root ([IO.Path]::GetPathRoot($homePath)) -Path $homePath
            $homeItem = Get-Item -LiteralPath $homePath -Force -ErrorAction Stop
            $canonicalHome = Normalize-DispatchRootPath -Path $homeItem.FullName
            if (-not $names.Add($entry.name) -or -not $homes.Add($canonicalHome)) { throw ('帳號名稱或目錄重複：' + $entry.name + '; ' + $homePath) }
            [pscustomobject]@{ name = $entry.name; codex_home = $canonicalHome }
        }
    }
    catch { throw ('CodexAccountConfigurationInvalid：' + $_.Exception.Message) }
}
