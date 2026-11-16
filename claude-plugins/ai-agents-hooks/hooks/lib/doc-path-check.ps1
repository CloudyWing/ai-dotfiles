#Requires -Version 7.0
# 本機路徑偵測函式庫，供 .githooks/Test-StagedDocPath.ps1 使用。外掛的 hooks/core/doc-path.ts 以 TypeScript 實作同一套規則，
# 兩份實作由 scripts/tests/Test-DocLocalPathCheck.ps1 以同一組輸入比對。
# 純函式：不讀寫檔案、不呼叫 git。
Set-StrictMode -Version Latest

# 路徑 token 的終止字元：空白、反引號、單雙引號與全形標點（，。；：、（）「」）。
# 空白以明確列舉寫出（即 .NET 的 \s：U+0009 至 U+000D、U+0085 與 Unicode Z 類），與 hooks/core/doc-path.ts 的列舉字面相同。
$script:LocalPathWhiteSpace = '\t\n\v\f\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000'
$script:LocalPathTerminators = $script:LocalPathWhiteSpace + '`''"，。；：、（）「」'

# 起點：字母加冒號，後接一個以上的分隔符與至少一個路徑片段字元。字母前不得是英數字（排除 https://）。
$script:LocalPathTokenPattern = [regex]::new(
    '(?<![A-Za-z0-9])[A-Za-z]:[\\/]+[^\\/' + $script:LocalPathTerminators + '][^' + $script:LocalPathTerminators + ']*',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

# 豁免：磁碟機、分隔符、可選的 Users 片段，其後直接接佔位符。
$script:LocalPathPlaceholderPattern = [regex]::new(
    '^[A-Za-z]:[\\/]+(?:Users[\\/]+)?(?:<[^<>]+>|\{[^{}]+\}|%[^%]+%|\$)',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)

function Find-LocalPathViolation {
    <#
    .SYNOPSIS
        回傳文字中含本機磁碟機絕對路徑的違規 token，無違規時不輸出。呼叫端以 @() 包覆即得陣列，無違規為空陣列。
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $violations = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    foreach ($match in $script:LocalPathTokenPattern.Matches($Text)) {
        $token = $match.Value
        if ($script:LocalPathPlaceholderPattern.IsMatch($token)) {
            continue
        }
        # 句尾的 ASCII 標點不屬於路徑，不在回報的 token 中保留。
        $trimmed = $token.TrimEnd('.', ',', ';', ':', '!', '?', ')', ']', '}')
        # 修剪後只剩磁碟機根目錄（如句尾括號內的 C:\）不是路徑，不回報。
        if ($trimmed.Length -gt 0 -and $trimmed -notmatch '^[A-Za-z]:[\\/]*$') {
            $violations.Add($trimmed)
        }
    }

    return $violations.ToArray()
}

function Test-LocalPathExcludedFile {
    <#
    .SYNOPSIS
        路徑任一片段為 .local，或檔名符合 *.local.md 時回傳 $true。不分大小寫，接受 \ 與 /。
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path
    )

    if ([string]::IsNullOrEmpty($Path)) {
        return $false
    }

    $segments = @($Path -split '[\\/]' | Where-Object { $_ -ne '' })
    foreach ($segment in $segments) {
        if ($segment -ieq '.local') {
            return $true
        }
    }

    if ($segments.Count -gt 0 -and $segments[-1] -like '*.local.md') {
        return $true
    }

    return $false
}
