#Requires -Version 7.0
# 派工新入口的通用函式與常數。由 scripts\Invoke-CodexRun.ps1 依檔名排序 dot-source，不單獨執行。

function New-RunError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateRange(1, 255)]
        [int]$ExitCode = 1,

        [AllowNull()]
        [object[]]$Details = @()
    )

    # 帶 Code、ExitCode、Details 的例外。以 throw (New-RunError ...) 使用，呼叫端從 Exception.Data 取值。
    $exception = New-Object System.InvalidOperationException -ArgumentList @($Code + '：' + $Message)
    $exception.Data['Code'] = $Code
    $exception.Data['ExitCode'] = $ExitCode
    $exception.Data['Details'] = @($Details)
    return $exception
}

function ConvertTo-AsciiJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [ValidateRange(1, 100)]
        [int]$Depth = 10,

        [switch]$Compress
    )

    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress:$Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($match) '\u' + ([int][char]$match.Value).ToString('x4') })
}

function Write-RunJsonAtomic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [ValidateRange(1, 100)]
        [int]$Depth = 10
    )

    # UTF-8 無 BOM，先寫同目錄暫存檔再取代目標，讀取端不會看到寫到一半的檔案。
    $directory = Split-Path -Parent $Path
    if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth
    $temp = Join-Path $directory ('.run-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $json + "`n", (New-Object System.Text.UTF8Encoding -ArgumentList @($false)))
        [IO.File]::Move($temp, $Path, $true)
    }
    finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Get-RunSha256File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $stream = New-Object System.IO.FileStream -ArgumentList @($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
    }
}

function Get-RunSha256Text {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetBytes($Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function New-RunId {
    [CmdletBinding()]
    param()

    $random = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(3)).ToLowerInvariant()
    return [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff', [Globalization.CultureInfo]::InvariantCulture) + 'Z-' + $random
}

function Test-RunPathUnder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    # 路徑等於根目錄或在根目錄之下時為 true，不分大小寫，不依賴結尾分隔字元。
    $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd($separators)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd($separators)
    if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Test-RunPathCmdSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    # 參數經 codex.cmd 轉手時會被 cmd.exe 解讀的字元，以及權限設定以 TOML literal 鍵（單引號）表達路徑時無法表達的單引號。
    return -not [regex]::IsMatch($Path, '[&|<>^%"'']')
}

function Get-RunDenyPattern {
    [CmdletBinding()]
    param()

    # 檔名樣式。權限設定的 deny 鍵與來源雜湊、啟動前檢查共用同一份。
    return [string[]]@('.env', '.env.*', '*.pem', '*.key', 'secrets.*')
}

function Test-RunDenyPatternName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrEmpty($Name)) { return $false }
    foreach ($pattern in (Get-RunDenyPattern)) {
        if ($Name -like $pattern) { return $true }
    }
    return $false
}

function Get-RunJsonProperty {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object -or $Object -isnot [pscustomobject]) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}
