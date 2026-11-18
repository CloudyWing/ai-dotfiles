#Requires -Version 7.0
# 成本帳追加。格式為 cost-ledger.v2（14 欄）。依賴 00-common.ps1。

function Add-RunLedgerLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LedgerPath,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string[]]$Row
    )

    # 沿用 cost-ledger.v2：建檔、標記行與表頭、跳脫、獨佔鎖與重試（最多 10 次、間隔 100 毫秒）、同 runId 已存在時略過。
    if ($Row.Count -ne 14) { throw ('成本事件列必須有 14 欄，實際為 ' + $Row.Count + ' 欄。') }
    $marker = '<!-- cost-ledger.v2 -->'
    $cells = New-Object 'System.Collections.Generic.List[string]'
    foreach ($cell in $Row) {
        $cellText = if ($null -eq $cell) { '' } else { [string]$cell }
        $cells.Add(($cellText.Replace('|', '\|') -replace '\r\n|\r|\n', ' '))
    }
    $rowText = '| ' + ($cells -join ' | ') + ' |'
    $headerLines = @(
        $marker,
        '| 時間（UTC） | 列類型 | 成本目標 | dispatchSlug | runId | cycle_id | cycle_round | cycle_role | 事件類型 | 耗時（秒） | input | cached_input | output | 備註 |',
        '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |'
    )
    $ledgerDirectory = Split-Path -Parent $LedgerPath
    if (-not [IO.Directory]::Exists($ledgerDirectory)) { $null = [IO.Directory]::CreateDirectory($ledgerDirectory) }

    $stream = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $stream = New-Object System.IO.FileStream -ArgumentList @($LedgerPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            break
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 10) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
    try {
        $existingBytes = New-Object byte[] ([int]$stream.Length)
        $readCount = 0
        while ($readCount -lt $existingBytes.Length) {
            $chunk = $stream.Read($existingBytes, $readCount, $existingBytes.Length - $readCount)
            if ($chunk -le 0) { break }
            $readCount += $chunk
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
        $existingText = $utf8NoBom.GetString($existingBytes, 0, $readCount)
        if ($existingText.Length -gt 0 -and $existingText[0] -eq [char]0xFEFF) { $existingText = $existingText.Substring(1) }
        foreach ($existingLine in ($existingText -split '\r?\n')) {
            if ($existingLine.Contains('| ' + $RunId + ' |') -and $existingLine.Contains('| 事件 |')) { return 'skipped-existing' }
        }
        $newLine = if ($existingText.Contains("`r`n") -or $existingText.Length -eq 0) { "`r`n" } else { "`n" }
        $appendText = ''
        if ($existingText.Trim().Length -eq 0) {
            $appendText = '# ' + (Split-Path -Leaf $ledgerDirectory) + ' 成本紀錄' + $newLine + $newLine + ($headerLines -join $newLine) + $newLine + $rowText + $newLine
        }
        else {
            if (-not $existingText.EndsWith("`n")) { $appendText = $newLine }
            if ($existingText.Contains($marker)) { $appendText += $rowText + $newLine }
            else { $appendText += $newLine + ($headerLines -join $newLine) + $newLine + $rowText + $newLine }
        }
        $appendBytes = $utf8NoBom.GetBytes($appendText)
        $null = $stream.Seek(0, [IO.SeekOrigin]::End)
        $stream.Write($appendBytes, 0, $appendBytes.Length)
        $stream.Flush()
    }
    finally {
        $stream.Dispose()
    }
    return 'recorded'
}

function Add-RunCostRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LedgerPath,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$RunId,

        [AllowNull()]
        [object]$Cycle,

        [Parameter(Mandatory)]
        [double]$DurationSeconds,

        [AllowNull()]
        [object]$Usage,

        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [string]$Result,

        [Parameter(Mandatory)]
        [string]$TaskType,

        [Parameter(Mandatory)]
        [string]$AccountName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RejectionKind,

        [DateTime]$EndedUtc = [DateTime]::UtcNow
    )

    # 每次嘗試結束時追加一列（含被服務端拒絕、沒有用量的嘗試）。帳號與拒絕種類放在備註欄，不增減欄位。
    $cycleCells = @('-', '-', '-')
    if ($null -ne $Cycle) { $cycleCells = @([string]$Cycle.id, [string]$Cycle.round, [string]$Cycle.role) }
    $usageStatus = if ($null -ne $Usage) { [string]$Usage.status } else { 'no-terminal-event' }
    $inputCell = '-'
    $cachedCell = '-'
    $outputCell = '-'
    if ($null -ne $Usage -and $usageStatus -ceq 'recorded') {
        # 個別欄位為 $null（上游缺少該欄）時填 -。
        $inputCell = if ($null -eq $Usage.input_tokens) { '-' } else { [string][long]$Usage.input_tokens }
        $cachedCell = if ($null -eq $Usage.cached_input_tokens) { '-' } else { [string][long]$Usage.cached_input_tokens }
        $outputCell = if ($null -eq $Usage.output_tokens) { '-' } else { [string][long]$Usage.output_tokens }
    }
    $rejection = if ([string]::IsNullOrWhiteSpace($RejectionKind)) { 'none' } else { $RejectionKind }
    $note = 'exit={0};result={1};task={2};account={3};rejection={4};usage={5}' -f $ExitCode, $Result, $TaskType, $AccountName, $rejection, $usageStatus
    $row = @(
        $EndedUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture),
        '事件',
        $LineSlug,
        $DispatchSlug,
        $RunId,
        [string]$cycleCells[0],
        [string]$cycleCells[1],
        [string]$cycleCells[2],
        '首次',
        [string][int64][Math]::Floor($DurationSeconds),
        $inputCell,
        $cachedCell,
        $outputCell,
        $note
    )
    return Add-RunLedgerLine -LedgerPath $LedgerPath -RunId $RunId -Row $row
}
