#Requires -Version 5.1

function New-DispatchInputFinding {
    [CmdletBinding()]
    param([string]$CheckId, [string]$Severity, [string]$Code, [string]$Field, [string]$Message, [string]$Expected, [string]$Received, [string]$Source, [Nullable[int]]$Line, [Nullable[int]]$OrderField)
    $finding = [ordered]@{ check_id = $CheckId; severity = $Severity; code = $Code; field = $Field; message = $Message; expected = $Expected; received = $Received; source = $Source }
    if ($PSBoundParameters.ContainsKey('Line')) { $finding.line = $Line }
    if ($PSBoundParameters.ContainsKey('OrderField')) { $finding.order_field = $OrderField }
    [pscustomobject]$finding
}

function Read-DispatchRequiredReadBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Order)
    $body = [string]$Order.TaskBody
    $start = 1
    if ($null -ne $Order.PSObject.Properties['TaskBodyStartLine']) { $start = [int]$Order.TaskBodyStartLine }
    $masked = [regex]::Replace($body, '(?s)<!--.*?(?:-->|\z)', { param($m) [regex]::Replace($m.Value, '[^\r\n]', ' ') })
    $rawLines = @($body -split '\r?\n')
    $lines = @($masked -split '\r?\n')
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $errors = New-Object 'System.Collections.Generic.List[object]'
    $outside = New-Object 'System.Collections.Generic.List[object]'
    $present = $false; $headingLine = 0; $headingRaw = ''; $active = $false; $hasEntry = $false; $fenced = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]; $raw = [string]$rawLines[$i]; $number = $start + $i
        if ($line -match '^\s*```') {
            if ($active -and -not $hasEntry) { $errors.Add([pscustomobject]@{ line = $number; raw = $raw; code = 'DispatchInputRequiredReadEmpty'; reason = '「必讀檔案：」之後沒有清單行，標題後須緊接清單行，沒有必讀檔案時請刪除整個區塊' }) }
            $active = $false; $fenced = -not $fenced; $outside.Add([pscustomobject]@{ line = $number; text = $line; raw = $raw }); continue
        }
        if ($fenced) { $outside.Add([pscustomobject]@{ line = $number; text = $line; raw = $raw }); continue }
        $standard = $line -cmatch '^必讀檔案：\s*$'
        $near = $line -match '^[\s#*\->`]*必讀檔案(?:[:：]|[\s*`]*$)'
        if ($standard -or $near) {
            if ($active -and -not $hasEntry) { $errors.Add([pscustomobject]@{ line = $number; raw = $raw; code = 'DispatchInputRequiredReadEmpty'; reason = '「必讀檔案：」之後沒有清單行，標題後須緊接清單行，沒有必讀檔案時請刪除整個區塊' }) }
            if ($standard -and -not $present) { $present = $true; $headingLine = $number; $headingRaw = $raw; $active = $true; $hasEntry = $false; continue }
            $active = $false
            $reason = if ($standard) { '「必讀檔案：」標題重複，一份派遣單只能有一個區塊，請合併' } else { '「必讀檔案」標題寫法不符，標題須單獨一行且恰為「必讀檔案：」（全形冒號，無前綴符號，同行不接內容）' }
            $errors.Add([pscustomobject]@{ line = $number; raw = $raw; code = 'DispatchInputRequiredReadHeadingInvalid'; reason = $reason })
            continue
        }
        if ($active) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line -match '^\s*(?:[-*+]|\d+\.)') {
                $hasEntry = $true; $code = ''; $reason = ''; $path = ''
                $quoted = [regex]::Match($line, '`([^`]*)`')
                if ($quoted.Success) { $path = $quoted.Groups[1].Value -replace ':\d+(?::\d+)?$', '' }
                else {
                    $salvage = [regex]::Match($line, '(?i)(?:[a-z]:[\\/]|\\\\[^\\/\s`]+[\\/][^\\/\s`]+)[^\s`、，；]*')
                    if ($salvage.Success) { $path = ($salvage.Value.TrimEnd('.', ',', '，', '。', '）', ')') -replace ':\d+(?::\d+)?$', '') }
                }
                $ticks = ([regex]::Matches($line, '`')).Count
                $paths = ([regex]::Matches($line, '(?i)(?:[a-z]:[\\/]|\\\\[^\\/\s`]+[\\/][^\\/\s`]+)')).Count
                if ($line -cnotmatch '^- ') { $code = 'DispatchInputRequiredReadLineInvalid'; $reason = '清單行須以「- 」（減號加一個空白）開頭，行首不得縮排' }
                elseif ($paths -ge 2 -or $ticks -ge 4) { $code = 'DispatchInputRequiredReadMultiplePaths'; $reason = '一行只能列一個路徑，偵測到 ' + [Math]::Max($paths, [int][Math]::Floor($ticks / 2)) + ' 個路徑，請拆成每行一個' }
                elseif ($ticks -eq 0) { $code = 'DispatchInputRequiredReadLineInvalid'; $reason = '清單行的路徑須以反引號包住' }
                elseif ($ticks % 2 -ne 0) { $code = 'DispatchInputRequiredReadLineInvalid'; $reason = '反引號未成對' }
                elseif ($line -cnotmatch '^- `[^`]*`\s*$') { $code = 'DispatchInputRequiredReadLineInvalid'; $reason = '反引號之外不得有其他文字，說明請另起一段，不要寫在清單行' }
                elseif ([string]::IsNullOrWhiteSpace($path)) { $code = 'DispatchInputRequiredReadLineInvalid'; $reason = '路徑為空白' }
                elseif ($quoted.Groups[1].Value -match ':\d+(?::\d+)?$') { $code = 'DispatchInputRequiredReadLineInvalid'; $reason = '必讀檔案不接行號後綴，請只列檔案路徑' }
                elseif ($path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { $code = 'DispatchInputRequiredReadNotAbsolute'; $reason = '路徑須為絕對路徑（磁碟機路徑 C:\... 或 UNC \\主機\共用），不接受相對路徑、環境變數與未替換的佔位符' }
                $state = if ($code -eq '') { 'ok' } else { 'invalid' }
                $entries.Add([pscustomobject]@{ line = $number; raw = $raw; path = $path; state = $state; code = $code; reason = $reason })
                continue
            }
            if (-not $hasEntry) { $errors.Add([pscustomobject]@{ line = $number; raw = $raw; code = 'DispatchInputRequiredReadEmpty'; reason = '「必讀檔案：」之後沒有清單行，標題後須緊接清單行，沒有必讀檔案時請刪除整個區塊' }) }
            $active = $false
        }
        $outside.Add([pscustomobject]@{ line = $number; text = $line; raw = $raw })
    }
    if ($active -and -not $hasEntry) { $errors.Add([pscustomobject]@{ line = $headingLine; raw = '（第 4 欄結束）'; code = 'DispatchInputRequiredReadEmpty'; reason = '「必讀檔案：」之後沒有清單行，標題後須緊接清單行，沒有必讀檔案時請刪除整個區塊' }) }
    [pscustomobject]@{ present = $present; heading_line = $headingLine; heading_raw = $headingRaw; entries = @($entries.ToArray()); block_errors = @($errors.ToArray()); outside_lines = @($outside.ToArray()) }
}

function Get-DispatchRequiredReadListedPath {
    [CmdletBinding()]
    param([object]$Block)
    $seen = @{}
    foreach ($entry in $Block.entries) {
        if (-not [string]::IsNullOrWhiteSpace($entry.path)) {
            try {
                $normalized = [IO.Path]::GetFullPath($entry.path).TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant()
                if (-not $seen.ContainsKey($normalized)) { $seen[$normalized] = $true; $normalized }
            } catch { }
        }
    }
}

function Get-DispatchRequiredReadExample {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -or $Path -match '[`\r\n*?]|:\d+(?::\d+)?$' -or ([regex]::Matches($Path, '(?i)(?:[a-z]:[\\/]|\\\\[^\\/\s`]+[\\/][^\\/\s`]+)')).Count -gt 1) { $Path = 'C:\絕對\路徑\檔案.md' }
    return "必讀檔案：`n- ``$Path``"
}

function New-DispatchRequiredReadFinding {
    [CmdletBinding()]
    param([string]$CheckId, [string]$Severity, [string]$Code, [string]$Reason, [object]$Order, [int]$Line, [string]$Raw, [string]$Path)
    if ($Raw.Length -gt 200) { $Raw = $Raw.Substring(0, 200) + '…' }
    $example = Get-DispatchRequiredReadExample -Path $Path
    $message = $Reason + '。派遣單：' + $Order.Path + '；第 4 欄（檔案第 ' + $Line + ' 行）；收到：「' + $Raw + '」；正確寫法（派遣單第 4 欄內）：' + "`n" + $example
    New-DispatchInputFinding -CheckId $CheckId -Severity $Severity -Code $Code -Field 'task_body.required_read' -Message $message -Expected $example -Received $Raw -Source ([string]$Order.Path) -Line $Line -OrderField 4
}

function Format-DispatchRequiredReadBlock {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][AllowEmptyCollection()][string[]]$Path)
    foreach ($item in $Path) {
        if ($item -match '[`\r\n]') { throw 'DispatchInputRequiredReadLineInvalid：路徑不得包含反引號或換行' }
    }
    $lines = @('必讀檔案：') + @($Path | ForEach-Object { '- `' + $_ + '`' })
    $text = $lines -join "`n"
    $block = Read-DispatchRequiredReadBlock -Order ([pscustomobject]@{ TaskBody = $text })
    $errors = @($block.block_errors) + @($block.entries | Where-Object { $_.state -ne 'ok' })
    if ($errors.Count -gt 0) { throw ($errors[0].code + '：' + $errors[0].reason) }
    return $text
}

function Get-DispatchOrderLocation {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug)
    $name = 'dispatch-order-' + $DispatchSlug + '.md'
    [pscustomobject]@{
        source = Join-Path $SourceRoot ('.local\ai-sessions\handoff\' + $LineSlug + '\' + $name)
        worktree = Join-Path $ExecutionRoot ('.local\ai-sessions\handoff\' + $LineSlug + '\' + $name)
        legacy_root_path = Join-Path $SourceRoot (Join-Path '.local\ai-sessions\handoff' $name)
    }
}

function Resolve-DispatchOrderLocation {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug, [ValidateSet('Source', 'Execution')][string]$Side)
    $root = if ($Side -eq 'Source') { $SourceRoot } else { $ExecutionRoot }
    $locations = Get-DispatchOrderLocation -SourceRoot $root -ExecutionRoot $root -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $path = [IO.Path]::GetFullPath($locations.source)
    $legacy = [IO.Path]::GetFullPath($locations.legacy_root_path)
    $state = 'missing'
    $code = 'DispatchInputOrderMissing'
    $message = '派遣單不存在：' + $path
    try {
        if (Test-Path -LiteralPath $legacy -PathType Leaf -ErrorAction Stop) {
            $state = 'legacy-root'
            $code = 'DispatchInputOrderLocationInvalid'
            $message = '派遣單位於根目錄：' + $legacy + '；請移至正確路徑並移除根目錄檔案：' + $path
        }
        elseif (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) {
            $state = 'ok'
            $code = ''
            $message = '派遣單位置：' + $path
        }
    }
    catch { $message += '；' + $_.Exception.Message }
    [pscustomobject]@{ side = $Side; path = $path; legacy_root_path = $legacy; state = $state; code = $code; message = $message }
}

function Get-DispatchOrderLocationFinding {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug, [ValidateSet('Source', 'Execution')][string]$Side)
    $result = Resolve-DispatchOrderLocation -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -Side $Side
    if ($result.state -ne 'ok') {
        $id = if ($Side -eq 'Source') { 'DI-ORDERLOC-A' } else { 'DI-ORDERLOC' }
        New-DispatchInputFinding -CheckId $id -Severity 'error' -Code $result.code -Field 'order' -Message $result.message -Expected $result.path -Received '' -Source $result.path
    }
}

function Test-DispatchOrderRequiresDesign {
    [CmdletBinding()]
    param([object]$Order, [string]$SourceRoot, [string]$LineSlug, [string]$DispatchSlug)
    if ($null -eq $Order) { return $false }
    $listed = @(Get-DispatchRequiredReadListedPath -Block (Read-DispatchRequiredReadBlock -Order $Order))
    foreach ($root in @($SourceRoot, (Join-Path $SourceRoot ('.local\ai-sessions\worktrees\' + $DispatchSlug)))) {
        $path = [IO.Path]::GetFullPath((Join-Path $root ('.local\ai-sessions\handoff\' + $LineSlug + '\design.md'))).TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant()
        if ($listed -contains $path) { return $true }
    }
    return $false
}

function Test-DispatchRequiredIdentifierResolvable {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$ConfiguredIdentifier, [string]$DispatchKind, [AllowEmptyString()][string]$TaskType, [AllowEmptyString()][string]$EvidencePackPath, [AllowEmptyCollection()][string[]]$TargetPath)
    try {
        $null = Get-DispatchRequiredIdentifier -ConfiguredIdentifier $ConfiguredIdentifier -DispatchKind $DispatchKind -TaskType $TaskType -EvidencePackPath $EvidencePackPath -TargetPath $TargetPath
        return $true
    }
    catch { return $false }
}

function Get-DispatchOutsideBlockPathHint {
    [CmdletBinding()]
    param([object]$Order, [object]$Block)
    $pathPattern = '(?i)(?<![a-z0-9_.\-\\/])(?:`(?<quoted>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^`\r\n]+)`|"(?<quoted>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^"\r\n]+)"|(?<bare>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^\s`"''<>|、（，；：\]]+))'
    $count = 0; $omitted = 0
    foreach ($item in $Block.outside_lines) {
        $paths = New-Object 'System.Collections.Generic.List[string]'
        foreach ($match in [regex]::Matches([string]$item.text, $pathPattern)) {
            $prefix = $item.text.Substring(0, $match.Index)
            $verbs = [regex]::Matches($prefix, '(?i)必讀|讀取|參考|依據|比對|審查|新增|建立|產生|輸出|寫入|\bread\b|\bcreate\b|\bwrite\b|\boutput\b')
            if ($verbs.Count -gt 0 -and $verbs[$verbs.Count - 1].Value -match '(?i)新增|建立|產生|輸出|寫入|create|write|output') { continue }
            $path = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['bare'].Value.TrimEnd('.', ',', '，', '。', '）', ')') }
            $path = $path -replace ':\d+(?::\d+)?$', ''
            $status = '不存在'
            try { if (Test-Path -LiteralPath $path -ErrorAction Stop) { $status = '存在' } } catch { $status = '無法檢查' }
            $paths.Add($path + '（' + $status + '）')
            if ($paths.Count -eq 1) { $examplePath = $path }
        }
        if ($paths.Count -eq 0) { continue }
        if ($count -ge 20) { if ($omitted -eq 0) { $firstOmitted = $item }; $omitted++; continue }
        $count++
        New-DispatchRequiredReadFinding -CheckId 'DI-REF-A' -Severity 'warning' -Code 'DispatchInputOutsideBlockPath' -Reason ('第 4 欄區塊外提到絕對路徑：' + ($paths -join '、') + '，不擋派遣；若需要執行端必讀，請列入「必讀檔案：」區塊') -Order $Order -Line $item.line -Raw $item.raw -Path $examplePath
    }
    if ($omitted -gt 0) {
        New-DispatchRequiredReadFinding -CheckId 'DI-REF-A' -Severity 'warning' -Code 'DispatchInputOutsideBlockPath' -Reason ('其餘 ' + $omitted + ' 行略') -Order $Order -Line $firstOmitted.line -Raw $firstOmitted.raw -Path ''
    }
}

function Get-DispatchReferenceFindings {
    [CmdletBinding()]
    param([object]$Order, [string]$Stage, [string]$DispatchRoot, [string]$SourceRoot, [string]$LineSlug, [string]$DispatchSlug)
    if ($null -eq $Order) { return }
    $block = Read-DispatchRequiredReadBlock -Order $Order
    if ($Stage -eq 'Request') {
        foreach ($item in @($block.block_errors) + @($block.entries | Where-Object { $_.state -eq 'invalid' })) {
            $path = if ($null -ne $item.PSObject.Properties['path'] -and $item.code -ne 'DispatchInputRequiredReadNotAbsolute') { $item.path } else { '' }
            New-DispatchRequiredReadFinding -CheckId 'DI-REQREAD' -Severity 'error' -Code $item.code -Reason $item.reason -Order $Order -Line $item.line -Raw $item.raw -Path $path
        }
        if (-not $block.present -and $block.block_errors.Count -eq 0) {
            $line = if ($null -ne $Order.PSObject.Properties['TaskBodyStartLine']) { $Order.TaskBodyStartLine } else { 1 }
            New-DispatchRequiredReadFinding -CheckId 'DI-REQREAD' -Severity 'warning' -Code 'DispatchInputRequiredReadAbsent' -Reason '派遣單第 4 欄沒有「必讀檔案：」區塊，本次放行（過渡規則）。若本派遣要求執行端讀取特定檔案，請以下列格式列出' -Order $Order -Line $line -Raw '（第 4 欄沒有「必讀檔案：」標題）' -Path ''
        }
        Get-DispatchOutsideBlockPathHint -Order $Order -Block $block
    }
    $designs = @()
    if ($SourceRoot -and $LineSlug -and $DispatchSlug) {
        foreach ($root in @($SourceRoot, (Join-Path $SourceRoot ('.local\ai-sessions\worktrees\' + $DispatchSlug)))) {
            $designs += [IO.Path]::GetFullPath((Join-Path $root ('.local\ai-sessions\handoff\' + $LineSlug + '\design.md'))).TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant()
        }
    }
    $seen = @{}
    foreach ($entry in $block.entries) {
        if ($entry.state -ne 'ok') { continue }
        $path = $entry.path
        $normalized = [IO.Path]::GetFullPath($path).TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant()
        if ($seen.ContainsKey($normalized) -or ($Stage -eq 'Request' -and $designs -contains $normalized)) { continue }
        $seen[$normalized] = $true
        $underDispatch = Test-PathWithinRoot -Path $path -Root $DispatchRoot
        if (($Stage -eq 'Request' -and $underDispatch) -or ($Stage -eq 'Worktree' -and -not $underDispatch)) { continue }
        $reason = ''
        try { if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) { $reason = '必讀檔案不存在，請確認路徑或先建立該檔後重送；非必讀的輸出路徑請移出區塊' } }
        catch { $reason = '無法檢查必讀檔案：' + $_.Exception.Message }
        if ($reason -ne '') {
            $id = if ($Stage -eq 'Worktree') { 'DI-REF-B' } else { 'DI-REF-A' }
            New-DispatchRequiredReadFinding -CheckId $id -Severity 'error' -Code 'DispatchInputReferenceMissing' -Reason $reason -Order $Order -Line $entry.line -Raw $entry.raw -Path $path
        }
    }
    if ($Stage -eq 'Request') {
        $pathPattern ='(?i)(?<![a-z0-9_.\-\\/])(?:`(?<quoted>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^`\r\n]+)`|"(?<quoted>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^"\r\n]+)"|(?<bare>(?:[a-z]:[\\/]|(?<!\[)\\\\)[^\s`"''<>|、（，；：\]]+))'
        $acceptance = [regex]::Match([string]$Order.Content, '(?ms)^##\s*5\..*?\r?\n(?<body>.*?)(?=^##\s*6\.|\z)')
        foreach ($match in [regex]::Matches($acceptance.Groups['body'].Value, $pathPattern)) {
            $path = if ($match.Groups['quoted'].Success) { $match.Groups['quoted'].Value } else { $match.Groups['bare'].Value.TrimEnd('.', ',', '，', '。', '）', ')') }
            $path = $path -replace ':\d+(?::\d+)?$', ''
            try { $exists = Test-Path -LiteralPath $path -ErrorAction Stop; $reason = '驗收命令引用路徑不存在：' + $path }
            catch { $exists = $false; $reason = '無法檢查驗收命令引用路徑：' + $path + '；' + $_.Exception.Message }
            if (-not $exists) { New-DispatchInputFinding -CheckId 'DI-REF-A' -Severity 'warning' -Code 'DispatchInputReferenceMissing' -Field 'acceptance' -Message $reason -Expected $path -Received '' -Source ([string]$Order.Path) }
        }
    }
}

function Test-DispatchDirectoryContainsCsharp {
    [CmdletBinding()]
    param([string]$Path)
    $pending = New-Object 'System.Collections.Generic.Stack[string]'
    $pending.Push($Path)
    $count = 0
    while ($pending.Count -gt 0) {
        $directoryPath = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop) {
            $count++
            if ($count -gt 10000) { throw 'DispatchInputDirectoryScanLimit：目錄掃描超過 10000 個項目。' }
            if ($item.PSIsContainer) {
                if ($item.Name -notin @('bin', 'obj', '.git', '.local', 'node_modules') -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($item.FullName) }
            }
            elseif ($item.Extension -in @('.cs', '.csx')) { return $true }
        }
    }
    return $false
}

function Invoke-DispatchInputChecks {
    [CmdletBinding()]
    param([ValidateSet('Request', 'Worktree')][string]$Stage, [Parameter(Mandatory)][object]$Context)
    $promptPath = [string](Get-DispatchJsonProperty -Object $Context -Name 'PromptPath')
    $contextValues = @{}
    $promptText = ''
    $promptExists = $false
    try {
        if (-not [string]::IsNullOrWhiteSpace($promptPath) -and (Test-Path -LiteralPath $promptPath -PathType Leaf -ErrorAction Stop)) {
            $promptText = Get-Content -LiteralPath $promptPath -Raw -Encoding UTF8 -ErrorAction Stop
            $promptExists = $true
        }
    }
    catch {
        $id = if ($Stage -eq 'Worktree') { 'DI-LINECTX-B' } else { 'DI-LINECTX-A' }
        $code = if ($Stage -eq 'Worktree') { 'DispatchInputLineContextMismatch' } else { 'DispatchInputLineContextMissing' }
        New-DispatchInputFinding -CheckId $id -Severity 'error' -Code $code -Field 'prompt_path' -Message ('無法讀取 prompt：' + $promptPath + '；' + $_.Exception.Message) -Expected $promptPath -Received '' -Source $promptPath
    }
    if ($promptExists) {
        foreach ($label in @('lineSlug', 'sourceLineRoot', 'dispatchLineRoot', 'reportLineRoot', 'sourceRoot', 'dispatchRoot')) {
            $match = [regex]::Match($promptText, '(?im)^\s*(?:-\s*)?' + $label + '\s*[:=]\s*[`"'']?(?<value>[^\r\n`"'']+)', [Text.RegularExpressions.RegexOptions]::None)
            if ($match.Success) { $contextValues[$label] = $match.Groups['value'].Value.Trim() }
        }
    }
    if ($Stage -eq 'Worktree') {
        $executionRoot = [string]$Context.ExecutionRoot
        $expected = @{
            dispatchRoot = $executionRoot
            dispatchLineRoot = Join-Path $executionRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug)
            reportLineRoot = Join-Path $executionRoot ('.local\ai-sessions\report\' + $Context.LineSlug)
        }
        foreach ($label in $expected.Keys) {
            if (-not $contextValues.ContainsKey($label) -or -not [string]::Equals($contextValues[$label], $expected[$label], [StringComparison]::OrdinalIgnoreCase)) {
                New-DispatchInputFinding -CheckId 'DI-LINECTX-B' -Severity 'error' -Code 'DispatchInputLineContextMismatch' -Field $label -Message ('LineContext 不符實際執行目錄：' + $label) -Expected $expected[$label] -Received ([string]$contextValues[$label]) -Source $promptPath
            }
        }
        if ($Context.DispatchKind -eq 'resource' -and $Context.TaskType -ne 'advisor-consult') {
            Get-DispatchOrderLocationFinding -SourceRoot $Context.SourceRoot -ExecutionRoot $executionRoot -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug -Side Execution
        }
        if (-not [string]::Equals($executionRoot, $Context.SourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Get-DispatchReferenceFindings -Order $Context.ResourceOrder -Stage $Stage -DispatchRoot $executionRoot -SourceRoot $Context.SourceRoot -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug
        }
        return
    }
    if ($Context.DispatchKind -eq 'resource' -and $Context.TaskType -ne 'advisor-consult') {
        Get-DispatchOrderLocationFinding -SourceRoot $Context.SourceRoot -ExecutionRoot $Context.SourceRoot -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug -Side Source
    }
    $sourceLineRoot = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug)
    if (-not $promptExists -or $promptText -notmatch '(?i)LineContext') {
        New-DispatchInputFinding -CheckId 'DI-LINECTX-A' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field 'LineContext' -Message ('prompt 缺少 LineContext 區塊：' + $promptPath) -Expected 'LineContext 區塊' -Received '' -Source $promptPath
    }
    $expectedSource = @{ lineSlug = [string]$Context.LineSlug; sourceRoot = [string]$Context.SourceRoot; sourceLineRoot = $sourceLineRoot }
    foreach ($label in @('lineSlug', 'sourceLineRoot', 'dispatchLineRoot', 'reportLineRoot', 'sourceRoot', 'dispatchRoot')) {
        if (-not $contextValues.ContainsKey($label) -or ($expectedSource.ContainsKey($label) -and -not [string]::Equals($contextValues[$label], $expectedSource[$label], [StringComparison]::OrdinalIgnoreCase))) {
            New-DispatchInputFinding -CheckId 'DI-LINECTX-A' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field $label -Message ('LineContext 欄位缺少或不符：' + $label) -Expected ([string]$expectedSource[$label]) -Received ([string]$contextValues[$label]) -Source $promptPath
        }
    }
    if ($contextValues.ContainsKey('dispatchRoot') -and $contextValues.ContainsKey('dispatchLineRoot') -and $contextValues.ContainsKey('reportLineRoot')) {
        $possibleRoot = Join-Path $Context.SourceRoot ('.local\ai-sessions\worktrees\' + $Context.DispatchSlug)
        $rootValue = $contextValues['dispatchRoot']
        $validRoot = [string]::Equals($rootValue, $Context.SourceRoot, [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($rootValue, $possibleRoot, [StringComparison]::OrdinalIgnoreCase)
        $validHandoff = [string]::Equals($contextValues['dispatchLineRoot'], (Join-Path $rootValue ('.local\ai-sessions\handoff\' + $Context.LineSlug)), [StringComparison]::OrdinalIgnoreCase)
        $validReport = [string]::Equals($contextValues['reportLineRoot'], (Join-Path $rootValue ('.local\ai-sessions\report\' + $Context.LineSlug)), [StringComparison]::OrdinalIgnoreCase)
        if (-not ($validRoot -and $validHandoff -and $validReport)) {
            New-DispatchInputFinding -CheckId 'DI-LINECTX-A' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field 'dispatchRoot' -Message 'LineContext 的執行根目錄與交接、報告目錄不一致。' -Expected '同一來源樹或派遣 worktree' -Received $rootValue -Source $promptPath
        }
    }
    $evidenceCheckPath = [string](Get-DispatchJsonProperty -Object $Context -Name 'EvidenceCheckPath')
    if ([string]::IsNullOrWhiteSpace($evidenceCheckPath)) { $evidenceCheckPath = [string]$Context.EvidencePackPath }
    if ($Context.TaskType -eq 'advisor-consult') {
        try {
            if ([string]::IsNullOrWhiteSpace($evidenceCheckPath) -or -not (Test-Path -LiteralPath $evidenceCheckPath -PathType Leaf -ErrorAction Stop)) { throw '找不到 evidence pack。' }
            $evidenceContent = Get-Content -LiteralPath $evidenceCheckPath -Raw -Encoding UTF8 -ErrorAction Stop
            $missingRules = @(Test-AdvisorEvidencePackContent -Content $evidenceContent -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug)
            foreach ($rule in $missingRules) {
                New-DispatchInputFinding -CheckId 'DI-EVID' -Severity 'error' -Code 'EvidencePackInvalid' -Field 'evidence_pack_path' -Message ('evidence pack 缺少必要內容；要求的完整內容：' + $rule.Display) -Expected $rule.Display -Received '' -Source $evidenceCheckPath
            }
        }
        catch {
            New-DispatchInputFinding -CheckId 'DI-EVID' -Severity 'error' -Code 'EvidencePackInvalid' -Field 'evidence_pack_path' -Message ('無法讀取 evidence pack：' + $evidenceCheckPath + '；' + $_.Exception.Message) -Expected $evidenceCheckPath -Received '' -Source $evidenceCheckPath
        }
    }
    $order = $Context.ResourceOrder
    $referenceRoot = Join-Path $Context.SourceRoot ('.local\ai-sessions\worktrees\' + $Context.DispatchSlug)
    $referenceFindings = @(Get-DispatchReferenceFindings -Order $order -Stage $Stage -DispatchRoot $referenceRoot -SourceRoot $Context.SourceRoot -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug)
    $reviewerUnlisted = $false
    if ($null -ne $order) {
        if ([string](Get-DispatchJsonProperty -Object $Context -Name 'WriteMode') -eq 'write' -and $order.Role -match '(?i)維護工程師|值班工程師|除錯工程師|Maintainer|debug|除錯' -and ($order.TaskBody + ' ' + $order.Boundary) -match '(?i)(不|禁止|不得|不可)\s*(派生|使用)\s*subagent') {
            New-DispatchInputFinding -CheckId 'DI-ROLE' -Severity 'error' -Code 'DispatchInputRoleConflict' -Field 'role' -Message 'Maintainer 與禁止派生 subagent 衝突，請改用 Support Engineer 或移除禁止字樣。' -Expected '相容的角色與邊界' -Received ([string]$order.Role) -Source ([string]$order.Path)
        }
        $summaryPath = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\requirement-summary.md')
        if ($order.Role -match '(?i)Reviewer|Frontend Reviewer|Contract Auditor|review|審查') {
            try {
                $block = Read-DispatchRequiredReadBlock -Order $order
                $listed = @(Get-DispatchRequiredReadListedPath -Block $block)
                $worktreeSummary = Join-Path $referenceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\requirement-summary.md')
                $expectedSummaries = @($summaryPath, $worktreeSummary) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant() }
                if ((Test-Path -LiteralPath $summaryPath -PathType Leaf -ErrorAction Stop) -and @($expectedSummaries | Where-Object { $listed -contains $_ }).Count -eq 0) {
                    $reviewerUnlisted = $true
                    $line = if ($block.present) { $block.heading_line } elseif ($null -ne $order.PSObject.Properties['TaskBodyStartLine']) { $order.TaskBodyStartLine } else { 1 }
                    $raw = if ($block.present) { $block.heading_raw } else { '（第 4 欄沒有「必讀檔案：」標題）' }
                    $status = if ($block.present) { '標題在檔案第 ' + $line + ' 行，已列 ' + $block.entries.Count + ' 項' } else { '沒有區塊' }
                    New-DispatchRequiredReadFinding -CheckId 'DI-REV4' -Severity 'error' -Code 'DispatchInputReviewerSummaryUnlisted' -Reason ('派遣單第 4 欄「必讀檔案」區塊未列出同線需求摘要：' + $summaryPath + '。區塊現況：' + $status) -Order $order -Line $line -Raw $raw -Path $summaryPath
                }
            }
            catch {
                $reviewerUnlisted = $true
                $line = if ($null -ne $order.PSObject.Properties['TaskBodyStartLine']) { $order.TaskBodyStartLine } else { 1 }
                $raw = @([string]$order.TaskBody -split '\r?\n')[0]
                New-DispatchRequiredReadFinding -CheckId 'DI-REV4' -Severity 'error' -Code 'DispatchInputReviewerSummaryUnlisted' -Reason ('無法檢查需求摘要：' + $summaryPath + '；' + $_.Exception.Message) -Order $order -Line $line -Raw $raw -Path $summaryPath
            }
        }
    }
    foreach ($finding in $referenceFindings) {
        if (-not ($reviewerUnlisted -and $finding.code -eq 'DispatchInputRequiredReadAbsent')) { $finding }
    }
    $hasCsharpTarget = $false
    $targetScanError = ''
    if ([string](Get-DispatchJsonProperty -Object $Context -Name 'WriteMode') -eq 'write') {
        foreach ($target in @($Context.TargetPath)) {
            if ([string]$target -match '(?i)\.csx?$') { $hasCsharpTarget = $true; break }
            try {
                if ((Test-Path -LiteralPath $target -PathType Container -ErrorAction Stop) -and (Test-DispatchDirectoryContainsCsharp -Path $target)) { $hasCsharpTarget = $true; break }
            }
            catch {
                $targetScanError = $_.Exception.Message
                if ($targetScanError.StartsWith('DispatchInputDirectoryScanLimit', [StringComparison]::Ordinal)) {
                    New-DispatchInputFinding -CheckId 'DI-STYLE' -Severity 'error' -Code 'DispatchInputDirectoryScanLimit' -Field 'target_path' -Message '目錄項目超過 10000 個，無法確認是否含 C# 檔；請將 target_path 縮小到實際要修改的子目錄或檔案。' -Expected '不超過 10000 個項目的目標目錄' -Received '' -Source ([string]$target)
                }
                else {
                    New-DispatchInputFinding -CheckId 'DI-STYLE' -Severity 'error' -Code 'DispatchInputProfileKeyMissing' -Field 'target_path' -Message ('無法檢查目標目錄：' + $target + '；' + $targetScanError) -Expected '可讀取的目標目錄' -Received '' -Source ([string]$target)
                }
            }
        }
    }
    if ($hasCsharpTarget) {
        $profilePath = Join-Path $Context.SourceRoot 'AGENTS.local.md'
        $style = ''
        $structureError = ''
        try {
            if (Test-Path -LiteralPath $profilePath -PathType Leaf -ErrorAction Stop) {
                $profile = [string](Get-Content -LiteralPath $profilePath -Raw -Encoding UTF8 -ErrorAction Stop)
                $begins = [regex]::Matches($profile, '(?m)^<!-- AI-PROFILE:BEGIN -->\r?$')
                $ends = [regex]::Matches($profile, '(?m)^<!-- AI-PROFILE:END -->\r?$')
                if ($begins.Count -ne $ends.Count -or $begins.Count -gt 1 -or ($begins.Count -eq 1 -and $begins[0].Index -ge $ends[0].Index) -or ([regex]::Matches($profile, 'AI-PROFILE:(BEGIN|END)').Count -ne ($begins.Count + $ends.Count))) { $structureError = 'AI-PROFILE 標記結構無效。' }
                elseif ($begins.Count -eq 1) {
                    $keys = @{}
                    $body = $profile.Substring($begins[0].Index + $begins[0].Length, $ends[0].Index - $begins[0].Index - $begins[0].Length)
                    foreach ($lineText in ($body -split '\r?\n')) {
                        if ([string]::IsNullOrWhiteSpace($lineText)) { continue }
                        if ($lineText -cnotmatch '^\s*([a-z0-9.-]+)\s*:\s*(\S.*?)\s*$' -or $keys.ContainsKey($Matches[1])) { $structureError = 'AI-PROFILE 鍵值格式無效或重複。'; break }
                        $keys[$Matches[1]] = $Matches[2]
                    }
                    if ($keys.ContainsKey('code-style.csharp')) { $style = $keys['code-style.csharp'] }
                }
            }
        }
        catch { $structureError = '無法讀取 AI-PROFILE：' + $_.Exception.Message }
        if ($structureError -ne '' -or $style -cnotin @('personal', 'standard', 'project')) {
            $code = if ($structureError -ne '') { 'AiProfileStructureInvalid' } else { 'DispatchInputProfileKeyMissing' }
            New-DispatchInputFinding -CheckId 'DI-STYLE' -Severity 'error' -Code $code -Field 'code-style.csharp' -Message ('AI-PROFILE 的 code-style.csharp 缺少或無效：' + $profilePath + ' ' + $structureError) -Expected 'personal、standard 或 project' -Received $style -Source $profilePath
        }
    }
    $linePath = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\line.json')
    try {
        $line = Get-Content -LiteralPath $linePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        $kind = [string](Get-DispatchJsonProperty -Object $line -Name 'kind')
        if ((Get-DispatchJsonProperty -Object $line -Name 'schema') -cne 'ai-sessions.line.v1' -or (Get-DispatchJsonProperty -Object $line -Name 'line-slug') -cne $Context.LineSlug -or ($kind -ne '' -and $kind -notin @('workflow', 'adhoc'))) { throw 'line.json 欄位不符。' }
    }
    catch {
        New-DispatchInputFinding -CheckId 'DI-LINEJSON' -Severity 'error' -Code 'DispatchInputLineContextMissing' -Field 'line.json' -Message ('line.json 缺少或無效：' + $linePath + '；' + $_.Exception.Message) -Expected $linePath -Received '' -Source $linePath
    }
    if (-not (Test-DispatchRequiredIdentifierResolvable -ConfiguredIdentifier ([string]$Context.RequiredIdentifier) -DispatchKind ([string]$Context.DispatchKind) -TaskType ([string]$Context.TaskType) -EvidencePackPath ([string]$Context.EvidencePackPath) -TargetPath @($Context.TargetPath))) {
        New-DispatchInputFinding -CheckId 'DI-IDENT' -Severity 'error' -Code 'DispatchRequestMissingField' -Field 'required_identifier' -Message '無法從 target_path 推導 required_identifier，請提供該欄位。' -Expected 'required_identifier 或具有檔名的 target_path' -Received '' -Source 'request'
    }
    if ($Context.DispatchKind -eq 'resource' -and $null -ne $Context.ResourceOrder -and (Test-DispatchOrderRequiresDesign -Order $Context.ResourceOrder -SourceRoot $Context.SourceRoot -LineSlug $Context.LineSlug -DispatchSlug $Context.DispatchSlug)) {
        $designPath = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\design.md')
        if (-not (Test-Path -LiteralPath $designPath -PathType Leaf)) {
            $block = Read-DispatchRequiredReadBlock -Order $Context.ResourceOrder
            $designCandidates = @($designPath, (Join-Path $referenceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\design.md'))) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/').Replace('/', '\').ToLowerInvariant() }
            $entry = @($block.entries | Where-Object { $candidate = @(Get-DispatchRequiredReadListedPath -Block ([pscustomobject]@{ entries = @($_) })); $candidate.Count -gt 0 -and $designCandidates -contains $candidate[0] })[0]
            New-DispatchRequiredReadFinding -CheckId 'DI-DESIGN' -Severity 'error' -Code 'DispatchInputDesignMissing' -Reason ('找不到派遣單要求的設計文件：' + $designPath) -Order $Context.ResourceOrder -Line $entry.line -Raw $entry.raw -Path $designPath
        }
    }
}

function Assert-DispatchInputFindings {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Findings, [string]$RequestPathValue)
    $errors = @($Findings | Where-Object { $_.severity -eq 'error' })
    if ($errors.Count -gt 0) {
        $detail = [ordered]@{ findings = @($Findings) }
        if (@($errors | Where-Object { $_.check_id -eq 'DI-STYLE' -and $_.field -eq 'code-style.csharp' -and $_.code -eq 'DispatchInputProfileKeyMissing' }).Count -gt 0) { $detail.missing_keys = @('code-style.csharp') }
        Throw-DispatchRequestFailure -Code $errors[0].code -Message (($errors | ForEach-Object { $_.message }) -join '；') -RequestPathValue $RequestPathValue -Field $errors[0].field -Detail $detail
    }
}
