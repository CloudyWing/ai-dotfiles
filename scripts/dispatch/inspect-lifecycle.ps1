function Get-EventPropertyValue {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-DispatchSecretPatternNames {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)

    $patterns = New-Object 'System.Collections.Generic.List[string]'
    if ([regex]::IsMatch($Text, '(?im)-----BEGIN[^\r\n]*PRIVATE KEY-----')) {
        $patterns.Add('pem-private-key-header')
    }
    if ([regex]::IsMatch($Text, '(?i)\b(?:Password|Pwd)\s*=\s*(?:"[^"]+"|''[^'']+''|[^;,\s}]+)')) {
        $patterns.Add('connection-string-password')
    }
    if ([regex]::IsMatch($Text, '(?i)\bAKIA[A-Z0-9]{16}\b')) {
        $patterns.Add('aws-access-key-id')
    }
    if ([regex]::IsMatch($Text, '(?i)\bsk-[A-Z0-9_-]{17,}\b')) {
        $patterns.Add('sk-token')
    }
    foreach ($line in ($Text -split '\r\n|\n|\r')) {
        $assignment = [regex]::Match($line, '^\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*?)\s*$')
        if ($assignment.Success -and $assignment.Groups['value'].Value.Length -gt 0 -and $assignment.Groups['key'].Value -match '(?i)(SECRET|PASSWORD|TOKEN|API_KEY)') {
            $patterns.Add('env-secret-assignment')
            break
        }
    }
    return @($patterns.ToArray() | Select-Object -Unique)
}

function Test-DispatchSecretJsonPropertyName {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Name)

    $normalizedName = ($Name -replace '[-_.\s]', '').ToLowerInvariant()
    foreach ($secretTerm in @('secret', 'password', 'passwd', 'credential', 'connectionstring', 'privatekey', 'apikey')) {
        if ($normalizedName.IndexOf($secretTerm, [System.StringComparison]::Ordinal) -ge 0) {
            return $true
        }
    }
    return $normalizedName.EndsWith('token', [System.StringComparison]::Ordinal) -or
        $normalizedName.EndsWith('pwd', [System.StringComparison]::Ordinal)
}

function Add-DispatchSecretExposurePattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Findings,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$FindingKeys,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][int]$LineNumber,
        [Parameter(Mandatory)][string]$Pattern
    )

    $key = $FilePath + "`n" + $LineNumber.ToString([Globalization.CultureInfo]::InvariantCulture) + "`n" + $Pattern
    if ($FindingKeys.Add($key)) { $Findings.Add([ordered]@{ file = $FilePath; line = $LineNumber; pattern = $Pattern }) }
}

function Add-DispatchSecretExposureText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Findings,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$FindingKeys,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][int]$LineNumber,
        [AllowEmptyString()][string]$Text
    )
    foreach ($pattern in @(Get-DispatchSecretPatternNames -Text $Text)) {
        Add-DispatchSecretExposurePattern -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $LineNumber -Pattern $pattern
    }
}

function New-DispatchInspectJsonPropertyLineLookup {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$StartLineNumber
    )

    $lookup = [ordered]@{ lines = @{}; indexes = @{} }
    $propertyMatches = [regex]::Matches($Text, '"(?<name>(?:\\.|[^"\\])*)"\s*:')
    foreach ($match in $propertyMatches) {
        $precedingBackslashCount = 0
        for ($index = $match.Index - 1; $index -ge 0 -and $Text[$index] -eq '\'; $index--) {
            $precedingBackslashCount++
        }
        if (($precedingBackslashCount % 2) -eq 1) { continue }

        $name = [string](ConvertFrom-Json -InputObject ('"' + $match.Groups['name'].Value + '"') -ErrorAction Stop)
        if (-not $lookup.lines.ContainsKey($name)) {
            $lookup.lines[$name] = New-Object 'System.Collections.Generic.List[int]'
        }
        $prefix = $Text.Substring(0, $match.Index)
        $lineOffset = [regex]::Matches($prefix, '\r\n|\n|\r').Count
        $lookup.lines[$name].Add($StartLineNumber + $lineOffset)
    }
    return $lookup
}

function Get-DispatchInspectJsonPropertyLineNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Lookup,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$FallbackLineNumber
    )

    if (-not $Lookup.lines.ContainsKey($Name)) { return $FallbackLineNumber }
    $index = if ($Lookup.indexes.ContainsKey($Name)) { [int]$Lookup.indexes[$Name] } else { 0 }
    $lineNumbers = $Lookup.lines[$Name]
    if ($index -ge $lineNumbers.Count) { return $FallbackLineNumber }
    $Lookup.indexes[$Name] = $index + 1
    return [int]$lineNumbers[$index]
}

function Add-DispatchSecretExposureFromValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Findings,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.HashSet[string]]$FindingKeys,
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][int]$LineNumber,
        [AllowNull()][System.Collections.IDictionary]$PropertyLineLookup
    )
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        Add-DispatchSecretExposureText -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $LineNumber -Text $Value
        $trimmedValue = $Value.Trim()
        if (($trimmedValue.StartsWith('{', [StringComparison]::Ordinal) -and $trimmedValue.EndsWith('}', [StringComparison]::Ordinal)) -or
            ($trimmedValue.StartsWith('[', [StringComparison]::Ordinal) -and $trimmedValue.EndsWith(']', [StringComparison]::Ordinal))) {
            $parsedValue = $null
            $parsedSuccessfully = $false
            try {
                $parsedValue = ConvertFrom-Json -InputObject $trimmedValue -ErrorAction Stop
                $parsedSuccessfully = $true
            }
            catch {
            }
            if ($parsedSuccessfully) {
                Add-DispatchSecretExposureFromValue -Value $parsedValue -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $LineNumber -PropertyLineLookup $null
            }
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($entry in $Value.GetEnumerator()) {
            $propertyLineNumber = $LineNumber
            if ($null -ne $PropertyLineLookup) {
                $propertyLineNumber = Get-DispatchInspectJsonPropertyLineNumber -Lookup $PropertyLineLookup -Name ([string]$entry.Key) -FallbackLineNumber $LineNumber
            }
            if (Test-DispatchSecretJsonPropertyName -Name ([string]$entry.Key)) {
                Add-DispatchSecretExposurePattern -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $propertyLineNumber -Pattern 'json-secret-property'
            }
            Add-DispatchSecretExposureFromValue -Value $entry.Value -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $propertyLineNumber -PropertyLineLookup $PropertyLineLookup
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        foreach ($entry in $Value) {
            Add-DispatchSecretExposureFromValue -Value $entry -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $LineNumber -PropertyLineLookup $PropertyLineLookup
        }
        return
    }
    if ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $propertyLineNumber = $LineNumber
            if ($null -ne $PropertyLineLookup) {
                $propertyLineNumber = Get-DispatchInspectJsonPropertyLineNumber -Lookup $PropertyLineLookup -Name $property.Name -FallbackLineNumber $LineNumber
            }
            if (Test-DispatchSecretJsonPropertyName -Name $property.Name) {
                Add-DispatchSecretExposurePattern -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $propertyLineNumber -Pattern 'json-secret-property'
            }
            Add-DispatchSecretExposureFromValue -Value $property.Value -Findings $Findings -FindingKeys $FindingKeys -FilePath $FilePath -LineNumber $propertyLineNumber -PropertyLineLookup $PropertyLineLookup
        }
    }
}

function Get-DispatchInspectSecretExposureCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventStreamPath,
        [AllowEmptyString()][string]$LastMessagePath
    )
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $findingKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if (Test-Path -LiteralPath $EventStreamPath -PathType Leaf) {
        $lineNumber = 0
        foreach ($line in ((Read-DispatchUtf8Text -Path $EventStreamPath) -split '\r?\n')) {
            $lineNumber++
            $script:DispatchInspectScanContext.file = $EventStreamPath
            $script:DispatchInspectScanContext.line = $lineNumber
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            Add-DispatchSecretExposureText -Findings $findings -FindingKeys $findingKeys -FilePath $EventStreamPath -LineNumber $lineNumber -Text $line
            $event = $null
            $eventParsed = $false
            try {
                $event = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                $eventParsed = $true
            }
            catch {
            }
            if ($eventParsed) {
                Add-DispatchSecretExposureFromValue -Value $event -Findings $findings -FindingKeys $findingKeys -FilePath $EventStreamPath -LineNumber $lineNumber
            }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($LastMessagePath) -and (Test-Path -LiteralPath $LastMessagePath -PathType Leaf)) {
        $lineNumber = 0
        $script:DispatchInspectScanContext.file = $LastMessagePath
        $script:DispatchInspectScanContext.line = 0
        $lastMessage = Read-DispatchUtf8Text -Path $LastMessagePath
        foreach ($line in ($lastMessage -split '\r?\n')) {
            $lineNumber++
            $script:DispatchInspectScanContext.file = $LastMessagePath
            $script:DispatchInspectScanContext.line = $lineNumber
            Add-DispatchSecretExposureText -Findings $findings -FindingKeys $findingKeys -FilePath $LastMessagePath -LineNumber $lineNumber -Text $line
            $parsedValue = $null
            $parsedSuccessfully = $false
            try {
                $parsedValue = ConvertFrom-Json -InputObject $line -ErrorAction Stop
                $parsedSuccessfully = $true
            }
            catch {
            }
            if ($parsedSuccessfully) {
                Add-DispatchSecretExposureFromValue -Value $parsedValue -Findings $findings -FindingKeys $findingKeys -FilePath $LastMessagePath -LineNumber $lineNumber
            }
        }
        $trimmedLastMessage = $lastMessage.Trim()
        if (($trimmedLastMessage.StartsWith('{', [StringComparison]::Ordinal) -and $trimmedLastMessage.EndsWith('}', [StringComparison]::Ordinal)) -or
            ($trimmedLastMessage.StartsWith('[', [StringComparison]::Ordinal) -and $trimmedLastMessage.EndsWith(']', [StringComparison]::Ordinal))) {
            $script:DispatchInspectScanContext.file = $LastMessagePath
            $script:DispatchInspectScanContext.line = 1
            $parsedLastMessage = $null
            $lastMessageParsed = $false
            try {
                $parsedLastMessage = ConvertFrom-Json -InputObject $trimmedLastMessage -ErrorAction Stop
                $lastMessageParsed = $true
            }
            catch {
            }
            if ($lastMessageParsed) {
                $propertyLineLookup = New-DispatchInspectJsonPropertyLineLookup -Text $lastMessage -StartLineNumber 1
                Add-DispatchSecretExposureFromValue -Value $parsedLastMessage -Findings $findings -FindingKeys $findingKeys -FilePath $LastMessagePath -LineNumber 1 -PropertyLineLookup $propertyLineLookup
            }
        }
    }
    return [ordered]@{ secret_exposure_suspected = $findings.Count -gt 0; secret_exposure_findings = @($findings.ToArray()) }
}

function Throw-DispatchInspectSanitizedFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('InspectJsonParseFailed', 'InspectSecretScanFailed', 'InspectRedactionFailed', 'InspectEventStreamEmpty', 'InspectEventStreamMissing', 'InspectMissingThreadId', 'InspectInvalidThreadId', 'InspectInvalidAgentMessage', 'InspectInvalidErrorMessage', 'InspectThreadIdMismatch', 'InspectMissingAgentMessage', 'InspectMissingUsage', 'InspectInvalidTurnFailedMessage', 'InspectLastMessageUnavailable')][string]$Code,
        [Parameter(Mandatory)][AllowEmptyString()][string]$FilePath,
        [Parameter(Mandatory)][int]$LineNumber
    )

    $message = '{0}: file={1}; line={2}' -f $Code, $FilePath, $LineNumber
    $failure = [ordered]@{ errorCode = $Code; file = $FilePath; line = $LineNumber }
    $exception = New-Object System.InvalidOperationException($message)
    $exception.Data['operationResult'] = $failure
    throw $exception
}

function Get-DispatchInspectSecretExposure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EventStreamPath,
        [AllowEmptyString()][string]$LastMessagePath
    )

    $script:DispatchInspectScanContext = [ordered]@{ file = $EventStreamPath; line = 0 }
    try {
        return Get-DispatchInspectSecretExposureCore -EventStreamPath $EventStreamPath -LastMessagePath $LastMessagePath
    }
    catch {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectSecretScanFailed' -FilePath ([string]$script:DispatchInspectScanContext.file) -LineNumber ([int]$script:DispatchInspectScanContext.line)
    }
    finally {
        $script:DispatchInspectScanContext = $null
    }
}

function Get-DispatchInspectMalformedJsonLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EventStreamPath)

    $lineNumber = 0
    try {
        if (-not (Test-Path -LiteralPath $EventStreamPath)) { return 0 }
        foreach ($line in ((Read-DispatchUtf8Text -Path $EventStreamPath) -split '\r?\n')) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $null = ConvertFrom-Json -InputObject $line -ErrorAction Stop
            }
            catch {
                return $lineNumber
            }
        }
    }
    catch {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectSecretScanFailed' -FilePath $EventStreamPath -LineNumber $lineNumber
    }
    return 0
}

function Protect-DispatchInspectText {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text)
    $trimmedText = $Text.Trim()
    if (($trimmedText.StartsWith('{', [StringComparison]::Ordinal) -and $trimmedText.EndsWith('}', [StringComparison]::Ordinal)) -or
        ($trimmedText.StartsWith('[', [StringComparison]::Ordinal) -and $trimmedText.EndsWith(']', [StringComparison]::Ordinal))) {
        $structuredValue = $null
        $parsedSuccessfully = $false
        try {
            $structuredValue = ConvertFrom-Json -InputObject $trimmedText -ErrorAction Stop
            $parsedSuccessfully = $true
        }
        catch {
        }
        if ($parsedSuccessfully) {
            $protectedValue = Protect-DispatchInspectOutputValue -Value $structuredValue -RedactEventLines $false -StructuredSecretRedaction $true
            return ConvertTo-Json -InputObject $protectedValue -Depth 100 -Compress
        }
    }
    $protected = [regex]::Replace($Text, '(?is)-----BEGIN[^\r\n]*PRIVATE KEY-----.*?(?:-----END[^\r\n]*PRIVATE KEY-----|$)', '[REDACTED: possible PEM private key]')
    $protected = [regex]::Replace($protected, '(?i)(?<prefix>\b(?:Password|Pwd)\s*=\s*)(?:"[^"]*"|''[^'']*''|[^;,\s}]+)', '${prefix}[REDACTED]')
    $protected = [regex]::Replace($protected, '(?i)\bAKIA[A-Z0-9]{16}\b', '[REDACTED: possible AWS access key]')
    $protected = [regex]::Replace($protected, '(?i)\bsk-[A-Z0-9_-]{17,}\b', '[REDACTED: possible token]')
    $parts = [regex]::Split($protected, '(\r\n|\n|\r)')
    for ($index = 0; $index -lt $parts.Length; $index += 2) {
        $assignment = [regex]::Match($parts[$index], '^(?<prefix>\s*(?<key>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*)(?<value>.*)$')
        if ($assignment.Success -and $assignment.Groups['value'].Value.Trim().Length -gt 0 -and $assignment.Groups['key'].Value -match '(?i)(SECRET|PASSWORD|TOKEN|API_KEY)') {
            $parts[$index] = $assignment.Groups['prefix'].Value + '[REDACTED]'
        }
    }
    return [string]::Concat($parts)
}

function Protect-DispatchInspectOutputValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value, [bool]$RedactEventLines, [bool]$StructuredSecretRedaction = $false)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return Protect-DispatchInspectText -Text $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in $Value.Keys) {
            if (Test-DispatchSecretJsonPropertyName -Name ([string]$key)) {
                $copy[$key] = '***'
            }
            elseif ($RedactEventLines -and -not $StructuredSecretRedaction -and [string]$key -in @('raw_lines', 'raw_event_lines', 'event_tail', 'raw_line')) {
                $copy[$key] = if ($Value[$key] -is [array] -or $Value[$key] -is [System.Collections.IList]) { @('[REDACTED: possible secret exposure]') } else { '[REDACTED: possible secret exposure]' }
            }
            else { $copy[$key] = Protect-DispatchInspectOutputValue -Value $Value[$key] -RedactEventLines $RedactEventLines -StructuredSecretRedaction $StructuredSecretRedaction }
        }
        return $copy
    }
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((Protect-DispatchInspectOutputValue -Value $item -RedactEventLines $RedactEventLines -StructuredSecretRedaction $StructuredSecretRedaction)) }
        return ,@($items.ToArray())
    }
    if ($Value -is [pscustomobject]) {
        $copy = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if (Test-DispatchSecretJsonPropertyName -Name $property.Name) {
                $copy[$property.Name] = '***'
            }
            else {
                $copy[$property.Name] = Protect-DispatchInspectOutputValue -Value $property.Value -RedactEventLines $RedactEventLines -StructuredSecretRedaction $StructuredSecretRedaction
            }
        }
        return [pscustomobject]$copy
    }
    return $Value
}

function Protect-DispatchInspectResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)][System.Collections.IDictionary]$SecretExposure
    )
    $sourcePath = if ($Result.Contains('eventStreamPath')) { [string]$Result.eventStreamPath } else { '' }
    $lineNumber = 0
    $findings = @($SecretExposure.secret_exposure_findings)
    if ([string]::IsNullOrWhiteSpace($sourcePath) -and $findings.Count -gt 0) { $sourcePath = [string]$findings[0].file }
    if ($findings.Count -gt 0) { $lineNumber = [int]$findings[0].line }
    if ([string]::IsNullOrWhiteSpace($sourcePath)) { $sourcePath = '<unknown>' }
    try {
        $hasStructuredSecret = @($findings | Where-Object { [string]$_.pattern -eq 'json-secret-property' }).Count -gt 0
        $protected = Protect-DispatchInspectOutputValue -Value $Result -RedactEventLines ([bool]$SecretExposure.secret_exposure_suspected) -StructuredSecretRedaction $hasStructuredSecret
        $protected.secret_exposure_suspected = [bool]$SecretExposure.secret_exposure_suspected
        $protected.secret_exposure_findings = $findings
        return $protected
    }
    catch {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectRedactionFailed' -FilePath $sourcePath -LineNumber $lineNumber
    }
}

function Test-UsageObject {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or -not ($Value -is [pscustomobject])) {
        return $false
    }

    $requiredNames = @('input_tokens', 'output_tokens')
    foreach ($requiredName in $requiredNames) {
        $property = $Value.PSObject.Properties[$requiredName]
        if ($null -eq $property) {
            return $false
        }
    }

    $numericTypes = @(
        [System.Byte], [System.SByte], [System.Int16], [System.UInt16], [System.Int32], [System.UInt32], [System.Int64], [System.UInt64],
        [single], [double], [decimal]
    )
    foreach ($property in @($Value.PSObject.Properties)) {
        if ($null -eq $property.Value -or $property.Value -is [bool] -or $property.Value.GetType() -notin $numericTypes -or [double]$property.Value -lt 0) {
            return $false
        }
    }

    return @($Value.PSObject.Properties).Count -gt 0
}

function ConvertTo-ComparableDispatchMessage {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Message)

    $normalized = $Message.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($normalized.Length -gt 0 -and $normalized[0] -eq [char]0xFEFF) {
        $normalized = $normalized.Substring(1)
    }
    return $normalized.TrimEnd([char[]]@([char]10))
}

function ConvertTo-DispatchInt32Value {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Field
    )

    $numericTypes = @(
        [System.Byte], [System.SByte], [System.Int16], [System.UInt16], [System.Int32], [System.UInt32], [System.Int64], [System.UInt64],
        [single], [double], [decimal]
    )
    if ($null -eq $Value -or $Value -is [bool] -or $Value.GetType() -notin $numericTypes) {
        throw ('{0} 必須是 Int32 整數。' -f $Field)
    }

    try {
        $decimalValue = [decimal]$Value
    }
    catch {
        throw ('{0} 必須是 Int32 整數。' -f $Field)
    }
    if ($decimalValue -ne [decimal]::Truncate($decimalValue) -or $decimalValue -lt [decimal][int]::MinValue -or $decimalValue -gt [decimal][int]::MaxValue) {
        throw ('{0} 必須是 Int32 整數。' -f $Field)
    }

    return [int]$decimalValue
}

function Set-DispatchJsonPropertyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    if ($Object -is [System.Collections.IDictionary]) {
        $Object[$Name] = $Value
        return
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

function Throw-DispatchInspectBindingFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message,

        [AllowEmptyString()]
        [string]$DispatchResultPath,

        [AllowNull()]
        [object]$Detail
    )

    $detailValue = if ($null -eq $Detail) { [ordered]@{} } else { $Detail }
    $result = [ordered]@{
        operation = 'Inspect'
        status = 'failed'
        success = $false
        outputValid = $false
        errorCode = $Code
        error = $Message
        dispatchResultPath = if ([string]::IsNullOrWhiteSpace($DispatchResultPath)) { $null } else { $DispatchResultPath }
        processExitCode = $null
        processExitCodeSource = 'sidecar-unavailable'
        dispatchBinding = $detailValue
    }
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['errorCode'] = $Code
    $exception.Data['operationResult'] = $result
    throw $exception
}

function Read-DispatchExitSidecar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    $pathValue = Resolve-AbsolutePath -Path $Path
    $historyRoot = Join-Path (Resolve-AbsolutePath -Path $ExecutionRoot) '.local\ai-sessions\history'
    if (-not (Test-PathWithinRoot -Path $pathValue -Root $historyRoot)) {
        throw "Dispatch exit sidecar 必須位於 execution history：$pathValue"
    }
    if ([IO.Path]::GetFileName($pathValue) -notmatch '^codex-exit-.+\.json$') {
        throw "Dispatch exit sidecar 檔名不符 per-run contract：$pathValue"
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $pathValue))) {
        throw "Dispatch exit sidecar 不存在：$pathValue"
    }

    $bytesBefore = Read-DispatchSharedBytes -Path $pathValue
    if ($bytesBefore.Length -ge 3 -and $bytesBefore[0] -eq 239 -and $bytesBefore[1] -eq 187 -and $bytesBefore[2] -eq 191) {
        throw "Dispatch exit sidecar 必須是 UTF-8 無 BOM：$pathValue"
    }
    $hashBefore = Get-DispatchByteArraySha256 -Bytes $bytesBefore
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList @($false, $true)
        $content = $encoding.GetString($bytesBefore)
        $document = ConvertFrom-DispatchJson -Content $content
    }
    catch {
        throw "Dispatch exit sidecar JSON 無法解析：$pathValue；$($_.Exception.Message)"
    }
    $bytesAfter = Read-DispatchSharedBytes -Path $pathValue
    $hashAfter = Get-DispatchByteArraySha256 -Bytes $bytesAfter
    if (-not [string]::Equals($hashBefore, $hashAfter, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Dispatch exit sidecar 在讀取期間變更：$pathValue"
    }
    if ($null -eq $document -or $document -isnot [psobject] -or $document -is [string] -or $document -is [ValueType]) {
        throw "Dispatch exit sidecar 根節點必須是 JSON object：$pathValue"
    }
    foreach ($name in @('schema', 'line_slug', 'dispatch_slug', 'run_id', 'process_exit_code', 'exit_code_status')) {
        if ($null -eq $document.PSObject.Properties[$name]) {
            throw "Dispatch exit sidecar 缺少欄位：$name"
        }
    }
    if ([string]$document.schema -cne 'ai-sessions.dispatch-exit.v1') {
        throw 'Dispatch exit sidecar schema 不符。'
    }
    if ([string]$document.line_slug -cne $LineSlug -or [string]$document.dispatch_slug -cne $DispatchSlug) {
        throw 'Dispatch exit sidecar line／dispatch 不一致。'
    }
    $parsedRunId = [guid]::Empty
    if ([string]$document.run_id -cne $RunId -or -not [guid]::TryParseExact([string]$document.run_id, 'D', [ref]$parsedRunId)) {
        throw 'Dispatch exit sidecar run_id 不一致或格式錯誤。'
    }
    if ([string]$document.exit_code_status -cne 'known') {
        throw 'Dispatch exit sidecar exit_code_status 必須是 known。'
    }
    $processExitCode = ConvertTo-DispatchInt32Value -Value $document.process_exit_code -Field 'process_exit_code'
    return [pscustomobject]@{
        Path = $pathValue
        Sha256 = $hashBefore
        ProcessExitCode = $processExitCode
        Document = $document
    }
}

function Wait-DispatchPollInterval {
    [CmdletBinding()]
    param()

    [System.Threading.Thread]::Sleep(1000)
}

function Wait-DispatchExitAndTerminalEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [Parameter(Mandatory)]
        [ValidateSet('readonly', 'write')]
        [string]$WriteMode,

        [Parameter(Mandatory)]
        [string]$RunRecordPath,

        [Parameter(Mandatory)]
        [string]$EventStreamPath,

        [Parameter(Mandatory)]
        [string]$SidecarPath
    )

    $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $runRecord = Read-DispatchRunRecord -Path $RunRecordPath -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    $sidecarPathValue = Resolve-AbsolutePath -Path $SidecarPath

    while ($true) {
        $sidecar = $null
        $sidecarFailure = $null
        try {
            $sidecar = Read-DispatchExitSidecar -Path $sidecarPathValue -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$runRecord.run_id)
        }
        catch {
            $sidecarFailure = $_.Exception.Message
            $pendingStatus = -not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $sidecarPathValue))
            if (-not $pendingStatus) {
                try {
                    $sidecarDocument = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $sidecarPathValue)
                    $pendingStatus = [string](Get-DispatchJsonProperty -Object $sidecarDocument -Name 'schema') -ceq 'ai-sessions.dispatch-exit.v1' -and
                        [string](Get-DispatchJsonProperty -Object $sidecarDocument -Name 'line_slug') -ceq $LineSlug -and
                        [string](Get-DispatchJsonProperty -Object $sidecarDocument -Name 'dispatch_slug') -ceq $DispatchSlug -and
                        [string](Get-DispatchJsonProperty -Object $sidecarDocument -Name 'run_id') -ceq [string]$runRecord.run_id -and
                        [string](Get-DispatchJsonProperty -Object $sidecarDocument -Name 'exit_code_status') -ceq 'pending'
                }
                catch {
                    $pendingStatus = $false
                }
            }
            if (-not $pendingStatus) {
                throw ('Dispatch exit sidecar 無效，無法等待：' + $sidecarFailure)
            }
        }

        if ($null -ne $sidecar) {
            $eventEvidence = Get-DispatchEventEvidence -EventPath $EventStreamPath
            $lastEventType = [string](Get-DispatchJsonProperty -Object $eventEvidence -Name 'last_event_type')
            return [pscustomobject]@{
                Sidecar = $sidecar
                EventEvidence = $eventEvidence
                LastEventType = $lastEventType
                TerminalEventAvailable = $lastEventType -in @('turn.completed', 'turn.failed')
            }
        }

        $processCheck = Get-PidCheckResult -SourceRoot $sourceRootPath -LineSlug $LineSlug -WriteMode $WriteMode
        $activeForDispatch = @($processCheck.ActiveRecords | Where-Object { [string]$_.DispatchSlug -ceq $DispatchSlug })
        $unconfirmedForDispatch = @($processCheck.UnconfirmedRecords | Where-Object { [string]$_.DispatchSlug -ceq $DispatchSlug })
        if ($unconfirmedForDispatch.Count -gt 0) {
            throw ('Codex process 身分無法確認，不能判定派遣終止：' + [string]$unconfirmedForDispatch[0].StatusMessage)
        }
        if ($activeForDispatch.Count -eq 0) {
            try {
                $sidecar = Read-DispatchExitSidecar -Path $sidecarPathValue -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$runRecord.run_id)
            }
            catch {
                throw ('Codex process 已結束，但 exit sidecar 尚未記錄完成；' + $_.Exception.Message)
            }
            $eventEvidence = Get-DispatchEventEvidence -EventPath $EventStreamPath
            $lastEventType = [string](Get-DispatchJsonProperty -Object $eventEvidence -Name 'last_event_type')
            return [pscustomobject]@{
                Sidecar = $sidecar
                EventEvidence = $eventEvidence
                LastEventType = $lastEventType
                TerminalEventAvailable = $lastEventType -in @('turn.completed', 'turn.failed')
            }
        }

        Wait-DispatchPollInterval
    }
}

function Resolve-DispatchInspectBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DispatchResultPathValue,

        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$ExecutionRoot,

        [Parameter(Mandatory)]
        [string]$LineSlug,

        [Parameter(Mandatory)]
        [string]$DispatchSlug,

        [string[]]$TargetPath = @(),

        [switch]$AllowPendingExitSidecar
    )

    try {
        $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
        $executionRootPath = Resolve-AbsolutePath -Path $ExecutionRoot
        $resultPath = Resolve-AbsolutePath -Path $DispatchResultPathValue
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result path 或 root 無法解析：' + $_.Exception.Message) -DispatchResultPath $DispatchResultPathValue
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $resultPath))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('找不到 Dispatch result：' + $resultPath) -DispatchResultPath $resultPath
    }
    $historyRoots = @(
        (Join-Path $sourceRootPath '.local\ai-sessions\history'),
        (Join-Path $executionRootPath '.local\ai-sessions\history')
    )
    if (-not (@($historyRoots | Where-Object { Test-PathWithinRoot -Path $resultPath -Root $_ }).Count -gt 0)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result 必須位於 source 或 execution history：' + $resultPath) -DispatchResultPath $resultPath
    }
    try {
        $resultFileSha256AtRead = Get-FileSha256 -Path $resultPath
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('DispatchResultBindingInvalid: Dispatch result 雜湊無法讀取：' + $resultPath) -DispatchResultPath $resultPath
    }

    try {
        $document = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $resultPath)
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('DispatchResultBindingInvalid: Dispatch result JSON 無法解析：' + $resultPath) -DispatchResultPath $resultPath
    }
    if ($null -eq $document -or $document -isnot [psobject] -or $document -is [string] -or $document -is [ValueType]) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 根節點必須是 JSON object。' -DispatchResultPath $resultPath
    }
    $resultHash = [string](Get-DispatchJsonProperty -Object $document -Name 'result_sha256')
    if ($resultHash -notmatch '^[a-fA-F0-9]{64}$') {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 缺少有效 result_sha256。' -DispatchResultPath $resultPath
    }
    try {
        $computedResultHash = Get-PrepareDocumentFingerprint -Document $document
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('DispatchResultBindingInvalid: Dispatch result 雜湊無法計算：' + $resultPath) -DispatchResultPath $resultPath
    }
    if (-not [string]::Equals($resultHash, $computedResultHash, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result result_sha256 不一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ expected = $computedResultHash; received = $resultHash })
    }
    if ([string](Get-DispatchJsonProperty -Object $document -Name 'schema') -cne 'ai-sessions.dispatch-result.v1' -or
        [string](Get-DispatchJsonProperty -Object $document -Name 'operation') -cne 'Dispatch' -or
        [string](Get-DispatchJsonProperty -Object $document -Name 'line_slug') -cne $LineSlug -or
        [string](Get-DispatchJsonProperty -Object $document -Name 'dispatch_slug') -cne $DispatchSlug) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result schema／operation／line／dispatch 不一致。' -DispatchResultPath $resultPath
    }
    if ((Get-DispatchJsonProperty -Object $document -Name 'process_started') -isnot [bool] -or -not [bool](Get-DispatchJsonProperty -Object $document -Name 'process_started')) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 必須是 process_started=true 的結果。' -DispatchResultPath $resultPath
    }
    $binding = Get-DispatchJsonProperty -Object $document -Name 'inspect_binding'
    if ($null -eq $binding -or $binding -isnot [psobject] -or $binding -is [string] -or $binding -is [ValueType]) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 缺少 inspect_binding object。' -DispatchResultPath $resultPath
    }

    $bindingPaths = [ordered]@{}
    foreach ($name in @('run_record_path', 'event_stream_path', 'scope_plan_path', 'quota_before_path', 'process_exit_code_sidecar_path')) {
        $value = Get-DispatchJsonProperty -Object $binding -Name $name
        if ($null -eq $value -or $value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('inspect_binding 缺少有效路徑：' + $name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $name })
        }
        try {
            $resolvedValue = Resolve-AbsolutePath -Path ([string]$value)
        }
        catch {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('inspect_binding 路徑無法解析：' + $name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $name; error = $_.Exception.Message })
        }
        if (-not [string]::Equals($resolvedValue, [string]$value, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('inspect_binding 路徑未正規化：' + $name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $name; value = $value })
        }
        $bindingPaths[$name] = $resolvedValue
    }
    $quotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $binding -Name 'quota_before_sha256')
    if ($quotaBeforeSha256 -notmatch '^[a-fA-F0-9]{64}$') {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding 缺少有效 quota_before_sha256。' -DispatchResultPath $resultPath
    }
    $resultQuotaBeforePath = [string](Get-DispatchJsonProperty -Object $document -Name 'quota_before_path')
    $resultQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $document -Name 'quota_before_sha256')
    if ([string]::IsNullOrWhiteSpace($resultQuotaBeforePath) -or
        -not [string]::Equals((Resolve-AbsolutePath -Path $resultQuotaBeforePath), $bindingPaths.quota_before_path, [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($resultQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 與 inspect_binding quota before path／SHA-256 不一致。' -DispatchResultPath $resultPath
    }
    $evidencePosition = Get-DispatchJsonProperty -Object $document -Name 'evidence_position'
    if ($null -ne $evidencePosition) {
        $evidenceQuotaBeforePath = [string](Get-DispatchJsonProperty -Object $evidencePosition -Name 'quota_before_path')
        $evidenceQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $evidencePosition -Name 'quota_before_sha256')
        if ([string]::IsNullOrWhiteSpace($evidenceQuotaBeforePath) -or
            -not [string]::Equals((Resolve-AbsolutePath -Path $evidenceQuotaBeforePath), $bindingPaths.quota_before_path, [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($evidenceQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch evidence quota before path／SHA-256 不一致。' -DispatchResultPath $resultPath
        }
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.run_record_path -Root (Join-Path $sourceRootPath '.local\ai-sessions\history'))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding RunRecord 超出 source history。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.event_stream_path -Root (Join-Path $executionRootPath '.local\ai-sessions\history'))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding event stream 超出 execution history。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.scope_plan_path -Root $executionRootPath)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding ScopePlan 超出 execution root。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.process_exit_code_sidecar_path -Root (Join-Path $executionRootPath '.local\ai-sessions\history'))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding exit sidecar 超出 execution history。' -DispatchResultPath $resultPath
    }
    if (-not (Test-PathWithinRoot -Path $bindingPaths.quota_before_path -Root $sourceRootPath) -and -not (Test-PathWithinRoot -Path $bindingPaths.quota_before_path -Root $executionRootPath)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'inspect_binding quota before 超出 source／execution root。' -DispatchResultPath $resultPath
    }

    try {
        $record = Read-DispatchRunRecord -Path $bindingPaths.run_record_path -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('DispatchResultBindingInvalid: Dispatch result RunRecord binding 無效：' + $resultPath) -DispatchResultPath $resultPath -Detail ([ordered]@{ run_record_path = $bindingPaths.run_record_path })
    }
    $recordComparisons = @(
        [pscustomobject]@{ Name = 'event_stream_path'; Expected = $record.event_stream_path; Actual = $bindingPaths.event_stream_path }
        [pscustomobject]@{ Name = 'scope_plan_path'; Expected = $record.scope_plan_path; Actual = $bindingPaths.scope_plan_path }
        [pscustomobject]@{ Name = 'process_exit_code_sidecar_path'; Expected = $record.process_exit_code_sidecar_path; Actual = $bindingPaths.process_exit_code_sidecar_path }
        [pscustomobject]@{ Name = 'quota_before_path'; Expected = $record.quota_before_path; Actual = $bindingPaths.quota_before_path }
    )
    foreach ($comparison in $recordComparisons) {
        if ([string]::IsNullOrWhiteSpace([string]$comparison.Expected) -or -not [string]::Equals((Resolve-AbsolutePath -Path ([string]$comparison.Expected)), $comparison.Actual, [StringComparison]::OrdinalIgnoreCase)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('Dispatch result 與 RunRecord binding 不一致：' + $comparison.Name) -DispatchResultPath $resultPath -Detail ([ordered]@{ field = $comparison.Name; run_record = $comparison.Expected; dispatch_result = $comparison.Actual })
        }
    }
    $recordQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $record -Name 'quota_before_sha256')
    if ($recordQuotaBeforeSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        -not [string]::Equals($recordQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'Dispatch result 與 RunRecord quota before SHA-256 binding 不一致。' -DispatchResultPath $resultPath
    }
    try {
        $actualQuotaBeforeSha256 = Get-FileSha256 -Path $bindingPaths.quota_before_path
    }
    catch {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ('quota before snapshot 雜湊無法讀取：' + $_.Exception.Message) -DispatchResultPath $resultPath
    }
    if (-not [string]::Equals($actualQuotaBeforeSha256, $quotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message 'quota before snapshot SHA-256 與 Dispatch／RunRecord binding 不一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ expected = $quotaBeforeSha256; actual = $actualQuotaBeforeSha256 })
    }

    $sidecar = $null
    $sidecarPending = $false
    try {
        $sidecar = Read-DispatchExitSidecar -Path $bindingPaths.process_exit_code_sidecar_path -ExecutionRoot $executionRootPath -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$record.run_id)
    }
    catch {
        if ($AllowPendingExitSidecar) {
            $sidecarError = $_.Exception.Message
            $pendingDocument = $null
            $sidecarPending = -not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $bindingPaths.process_exit_code_sidecar_path))
            if (-not $sidecarPending) {
                try {
                    $pendingDocument = ConvertFrom-DispatchJson -Content (Read-DispatchUtf8Text -Path $bindingPaths.process_exit_code_sidecar_path)
                    $sidecarPending = [string](Get-DispatchJsonProperty -Object $pendingDocument -Name 'schema') -ceq 'ai-sessions.dispatch-exit.v1' -and
                        [string](Get-DispatchJsonProperty -Object $pendingDocument -Name 'line_slug') -ceq $LineSlug -and
                        [string](Get-DispatchJsonProperty -Object $pendingDocument -Name 'dispatch_slug') -ceq $DispatchSlug -and
                        [string](Get-DispatchJsonProperty -Object $pendingDocument -Name 'run_id') -ceq [string]$record.run_id -and
                        [string](Get-DispatchJsonProperty -Object $pendingDocument -Name 'exit_code_status') -ceq 'pending'
                }
                catch {
                    $sidecarPending = $false
                }
            }
            if (-not $sidecarPending) {
                Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeUnavailable' -Message ('Dispatch exit sidecar 無法取得：' + $sidecarError) -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar_path = $bindingPaths.process_exit_code_sidecar_path; run_id = $record.run_id })
            }
            $sidecar = [pscustomobject]@{
                Path = $bindingPaths.process_exit_code_sidecar_path
                Sha256 = if ([System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $bindingPaths.process_exit_code_sidecar_path))) { Get-FileSha256 -Path $bindingPaths.process_exit_code_sidecar_path } else { $null }
                ProcessExitCode = $null
                Document = $pendingDocument
            }
        }
        else {
            Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeUnavailable' -Message ('Dispatch exit sidecar 無法取得：' + $_.Exception.Message) -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar_path = $bindingPaths.process_exit_code_sidecar_path; run_id = $record.run_id })
        }
    }

    $bindingProcessExitCode = $null
    $bindingProcessExitProperty = $binding.PSObject.Properties['process_exit_code']
    if ($null -ne $bindingProcessExitProperty -and $null -ne $bindingProcessExitProperty.Value) {
        try {
            $bindingProcessExitCode = ConvertTo-DispatchInt32Value -Value $bindingProcessExitProperty.Value -Field 'inspect_binding.process_exit_code'
        }
        catch {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message $_.Exception.Message -DispatchResultPath $resultPath
        }
    }
    $explicitProcessExitCode = $null
    if (Test-DispatchInvocationParameterBound -Name 'ProcessExitCode') {
        $explicitValue = Get-DispatchInvocationParameterValue -Name 'ProcessExitCode'
        if ($null -eq $explicitValue) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeMismatch' -Message '命令列顯式 ProcessExitCode 為 null，無法與 sidecar 一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar = $sidecar.ProcessExitCode; explicit = $null })
        }
        try {
            $explicitProcessExitCode = ConvertTo-DispatchInt32Value -Value $explicitValue -Field 'ProcessExitCode'
        }
        catch {
            Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeMismatch' -Message $_.Exception.Message -DispatchResultPath $resultPath
        }
    }
    if (($sidecarPending -and ($null -ne $bindingProcessExitCode -or $null -ne $explicitProcessExitCode)) -or
        (-not $sidecarPending -and (($null -ne $bindingProcessExitCode -and $bindingProcessExitCode -ne $sidecar.ProcessExitCode) -or ($null -ne $explicitProcessExitCode -and $explicitProcessExitCode -ne $sidecar.ProcessExitCode)))) {
        Throw-DispatchInspectBindingFailure -Code 'DispatchExitCodeMismatch' -Message 'Dispatch exit sidecar 與既有 ProcessExitCode 不一致。' -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar = $sidecar.ProcessExitCode; result_binding = $bindingProcessExitCode; explicit = $explicitProcessExitCode })
    }

    if (-not $sidecarPending) {
        try {
            Set-DispatchJsonPropertyValue -Object $binding -Name 'process_exit_code' -Value $sidecar.ProcessExitCode
            Set-DispatchJsonPropertyValue -Object $binding -Name 'process_exit_code_source' -Value 'sidecar'
            Set-DispatchJsonPropertyValue -Object $binding -Name 'sidecar_sha256' -Value $sidecar.Sha256
            $null = Write-DispatchAtomicJsonDocument -Path $resultPath -Document $document -SourceRoot $sourceRootPath -ExecutionRoot $executionRootPath -TargetPath @($TargetPath) -ExpectedExistingSha256 $resultFileSha256AtRead
        }
        catch {
            $bindingWriteErrorCode = [string]$_.Exception.Data['errorCode']
            if ([string]::IsNullOrWhiteSpace($bindingWriteErrorCode)) {
                $bindingWriteErrorCode = 'DispatchResultBindingWriteFailed'
            }
            Throw-DispatchInspectBindingFailure -Code $bindingWriteErrorCode -Message ('Dispatch result binding 更新失敗：' + $resultPath) -DispatchResultPath $resultPath -Detail ([ordered]@{ sidecar_path = $sidecar.Path; expected_result_sha256 = $resultFileSha256AtRead })
        }
    }

    return [pscustomobject]@{
        Path = $resultPath
        Document = $document
        Record = $record
        EventStreamPath = $bindingPaths.event_stream_path
        RunRecordPath = $bindingPaths.run_record_path
        ScopePlanPath = $bindingPaths.scope_plan_path
        QuotaBeforePath = $bindingPaths.quota_before_path
        QuotaBeforeSha256 = $quotaBeforeSha256
        SidecarPath = $sidecar.Path
        SidecarSha256 = $sidecar.Sha256
        ProcessExitCode = $sidecar.ProcessExitCode
        ProcessExitCodeSource = if ($sidecarPending) { 'sidecar-pending' } else { 'sidecar' }
    }
}

function Invoke-Inspect {
    $modelEvidence = $null
    $requiredOutputGate = $null
    $evidencePackInfo = $null
    $diagnosis = $null
    $secretExposure = [ordered]@{ secret_exposure_suspected = $false; secret_exposure_findings = @() }
    $dispatchInspectBinding = $null
    $dispatchResultPathValue = $null
    $waitResult = $null
    $processExitCodeSource = 'explicit'
    $processExitCodeSidecarPath = $null
    $processExitCodeSidecarSha256 = $null
    if ([string]::IsNullOrWhiteSpace($RequiredIdentifier)) {
        throw 'Inspect 必須提供 RequiredIdentifier。'
    }
    if ($WaitForCompletion -and [string]::IsNullOrWhiteSpace($DispatchResultPath)) {
        throw 'WaitForCompletion 必須搭配 DispatchResultPath。'
    }
    if (-not [string]::IsNullOrWhiteSpace($DispatchResultPath)) {
        if ([string]::IsNullOrWhiteSpace($SourceRoot) -or [string]::IsNullOrWhiteSpace($ExecutionRoot) -or
            [string]::IsNullOrWhiteSpace($LineSlug) -or [string]::IsNullOrWhiteSpace($DispatchSlug)) {
            Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message '使用 DispatchResultPath 時必須同時提供 SourceRoot、ExecutionRoot、LineSlug 與 DispatchSlug。' -DispatchResultPath $DispatchResultPath
        }
        $dispatchInspectBinding = Resolve-DispatchInspectBinding -DispatchResultPathValue $DispatchResultPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -TargetPath @($TargetPath) -AllowPendingExitSidecar
        if ($null -eq $dispatchInspectBinding.ProcessExitCode -and $WaitForCompletion) {
            $waitResult = Wait-DispatchExitAndTerminalEvent -ExecutionRoot $ExecutionRoot -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -WriteMode $WriteMode -RunRecordPath $dispatchInspectBinding.RunRecordPath -EventStreamPath $dispatchInspectBinding.EventStreamPath -SidecarPath $dispatchInspectBinding.SidecarPath
            $dispatchInspectBinding = Resolve-DispatchInspectBinding -DispatchResultPathValue $DispatchResultPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -TargetPath @($TargetPath)
        }
        $dispatchResultPathValue = $dispatchInspectBinding.Path
        $bindingPathArguments = @(
            [pscustomobject]@{ Name = 'RunRecordPath'; Expected = $dispatchInspectBinding.RunRecordPath }
            [pscustomobject]@{ Name = 'EventStreamPath'; Expected = $dispatchInspectBinding.EventStreamPath }
            [pscustomobject]@{ Name = 'ScopePlanPath'; Expected = $dispatchInspectBinding.ScopePlanPath }
            [pscustomobject]@{ Name = 'QuotaBeforePath'; Expected = $dispatchInspectBinding.QuotaBeforePath }
        )
        foreach ($bindingPathArgument in $bindingPathArguments) {
            if (Test-DispatchInvocationParameterBound -Name $bindingPathArgument.Name) {
                $receivedPath = Get-DispatchInvocationParameterValue -Name $bindingPathArgument.Name
                if ($null -eq $receivedPath -or [string]::IsNullOrWhiteSpace([string]$receivedPath)) {
                    Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ($bindingPathArgument.Name + ' 不可在 Dispatch binding 模式中為空。') -DispatchResultPath $dispatchResultPathValue -Detail ([ordered]@{ field = $bindingPathArgument.Name })
                }
                try {
                    $resolvedReceivedPath = Resolve-AbsolutePath -Path ([string]$receivedPath)
                }
                catch {
                    Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ($bindingPathArgument.Name + ' 無法解析：' + $_.Exception.Message) -DispatchResultPath $dispatchResultPathValue -Detail ([ordered]@{ field = $bindingPathArgument.Name; value = $receivedPath })
                }
                if (-not [string]::Equals($resolvedReceivedPath, [string]$bindingPathArgument.Expected, [StringComparison]::OrdinalIgnoreCase)) {
                    Throw-DispatchInspectBindingFailure -Code 'DispatchResultBindingInvalid' -Message ($bindingPathArgument.Name + ' 與 Dispatch result binding 不一致。') -DispatchResultPath $dispatchResultPathValue -Detail ([ordered]@{ field = $bindingPathArgument.Name; expected = $bindingPathArgument.Expected; received = $resolvedReceivedPath })
                }
            }
            Set-Variable -Name $bindingPathArgument.Name -Scope Local -Value ([string]$bindingPathArgument.Expected)
        }
        Set-Variable -Name 'ProcessExitCode' -Scope Local -Value ([Nullable[int]]$dispatchInspectBinding.ProcessExitCode)
        $processExitCodeSource = [string]$dispatchInspectBinding.ProcessExitCodeSource
        $processExitCodeSidecarPath = [string]$dispatchInspectBinding.SidecarPath
        $processExitCodeSidecarSha256 = [string]$dispatchInspectBinding.SidecarSha256
        if ($null -eq $dispatchInspectBinding.ProcessExitCode) {
            $secretExposure = Get-DispatchInspectSecretExposure -EventStreamPath $dispatchInspectBinding.EventStreamPath -LastMessagePath ([string]$dispatchInspectBinding.Record.last_message_path)
            $pendingResult = [ordered]@{
                operation = 'Inspect'
                status = 'started'
                success = $null
                completed = $false
                processStarted = $true
                processExitCode = $null
                processExitCodeSource = 'sidecar-pending'
                processExitCodeSidecarPath = $processExitCodeSidecarPath
                eventStreamPath = $dispatchInspectBinding.EventStreamPath
                dispatchResultPath = $dispatchResultPathValue
                terminationReason = $null
            }
            return Protect-DispatchInspectResult -Result $pendingResult -SecretExposure $secretExposure
        }
    }
    if ([string]::IsNullOrWhiteSpace($DispatchSlug)) {
        throw 'Inspect 必須提供 DispatchSlug。'
    }
    if ([string]::IsNullOrWhiteSpace($LineSlug)) {
        throw 'Inspect 必須提供 LineSlug。'
    }
    if ([string]::IsNullOrWhiteSpace($EventStreamPath)) {
        throw 'Inspect 必須提供 EventStreamPath。'
    }
    if ($null -eq $ProcessExitCode) {
        throw 'Inspect 必須提供 ProcessExitCode。'
    }
    $eventPath = Resolve-AbsolutePath -Path $EventStreamPath
    $malformedJsonLine = Get-DispatchInspectMalformedJsonLine -EventStreamPath $eventPath
    if ($malformedJsonLine -gt 0) {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectJsonParseFailed' -FilePath $eventPath -LineNumber $malformedJsonLine
    }
    $eventEvidence = Get-DispatchEventEvidence -EventPath $eventPath
    $serviceRejectionEvidence = Convert-EventEvidenceToServiceRejection -EventEvidence $eventEvidence
    try {
        $inspectRun = Resolve-InspectDispatchRun -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -EventStreamPath $eventPath -ScopePlanPath $ScopePlanPath -RunRecordPath $RunRecordPath
    }
    catch {
        $malformedJsonLine = Get-DispatchInspectMalformedJsonLine -EventStreamPath $eventPath
        if ($malformedJsonLine -gt 0) {
            Throw-DispatchInspectSanitizedFailure -Code 'InspectJsonParseFailed' -FilePath $eventPath -LineNumber $malformedJsonLine
        }
        throw
    }
    $secretExposure = Get-DispatchInspectSecretExposure -EventStreamPath $eventPath -LastMessagePath ([string]$inspectRun.Record.last_message_path)
    $recordModelEvidence = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'model_evidence'
    $recordReasoningEffortEvidence = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'reasoning_effort_evidence'
    $modelEvidenceGroup = ConvertTo-DispatchEvidenceGroup -Evidence $recordModelEvidence -Field 'model'
    $effortEvidenceGroup = ConvertTo-DispatchEvidenceGroup -Evidence $recordReasoningEffortEvidence -Field 'model_reasoning_effort'
    $modelEvidenceGroup.runtime_verifiable = New-UnknownDispatchEvidence -Field 'payload.model' -Reason 'Inspect 不執行環境探針，且沒有公開可驗證的實際 model 證據。' -Source 'public-actual-unavailable'
    $effortEvidenceGroup.runtime_verifiable = New-UnknownDispatchEvidence -Field 'payload.effort' -Reason 'Inspect 不執行環境探針，且沒有公開可驗證的實際 reasoning effort 證據。' -Source 'public-actual-unavailable'
    $modelEvidence = [ordered]@{
        evidence_contract = 'codex-dispatch.model-evidence.v1'
        model = $modelEvidenceGroup
        reasoning_effort = $effortEvidenceGroup
    }
    if ($inspectRun.Record.launch_state -eq 'launch-failed') {
        $failure = Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'failure'
        $failureOriginalOutput = Get-DispatchJsonProperty -Object $failure -Name 'original_output'
        $diagnosis = [ordered]@{
            status = 'failed'
            reason_code = [string](Get-DispatchJsonProperty -Object $failure -Name 'reason_code')
            observation = Get-DispatchJsonProperty -Object $failure -Name 'observation'
            original_output = $failureOriginalOutput
        }
        $failureErrorPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'error_stream_path')
        $failureStderr = ''
        if ([string]::IsNullOrWhiteSpace($failureErrorPath)) {
            $failureErrorPath = [string](Get-DispatchJsonProperty -Object $failureOriginalOutput -Name 'stderr').path
        }
        if (-not [string]::IsNullOrWhiteSpace($failureErrorPath) -and (Test-Path -LiteralPath $failureErrorPath -PathType Leaf)) {
            $failureStderr = Get-Content -LiteralPath $failureErrorPath -Raw -Encoding UTF8
        }
        $launchFailureResult = [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            lastMessageConsistency = 'NotApplicable'
            finalMessageSource = 'none'
            eventStreamPath = $eventPath
            errorStreamPath = if ([string]::IsNullOrWhiteSpace($failureErrorPath)) { $null } else { $failureErrorPath }
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            dispatchResultPath = $dispatchResultPathValue
            eventCount = 0
            lastEventType = 'none'
            threadId = $null
            completed = $false
            success = $false
            turnFailedReason = [string](Get-DispatchJsonProperty -Object $failure -Name 'message')
            finalMessage = $null
            outputValid = $false
            diagnosis = $diagnosis
            failure = $failure
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            modelEvidence = $modelEvidence
            reasoningEffortEvidence = $modelEvidence.reasoning_effort
            profile = [string](Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'parent_options') -Name 'profile')
            stderr = $failureStderr
        }
        return Protect-DispatchInspectResult -Result $launchFailureResult -SecretExposure $secretExposure
    }
    if (-not [System.IO.File]::Exists((ConvertTo-FileSystemApiPath -Path $eventPath))) {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectEventStreamMissing' -FilePath $eventPath -LineNumber 1
    }

    $events = New-Object System.Collections.Generic.List[object]
    $eventLineNumbers = New-Object 'System.Collections.Generic.List[int]'
    $malformedLines = New-Object System.Collections.Generic.List[object]
    $rawEventLines = New-Object System.Collections.Generic.List[string]
    $threadIds = New-Object System.Collections.Generic.List[string]
    $lineNumber = 0
    foreach ($line in ((Read-DispatchUtf8Text -Path $eventPath) -split '\r?\n')) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $rawEventLines.Add($line)
        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $malformedLines.Add([pscustomobject]@{
                    LineNumber = $lineNumber
                    ErrorCode  = 'InspectJsonParseFailed'
                })
            continue
        }
        $typeProperty = if ($null -eq $event) { $null } else { $event.PSObject.Properties['type'] }
        $typeValue = if ($null -eq $typeProperty) { $null } else { $typeProperty.Value }
        if ($null -eq $event -or $null -eq $typeProperty -or -not ($typeValue -is [string]) -or [string]::IsNullOrWhiteSpace($typeValue)) {
            $malformedLines.Add([pscustomobject]@{
                    LineNumber = $lineNumber
                    ErrorCode  = 'InspectEventTypeMissing'
                })
            continue
        }
        $events.Add($event)
        $eventLineNumbers.Add($lineNumber)
    }
    if ($malformedLines.Count -gt 0) {
        $firstMalformedLine = $malformedLines[0]
        $malformedErrorCode = [string]$firstMalformedLine.ErrorCode
        $malformedFilePath = [string]$eventPath
        $malformedLineNumber = [int]$firstMalformedLine.LineNumber
        $malformedMessage = '{0}: file={1}; line={2}' -f $malformedErrorCode, $malformedFilePath, $malformedLineNumber
        $malformedDiagnosis = New-DispatchInspectDiagnosis -ReasonCode $malformedErrorCode -Observation $malformedMessage -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @() -Stderr ''
        $sanitizedEventEvidence = [ordered]@{
            path = [string]$eventEvidence.path
            exists = [bool]$eventEvidence.exists
            sha256 = $eventEvidence.sha256
            event_state = 'unknown'
            last_event_type = $eventEvidence.last_event_type
            raw_lines = [string[]]@()
            usage_limit_evidence = @()
            usage_limit = $false
        }
        $malformedFailure = [ordered]@{
            errorCode = $malformedErrorCode
            file = $malformedFilePath
            line = $malformedLineNumber
        }
        $malformedResult = [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            success = $false
            outputValid = $false
            errorCode = $malformedErrorCode
            error = $malformedMessage
            failure = $malformedFailure
            diagnosis = $malformedDiagnosis
            eventEvidence = $sanitizedEventEvidence
            service_rejection = $null
            retry_allowed = $null
            eventStreamPath = $eventPath
            errorStreamPath = $ErrorStreamPath
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            dispatchResultPath = $dispatchResultPathValue
        }
        $malformedException = New-Object System.InvalidOperationException($malformedMessage)
        $malformedResult = Protect-DispatchInspectResult -Result $malformedResult -SecretExposure $secretExposure
        $malformedException = Write-DispatchOperationFailureResult -Exception $malformedException -Result $malformedResult
        throw $malformedException
    }
    if ($events.Count -eq 0) {
        $emptyLineNumber = 1
        $emptyMessage = 'InspectEventStreamEmpty: file={0}; line={1}' -f $eventPath, $emptyLineNumber
        $emptyStderr = ''
        $emptyDiagnosis = New-DispatchInspectDiagnosis -ReasonCode 'InspectEventStreamEmpty' -Observation $emptyMessage -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @() -Stderr $emptyStderr
        $emptyResult = [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            success = $false
            outputValid = $false
            errorCode = 'InspectEventStreamEmpty'
            error = $emptyMessage
            failure = [ordered]@{ errorCode = 'InspectEventStreamEmpty'; file = $eventPath; line = $emptyLineNumber }
            diagnosis = $emptyDiagnosis
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            eventStreamPath = $eventPath
            errorStreamPath = $ErrorStreamPath
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            dispatchResultPath = $dispatchResultPathValue
        }
        $emptyException = New-Object System.Exception($emptyMessage)
        $emptyResult = Protect-DispatchInspectResult -Result $emptyResult -SecretExposure $secretExposure
        $emptyException = Write-DispatchOperationFailureResult -Exception $emptyException -Result $emptyResult
        throw $emptyException
    }

    $eventTailType = [string](Get-EventPropertyValue -Object $events[$events.Count - 1] -Name 'type')
    if ($eventTailType -eq 'turn.started' -and [int]$ProcessExitCode -ne 0) {
        $unknownStderr = ''
        if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) {
            $unknownStderr = Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8
        }
        $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'InterruptedUnknown' -Observation '事件流在 turn.started 後沒有後續事件，且 process exit code 非零。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $unknownStderr
        $interruptionScopePlan = if ([string]::IsNullOrWhiteSpace($ScopePlanPath)) { $null } else { Read-ScopePlanFile -Path $ScopePlanPath }
        $interruptionSelectedUnitsValue = Get-DispatchJsonProperty -Object $interruptionScopePlan -Name 'selected_units'
        $interruptionSelectedUnits = @($interruptionSelectedUnitsValue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        $interruptionCheckpointPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'interruption_checkpoint_path')
        if ([string]::IsNullOrWhiteSpace($interruptionCheckpointPath)) {
            $interruptionCheckpointPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$inspectRun.Record.run_id)
        }
        $lastAgentMessage = ''
        $interruptionEventIndex = 0
        foreach ($interruptionEvent in $events) {
            $interruptionEventLineNumber = [int]$eventLineNumbers[$interruptionEventIndex]
            $interruptionEventIndex++
            $interruptionEventType = Get-EventPropertyValue -Object $interruptionEvent -Name 'type'
            $interruptionItem = Get-EventPropertyValue -Object $interruptionEvent -Name 'item'
            if ($interruptionEventType -eq 'item.completed' -and $null -ne $interruptionItem -and (Get-EventPropertyValue -Object $interruptionItem -Name 'type') -ceq 'agent_message') {
                $interruptionMessage = Get-EventPropertyValue -Object $interruptionItem -Name 'text'
                if ($null -eq $interruptionMessage -or -not ($interruptionMessage -is [string]) -or [string]::IsNullOrWhiteSpace($interruptionMessage)) {
                    Throw-DispatchInspectSanitizedFailure -Code 'InspectInvalidAgentMessage' -FilePath $eventPath -LineNumber $interruptionEventLineNumber
                }
                $lastAgentMessage = $interruptionMessage
            }
        }
        $interruptionCheckpoint = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $interruptionCheckpointPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$inspectRun.Record.run_id) -SelectedUnits $interruptionSelectedUnits -Message $lastAgentMessage -SourcePath @($ScopePlanPath, $inspectRun.Path, $eventPath)
        $unknownInterruption = [ordered]@{
            status = 'InterruptedUnknown'
            cold_start_recommended = $true
            last_event_type = $eventTailType
            process_exit_code = [int]$ProcessExitCode
            event_tail = if ($secretExposure.secret_exposure_suspected) { @('[REDACTED: possible secret exposure]') } else { @($rawEventLines.ToArray() | Select-Object -Last 3) }
            interruption_checkpoint_path = $interruptionCheckpoint.path
            confirmed_units = @($interruptionCheckpoint.confirmed_units)
            incomplete_units = @($interruptionCheckpoint.incomplete_units)
        }
        if ($null -eq $inspectRun.Record.PSObject.Properties['unknown_interruption']) {
            $inspectRun.Record | Add-Member -MemberType NoteProperty -Name 'unknown_interruption' -Value $unknownInterruption
        }
        else {
            $inspectRun.Record.unknown_interruption = $unknownInterruption
        }
        $null = Write-DispatchRunRecord -Record $inspectRun.Record -Update
        $unknownEventResult = [ordered]@{
            operation = 'Inspect'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            lastMessageConsistency = 'NotApplicable'
            finalMessageSource = 'none'
            eventStreamPath = $eventPath
            errorStreamPath = $ErrorStreamPath
            processExitCode = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            eventCount = $events.Count
            lastEventType = $eventTailType
            threadId = [string](Get-EventPropertyValue -Object $events[0] -Name 'thread_id')
            completed = $false
            success = $false
            turnFailedReason = ''
            finalMessage = $null
            outputValid = $false
            diagnosis = $diagnosis
            cold_start_recommended = $true
            recoveryState = 'InterruptedUnknown'
            unknownInterruption = $unknownInterruption
            interruptionCheckpoint = $interruptionCheckpoint
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            stderr = $unknownStderr
        }
        return Protect-DispatchInspectResult -Result $unknownEventResult -SecretExposure $secretExposure
    }

    $threadId = ''
    $finalEventMessage = ''
    $lastAgentMessage = ''
    $lastThreadIdLineNumber = 0
    $usage = $null
    $eventIndex = 0
    foreach ($event in $events) {
        $currentEventLineNumber = [int]$eventLineNumbers[$eventIndex]
        $eventIndex++
        $eventType = Get-EventPropertyValue -Object $event -Name 'type'
        if ($eventType -eq 'thread.started') {
            $threadIdValue = Get-EventPropertyValue -Object $event -Name 'thread_id'
            if ($null -eq $threadIdValue -or -not ($threadIdValue -is [string]) -or [string]::IsNullOrWhiteSpace($threadIdValue)) {
                Throw-DispatchInspectSanitizedFailure -Code 'InspectMissingThreadId' -FilePath $eventPath -LineNumber $currentEventLineNumber
            }
            $parsedThreadId = [guid]::Empty
            if (-not [guid]::TryParse($threadIdValue, [ref]$parsedThreadId)) {
                Throw-DispatchInspectSanitizedFailure -Code 'InspectInvalidThreadId' -FilePath $eventPath -LineNumber $currentEventLineNumber
            }
            $threadIds.Add($threadIdValue)
            $lastThreadIdLineNumber = $currentEventLineNumber
        }
        $item = Get-EventPropertyValue -Object $event -Name 'item'
        if ($null -ne $item) {
            $itemType = Get-EventPropertyValue -Object $item -Name 'type'
            if ($eventType -eq 'item.completed' -and ($itemType -is [string]) -and $itemType -eq 'agent_message') {
                $textValue = Get-EventPropertyValue -Object $item -Name 'text'
                if ($null -eq $textValue -or -not ($textValue -is [string]) -or [string]::IsNullOrWhiteSpace($textValue)) {
                    Throw-DispatchInspectSanitizedFailure -Code 'InspectInvalidAgentMessage' -FilePath $eventPath -LineNumber $currentEventLineNumber
                }
                $lastAgentMessage = $textValue
            }
        }
        if ($eventType -in @('turn.completed', 'turn.failed')) {
            $usage = Get-EventPropertyValue -Object $event -Name 'usage'
        }
        if ($eventType -eq 'error') {
            $messageValue = Get-EventPropertyValue -Object $event -Name 'message'
            if ($null -ne $messageValue) {
                if (-not ($messageValue -is [string])) {
                    Throw-DispatchInspectSanitizedFailure -Code 'InspectInvalidErrorMessage' -FilePath $eventPath -LineNumber $currentEventLineNumber
                }
                $finalEventMessage = $messageValue
            }
        }
    }

    $lastEvent = $events[$events.Count - 1]
    $lastEventType = Get-EventPropertyValue -Object $lastEvent -Name 'type'
    $terminalEventAvailable = $lastEventType -in @('turn.completed', 'turn.failed')
    if ($null -ne $waitResult) {
        $terminalEventAvailable = [bool]$waitResult.TerminalEventAvailable
    }

    $distinctThreadIds = @($threadIds.ToArray() | Sort-Object -Unique)
    if ($distinctThreadIds.Count -gt 1) {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectThreadIdMismatch' -FilePath $eventPath -LineNumber $lastThreadIdLineNumber
    }
    if ($distinctThreadIds.Count -eq 0) {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectMissingThreadId' -FilePath $eventPath -LineNumber ([int]$eventLineNumbers[$eventLineNumbers.Count - 1])
    }
    $threadId = $distinctThreadIds[0]

    if ($lastEventType -notin @('turn.completed', 'turn.failed')) {
        $inspectStderr = ''
        if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) {
            $inspectStderr = Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8
        }
        $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'InterruptedUnknown' -Observation ('Codex process 已結束，但事件流沒有 turn.completed 或 turn.failed；last_event_type=' + [string]$lastEventType + '; process_exit_code=' + [string][int]$ProcessExitCode) -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
        $interruptionScopePlan = if ([string]::IsNullOrWhiteSpace($ScopePlanPath)) { $null } else { Read-ScopePlanFile -Path $ScopePlanPath }
        $interruptionSelectedUnitsValue = Get-DispatchJsonProperty -Object $interruptionScopePlan -Name 'selected_units'
        $interruptionSelectedUnits = @($interruptionSelectedUnitsValue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
        $interruptionCheckpointPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'interruption_checkpoint_path')
        if ([string]::IsNullOrWhiteSpace($interruptionCheckpointPath)) {
            $interruptionCheckpointPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$inspectRun.Record.run_id)
        }
        $interruptionCheckpoint = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $interruptionCheckpointPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$inspectRun.Record.run_id) -SelectedUnits $interruptionSelectedUnits -Message $lastAgentMessage -SourcePath @($ScopePlanPath, $inspectRun.Path, $eventPath)
        $unknownInterruption = [ordered]@{
            status = 'InterruptedUnknown'
            cold_start_recommended = $true
            last_event_type = [string]$lastEventType
            process_exit_code = [int]$ProcessExitCode
            interruption_checkpoint_path = $interruptionCheckpoint.path
            interruption_checkpoint_source = [string](Get-OptionalObjectProperty -Object $interruptionCheckpoint -Name 'source')
            confirmed_units = @($interruptionCheckpoint.confirmed_units)
            incomplete_units = @($interruptionCheckpoint.incomplete_units)
            event_tail = if ($secretExposure.secret_exposure_suspected) { @('[REDACTED: possible secret exposure]') } else { @($rawEventLines.ToArray() | Select-Object -Last 3) }
        }
        if ($null -eq $inspectRun.Record.PSObject.Properties['unknown_interruption']) {
            $inspectRun.Record | Add-Member -MemberType NoteProperty -Name 'unknown_interruption' -Value $unknownInterruption
        }
        else {
            $inspectRun.Record.unknown_interruption = $unknownInterruption
        }
        $null = Write-DispatchRunRecord -Record $inspectRun.Record -Update
        $unknownTerminalResult = [ordered]@{
            operation = 'Inspect'
            status = 'interrupted'
            runId = $inspectRun.Record.run_id
            runRecordPath = $inspectRun.Path
            lastMessageConsistency = 'NotApplicable'
            finalMessageSource = 'none'
            eventStreamPath = $eventPath
            processExitCode = [int]$ProcessExitCode
            process_exit_code = [int]$ProcessExitCode
            processExitCodeSource = $processExitCodeSource
            processExitCodeSidecarPath = $processExitCodeSidecarPath
            processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
            dispatchResultPath = $dispatchResultPathValue
            eventCount = $events.Count
            lastEventType = [string]$lastEventType
            terminalEventAvailable = $terminalEventAvailable
            threadId = $threadId
            completed = $false
            success = $false
            turnFailedReason = ''
            finalMessage = $null
            outputValid = $false
            diagnosis = $diagnosis
            cold_start_recommended = $true
            recoveryState = 'InterruptedUnknown'
            unknownInterruption = $unknownInterruption
            interruptionCheckpoint = $interruptionCheckpoint
            scopePlan = $interruptionScopePlan
            eventEvidence = $eventEvidence
            service_rejection = $serviceRejectionEvidence
            retry_allowed = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
            stderr = $inspectStderr
        }
        return Protect-DispatchInspectResult -Result $unknownTerminalResult -SecretExposure $secretExposure
    }

    if ([string]::IsNullOrWhiteSpace($lastAgentMessage) -and $lastEventType -ne 'turn.failed') {
        Throw-DispatchInspectSanitizedFailure -Code 'InspectMissingAgentMessage' -FilePath $eventPath -LineNumber ([int]$eventLineNumbers[$eventLineNumbers.Count - 1])
    }

    if ($lastEventType -eq 'turn.completed') {
        $usageProperty = $lastEvent.PSObject.Properties['usage']
        if ($null -eq $usageProperty -or -not (Test-UsageObject -Value $usageProperty.Value)) {
            Throw-DispatchInspectSanitizedFailure -Code 'InspectMissingUsage' -FilePath $eventPath -LineNumber ([int]$eventLineNumbers[$eventLineNumbers.Count - 1])
        }
    }

    $turnFailedReason = ''
    $turnFailedError = $null
    if ($lastEventType -eq 'turn.failed') {
        $errorObject = Get-EventPropertyValue -Object $lastEvent -Name 'error'
        $turnFailedError = $errorObject
        if ($null -ne $errorObject) {
            $errorMessage = Get-EventPropertyValue -Object $errorObject -Name 'message'
            if ($null -ne $errorMessage) {
                if (-not ($errorMessage -is [string])) {
                    Throw-DispatchInspectSanitizedFailure -Code 'InspectInvalidTurnFailedMessage' -FilePath $eventPath -LineNumber ([int]$eventLineNumbers[$eventLineNumbers.Count - 1])
                }
                $turnFailedReason = $errorMessage
            }
        }
        if ([string]::IsNullOrWhiteSpace($turnFailedReason)) {
            $turnFailedReason = $finalEventMessage
        }
    }
    $inspectStderr = ''
    if (-not [string]::IsNullOrWhiteSpace($ErrorStreamPath) -and (Test-Path -LiteralPath $ErrorStreamPath -PathType Leaf)) {
        $inspectStderr = Get-Content -LiteralPath $ErrorStreamPath -Raw -Encoding UTF8
    }
    if ($lastEventType -eq 'turn.failed' -or [int]$ProcessExitCode -ne 0) {
        $diagnosisReasonCode = if ([string]::IsNullOrWhiteSpace($turnFailedReason)) { 'Unknown' } else { 'CodexLaunchFailed' }
        $diagnosisObservation = if ([string]::IsNullOrWhiteSpace($turnFailedReason)) {
            if ($lastEventType -eq 'turn.failed') { 'turn.failed 沒有提供可解析的 error.message。' } else { 'process exit code 非零，但事件流沒有可確認的錯誤原因。' }
        }
        else {
            '事件流提供 turn.failed error.message。'
        }
        $diagnosis = New-DispatchInspectDiagnosis -ReasonCode $diagnosisReasonCode -Observation $diagnosisObservation -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
    }

    $finalMessage = $lastAgentMessage
    $finalMessageIdentity = Get-DispatchFinalMessageIdentity -Message $finalMessage -RequiredIdentifier $RequiredIdentifier -DispatchSlug $DispatchSlug -LineSlug $LineSlug -Source $eventPath
    $explicitMessagePath = -not [string]::IsNullOrWhiteSpace($LastMessagePath)
    $messagePath = $inspectRun.Record.last_message_path
    $lastMessageConsistency = 'Missing'
    if ($explicitMessagePath -and -not [string]::Equals((Resolve-AbsolutePath $LastMessagePath), $messagePath, [StringComparison]::OrdinalIgnoreCase)) {
        $lastMessageConsistency = 'BindingMismatch'
    }
    else {
        $externalMessage = ''
        if (Test-Path -LiteralPath $messagePath -PathType Leaf) {
            $utf8 = New-Object Text.UTF8Encoding($false, $true)
            $externalMessage = $utf8.GetString((Read-DispatchSharedBytes -Path $messagePath))
        }
        if ([string]::IsNullOrWhiteSpace($externalMessage)) {
            if ($explicitMessagePath -and $lastEventType -ne 'turn.failed') {
                Throw-DispatchInspectSanitizedFailure -Code 'InspectLastMessageUnavailable' -FilePath $messagePath -LineNumber 1
            }
        }
        elseif ([string]::Equals((ConvertTo-ComparableDispatchMessage $finalMessage), (ConvertTo-ComparableDispatchMessage $externalMessage), [StringComparison]::Ordinal)) {
            $lastMessageConsistency = 'Match'
        }
        else {
            $lastMessageConsistency = 'Mismatch'
        }
    }

    $outputValid = $lastMessageConsistency -in @('Match', 'Missing') -and $finalMessageIdentity.valid
    if (-not $finalMessageIdentity.valid -and $null -eq $diagnosis) {
        $identityObservation = ($finalMessageIdentity.mismatches | ForEach-Object {
                '{0}: expected={1}; received={2}' -f [string]$_.field, [string]$_.expected, [string]$_.received
            }) -join '; '
        $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'FinalMessageIdentityMismatch' -Observation $identityObservation -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
        $diagnosis.identity_mismatches = @($finalMessageIdentity.mismatches)
    }
    if ($TaskType -eq 'advisor-consult') {
        $inspectEvidencePath = $EvidencePackPath
        if ([string]::IsNullOrWhiteSpace($inspectEvidencePath)) {
            $inspectEvidencePath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'evidence_pack_path')
        }
        if ([string]::IsNullOrWhiteSpace($inspectEvidencePath)) {
            throw 'EvidencePackMissing：advisor-consult Inspect 缺少 EvidencePackPath。'
        }
        $evidencePackInfo = Test-AdvisorEvidencePack -Path $inspectEvidencePath -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $evidenceHashRecordPath = Join-Path -Path (Split-Path -Parent $eventPath) -ChildPath ('evidence-pack-' + $DispatchSlug + '.sha256')
        $evidenceLengthRecordPath = Join-Path -Path (Split-Path -Parent $eventPath) -ChildPath ('evidence-pack-' + $DispatchSlug + '.length')
        if (-not (Test-Path -LiteralPath $evidenceHashRecordPath -PathType Leaf)) {
            throw 'EvidencePackInvalid：evidence pack 缺少 Start SHA-256 紀錄。'
        }
        $expectedHash = (Get-Content -LiteralPath $evidenceHashRecordPath -Raw -Encoding UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or -not [string]::Equals($expectedHash, $evidencePackInfo.sha256, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'EvidencePackInlineMismatch：evidence pack SHA-256 在 Start 與 Inspect 之間變更。'
        }
        if (-not (Test-Path -LiteralPath $evidenceLengthRecordPath -PathType Leaf)) {
            throw 'EvidencePackInvalid：evidence pack 缺少 Start length 紀錄。'
        }
        $expectedLengthText = (Get-Content -LiteralPath $evidenceLengthRecordPath -Raw -Encoding UTF8).Trim()
        $expectedLength = [int64]0
        if (-not [int64]::TryParse($expectedLengthText, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$expectedLength) -or $expectedLength -ne [int64]$evidencePackInfo.length) {
            throw 'EvidencePackInlineMismatch：evidence pack length 在 Start 與 Inspect 之間變更。'
        }
        $requiredOutputGate = Test-RequiredOutputSections -Message $finalMessage -RequiredOutput $evidencePackInfo.required_output
        if (-not $requiredOutputGate.valid) {
            $outputValid = $false
            if ($null -eq $diagnosis) {
                $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'EvidencePackRequiredOutputInvalid' -Observation '最後訊息缺少 evidence pack 宣告的 required output section 或 body。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
            }
        }
    }
    $threadRelay = $null
    if (-not [string]::IsNullOrWhiteSpace($ThreadIdPath)) {
        $threadRelay = Set-ThreadIdFromEventStream -EventPath $eventPath -ThreadPath (Resolve-AbsolutePath -Path $ThreadIdPath) -RequireThreadId
    }

    $executionResult = [ordered]@{
        completed        = $lastEventType -eq 'turn.completed'
        success          = $lastEventType -eq 'turn.completed' -and [int]$ProcessExitCode -eq 0 -and $outputValid
        lastEventType    = $lastEventType
        processExitCode  = [int]$ProcessExitCode
        turnFailedReason = $turnFailedReason
        outputValid      = $outputValid
    }
    if ($null -ne $serviceRejectionEvidence) {
        $executionResult.service_rejection = $serviceRejectionEvidence
        $executionResult.retry_allowed = $false
        $executionResult.success = $false
        if ([string]::IsNullOrWhiteSpace([string]$executionResult.turnFailedReason)) {
            $executionResult.turnFailedReason = 'quota service rejection'
        }
        if ($null -eq $diagnosis -or [string](Get-OptionalObjectProperty -Object $diagnosis -Name 'reason_code') -ne 'QuotaServiceRejected') {
            $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'QuotaServiceRejected' -Observation '事件流包含 quota service rejection，禁止自動 retry。' -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
        }
    }
    if ($lastEventType -eq 'turn.failed' -and $null -ne $turnFailedError -and $null -ne $diagnosis) {
        $diagnosis.error = $turnFailedError
    }
    $scopePlan = Read-ScopePlanFile -Path $ScopePlanPath
    $scopePlanSelectedUnitsValue = Get-DispatchJsonProperty -Object $scopePlan -Name 'selected_units'
    $scopePlanSelectedUnits = @($scopePlanSelectedUnitsValue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $scopePlanDeferredUnitsValue = Get-DispatchJsonProperty -Object $scopePlan -Name 'deferred_units'
    $scopePlanDeferredUnits = @($scopePlanDeferredUnitsValue | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $interruptionCheckpointPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'interruption_checkpoint_path')
    if ([string]::IsNullOrWhiteSpace($interruptionCheckpointPath)) {
        $interruptionCheckpointPath = Get-DispatchInterruptionCheckpointPath -SourceRoot $SourceRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$inspectRun.Record.run_id)
    }
    $interruptionCheckpoint = Get-DispatchInterruptionCheckpointWithMessageFallback -Path $interruptionCheckpointPath -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -RunId ([string]$inspectRun.Record.run_id) -SelectedUnits $scopePlanSelectedUnits -Message $finalMessage -SourcePath @($ScopePlanPath, $inspectRun.Path, $eventPath)
    $advisorCompletionPartition = $null
    if ($TaskType -eq 'advisor-consult') {
        $advisorCompletionPartition = Get-AdvisorCompletionPartition -Message $finalMessage -SelectedUnits $scopePlanSelectedUnits -DeferredUnits $scopePlanDeferredUnits
        if ($advisorCompletionPartition.status -eq 'invalid') {
            $outputValid = $false
            $executionResult.outputValid = $false
            $executionResult.success = $false
            if ($null -eq $diagnosis) {
                $diagnosis = New-DispatchInspectDiagnosis -ReasonCode 'AdvisorCompletedUnitsInvalid' -Observation ([string]$advisorCompletionPartition.reason) -EventStreamPath $eventPath -ErrorStreamPath $ErrorStreamPath -RawEventLines @($rawEventLines.ToArray()) -Stderr $inspectStderr
            }
        }
    }
    $snapshotFailure = $null
    $beforeSnapshotSha256Value = $null
    if ([string]::IsNullOrWhiteSpace($QuotaBeforePath)) {
        $snapshotFailure = 'Inspect 缺少 before quota snapshot。'
    }
    try {
        $resolvedQuotaBeforePath = Resolve-AbsolutePath -Path $QuotaBeforePath
        $recordQuotaBeforePath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_before_path')
        if ([string]::IsNullOrWhiteSpace($recordQuotaBeforePath) -or
            -not [string]::Equals($resolvedQuotaBeforePath, (Resolve-AbsolutePath -Path $recordQuotaBeforePath), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inspect quota before path 與 RunRecord 不一致。'
        }
        $beforeSnapshot = Read-QuotaSnapshot -Path $QuotaBeforePath
        $beforeSnapshotSha256Value = Get-FileSha256 -Path $QuotaBeforePath
        $recordQuotaBeforeSha256 = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_before_sha256')
        if ($recordQuotaBeforeSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            -not [string]::Equals($beforeSnapshotSha256Value, $recordQuotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inspect quota before SHA-256 與 RunRecord 不一致。'
        }
        if ($null -ne $dispatchInspectBinding -and
            -not [string]::Equals($beforeSnapshotSha256Value, [string]$dispatchInspectBinding.QuotaBeforeSha256, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Inspect quota before SHA-256 與 Dispatch result 不一致。'
        }
    }
    catch {
        $snapshotFailure = 'Inspect before quota snapshot 無效：' + $_.Exception.Message
    }
    $recordQuotaAfterPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_after_path')
    $recordQuotaAfterSha256 = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_after_sha256')
    $afterSnapshotPathValue = if ([string]::IsNullOrWhiteSpace($recordQuotaAfterPath)) { $QuotaAfterPath } else { $recordQuotaAfterPath }
    $afterSnapshotSha256Value = $null
    try {
        if ([string]::IsNullOrWhiteSpace($afterSnapshotPathValue) -and (-not [string]::IsNullOrWhiteSpace($CodexHome) -or -not [string]::IsNullOrWhiteSpace($env:CODEX_HOME))) {
            $historyRoot = Join-Path -Path (Resolve-AbsolutePath -Path $ExecutionRoot) -ChildPath '.local\ai-sessions\history'
            $afterSnapshotPathValue = Get-OrCreateQuotaSnapshot -Path $null -CodexHome $CodexHome -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath @() -HistoryRoot $historyRoot -Purpose 'after' -Required
        }
        if (-not [string]::IsNullOrWhiteSpace($afterSnapshotPathValue)) {
            $afterSnapshotPathValue = Resolve-AbsolutePath -Path $afterSnapshotPathValue
            if (-not (Test-PathWithinRoot -Path $afterSnapshotPathValue -Root $ExecutionRoot) -and -not (Test-PathWithinRoot -Path $afterSnapshotPathValue -Root $SourceRoot)) {
                throw "Inspect after quota snapshot 超出 source／execution root：$afterSnapshotPathValue"
            }
            $afterSnapshotSha256Value = Get-FileSha256 -Path $afterSnapshotPathValue
            if (-not [string]::IsNullOrWhiteSpace($recordQuotaAfterSha256) -and
                ($recordQuotaAfterSha256 -notmatch '^[a-fA-F0-9]{64}$' -or -not [string]::Equals($afterSnapshotSha256Value, $recordQuotaAfterSha256, [StringComparison]::OrdinalIgnoreCase))) {
                throw 'Inspect after quota SHA-256 與 RunRecord 不一致。'
            }
        }
    }
    catch {
        $snapshotFailure = 'Inspect after quota snapshot 取得失敗：' + $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($afterSnapshotPathValue)) {
        $snapshotFailure = 'Inspect 缺少 after quota snapshot。'
    }
    try {
        $afterSnapshot = Read-QuotaSnapshot -Path $afterSnapshotPathValue
    }
    catch {
        $snapshotFailure = 'Inspect after quota snapshot 無效：' + $_.Exception.Message
    }
    $closeSnapshotPathValue = $null
    $closeSnapshotSha256Value = $null
    $closeSnapshotStateValue = 'unknown'
    $closeHistoryRoot = Join-Path -Path (Resolve-AbsolutePath -Path $ExecutionRoot) -ChildPath ('.local\ai-sessions\history\' + $LineSlug)
    $closeSnapshotPathValue = New-QuotaSnapshotPath -HistoryRoot $closeHistoryRoot -Purpose 'close'
    $closeSnapshotPathValue = Get-OrCreateQuotaSnapshot -Path $null -SnapshotPath $closeSnapshotPathValue -CodexHome $CodexHome -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath @() -HistoryRoot $closeHistoryRoot -Purpose 'close' -Required
    $closeSnapshot = Read-QuotaSnapshot -Path $closeSnapshotPathValue
    $closeSnapshotSha256Value = Get-FileSha256 -Path $closeSnapshotPathValue
    $closeSnapshotSourceStateValue = [string](Get-DispatchJsonProperty -Object $closeSnapshot -Name 'state')
    $closeSnapshotPrimaryValue = Get-DispatchJsonProperty -Object $closeSnapshot -Name 'primary'
    $closeSnapshotSecondaryValue = Get-DispatchJsonProperty -Object $closeSnapshot -Name 'secondary'
    $closeSnapshotStateValue = if ($closeSnapshotSourceStateValue -eq 'Valid') { 'Valid' } elseif ($closeSnapshotSourceStateValue -eq 'SnapshotUnavailable') { 'unknown' } else { $closeSnapshotSourceStateValue }
    $recordQuotaObservationPath = [string](Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'quota_observation_path')
    $requestedQuotaObservationPath = if ([string]::IsNullOrWhiteSpace($BudgetMonitorPath)) { $recordQuotaObservationPath } else { $BudgetMonitorPath }
    $quotaObservationPathValue = $null
    if (-not [string]::IsNullOrWhiteSpace($requestedQuotaObservationPath)) {
        try {
            $candidateObservationPath = Resolve-AbsolutePath -Path $requestedQuotaObservationPath
            if (Test-PathWithinRoot -Path $candidateObservationPath -Root $closeHistoryRoot) {
                $quotaObservationPathValue = $candidateObservationPath
            }
        }
        catch {
        }
    }
    if ([string]::IsNullOrWhiteSpace($quotaObservationPathValue)) {
        $quotaObservationPathValue = Get-QuotaObservationPath -LineHistoryRoot $closeHistoryRoot -DispatchSlug $DispatchSlug
    }
    $closeProgress = if ($TaskType -eq 'advisor-consult') {
        Get-QuotaObservationProgress -EventPath $eventPath -ScopePlan $scopePlan -TaskType $TaskType
    }
    else {
        [ordered]@{
            event_count = $events.Count
            usage = $usage
            confirmed_conclusions = if ([string]::IsNullOrWhiteSpace($finalMessage)) { $null } elseif ($secretExposure.secret_exposure_suspected) { Protect-DispatchInspectText -Text $finalMessage } else { $finalMessage }
            completed_units = @()
            unfinished_units = @()
            completion_status = 'not-applicable'
        }
    }
    $closeMonitorWriteFailure = Invoke-BudgetMonitorRecordWrite -Path $quotaObservationPathValue -Record ([ordered]@{
            event = 'quota.snapshot'
            recorded_at_utc = [datetime]::UtcNow.ToString('o')
            state = $closeSnapshotStateValue
            source_state = $closeSnapshotSourceStateValue
            failure_code = if ($closeSnapshotStateValue -eq 'unknown') { 'quota-snapshot-unavailable' } else { $null }
            terminal = $true
            snapshot_path = $closeSnapshotPathValue
            snapshot_sha256 = $closeSnapshotSha256Value
            primary = $closeSnapshotPrimaryValue
            secondary = $closeSnapshotSecondaryValue
            progress = $closeProgress
        })
    $interruptionStatus = [ordered]@{
        applied = $true
        safePointPresent = -not [string]::IsNullOrWhiteSpace((Get-LatestSafePointMessage -EventPath $eventPath -TaskType $TaskType))
        sessionMode = $SessionMode
    }
    $budgetMonitor = @()
    if (-not [string]::IsNullOrWhiteSpace($quotaObservationPathValue)) {
        try {
            if (Test-Path -LiteralPath $quotaObservationPathValue -PathType Leaf) {
                $budgetMonitor = @(Get-Content -LiteralPath $quotaObservationPathValue -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
            }
        }
        catch {
            $budgetMonitor = @()
        }
    }
    if ($null -ne $closeMonitorWriteFailure) {
        $budgetMonitor += @($closeMonitorWriteFailure)
    }
    $advisorReportPathValue = $AdvisorConsultReportPath
    if ($TaskType -eq 'advisor-consult') {
        if ($null -eq $scopePlan -or $scopePlan.task_type -ne 'advisor-consult') {
            throw 'advisor-consult Inspect 缺少一致的 ScopePlan。'
        }
        if ([string]::IsNullOrWhiteSpace($advisorReportPathValue)) {
            throw 'advisor-consult Inspect 必須提供 AdvisorConsultReportPath。'
        }
        $advisorReportPathValue = Get-AdvisorConsultReportPath -Path $advisorReportPathValue -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug
        $evidencePathValue = $evidencePackInfo.path
        $advisorStatus = if ($executionResult.success) { 'completed' } else { 'failed' }
        $advisorFinalMessage = if ($secretExposure.secret_exposure_suspected) { Protect-DispatchInspectText -Text $finalMessage } else { $finalMessage }
        $advisorReportWrittenPath = Write-AdvisorConsultReport -Path $advisorReportPathValue -ExecutionRoot $ExecutionRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -EvidencePackPath $evidencePathValue -EvidencePackSha256 $evidencePackInfo.sha256 -EvidencePackLength $evidencePackInfo.length -FinalMessage $advisorFinalMessage -Status $advisorStatus -BudgetMonitor $budgetMonitor -RequiredOutputGate $requiredOutputGate -ScopePlan $scopePlan -InterruptionStatus $interruptionStatus
    }

    $inspectConclusionReportPaths = @()
    $inspectReportPathVariable = Get-Variable -Name 'ReportPath' -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $inspectReportPathVariable) {
        $inspectConclusionReportPaths = @($inspectReportPathVariable.Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    $recoverableArtifactState = Get-DispatchRecoverableArtifactState -RunRecord $inspectRun.Record -ConclusionReportPath $inspectConclusionReportPaths
    $result = [ordered]@{
        operation        = 'Inspect'
        status           = 'inspected'
        runId            = $inspectRun.Record.run_id
        runRecordPath    = $inspectRun.Path
        lastMessageConsistency = $lastMessageConsistency
        finalMessageSource = 'event-stream'
        eventStreamPath  = $eventPath
        processExitCode  = [int]$ProcessExitCode
        process_exit_code = [int]$ProcessExitCode
        eventCount       = $events.Count
        lastEventType    = $lastEventType
        terminalEventAvailable = $terminalEventAvailable
        threadId         = $threadId
        completed        = $executionResult.completed
        success          = $executionResult.success
        recoverable_artifacts_present = [bool]$recoverableArtifactState.recoverable_artifacts_present
        recoverable_artifact_files = @($recoverableArtifactState.recoverable_artifact_files)
        turnFailedReason = $executionResult.turnFailedReason
        finalMessage     = $finalMessage
        finalMessageIdentity = $finalMessageIdentity
        outputValid      = $outputValid
        modelEvidence    = $modelEvidence
        reasoningEffortEvidence = $modelEvidence.reasoning_effort
        profile          = [string](Get-DispatchJsonProperty -Object (Get-DispatchJsonProperty -Object $inspectRun.Record -Name 'parent_options') -Name 'profile')
        requiredOutput   = $requiredOutputGate
        usage            = $usage
        eventEvidence   = $eventEvidence
        service_rejection = $serviceRejectionEvidence
        retry_allowed   = if ($null -eq $serviceRejectionEvidence) { $null } else { $false }
        threadIdPath     = $ThreadIdPath
        threadRelay      = $threadRelay
        quotaBeforePath  = $QuotaBeforePath
        quotaBeforeSha256 = $beforeSnapshotSha256Value
        quotaAfterPath   = $afterSnapshotPathValue
        quotaAfterSha256 = $afterSnapshotSha256Value
        quotaCloseSnapshotPath = $closeSnapshotPathValue
        quotaCloseSnapshotSha256 = $closeSnapshotSha256Value
        quotaCloseSnapshotState = $closeSnapshotStateValue
        quotaObservationPath = $quotaObservationPathValue
        quotaObservationWriteFailure = $closeMonitorWriteFailure
        dispatchResultPath = $dispatchResultPathValue
        processExitCodeSource = $processExitCodeSource
        processExitCodeSidecarPath = $processExitCodeSidecarPath
        processExitCodeSidecarSha256 = $processExitCodeSidecarSha256
        afterSnapshot    = if ($null -eq $afterSnapshot) { $null } else { $afterSnapshot.values }
        snapshotFailure  = if ([string]::IsNullOrWhiteSpace($snapshotFailure)) { $null } else { $snapshotFailure }
        scopePlan        = $scopePlan
        interruptionCheckpoint = $interruptionCheckpoint
        interruptionCheckpointSource = [string](Get-OptionalObjectProperty -Object $interruptionCheckpoint -Name 'source')
        advisorConsultReportPath = if ($TaskType -eq 'advisor-consult') { $advisorReportWrittenPath } else { $null }
         diagnosis        = $diagnosis
         stderr           = $inspectStderr
    }
    if ($null -ne $dispatchInspectBinding) {
        $dispatchStatus = if ([bool]$executionResult.success) { 'completed' } else { 'failed' }
        $terminationReason = if ($lastEventType -eq 'turn.failed' -and -not [string]::IsNullOrWhiteSpace([string]$executionResult.turnFailedReason)) {
            'turn.failed: ' + [string]$executionResult.turnFailedReason
        }
        elseif ([int]$ProcessExitCode -ne 0) {
            'process-exit-code: ' + [string][int]$ProcessExitCode
        }
        elseif ($dispatchStatus -eq 'failed' -and $null -ne $diagnosis) {
            [string](Get-DispatchJsonProperty -Object $diagnosis -Name 'observation')
        }
        else {
            [string]$lastEventType
        }
        if ($secretExposure.secret_exposure_suspected) { $terminationReason = Protect-DispatchInspectText -Text $terminationReason }
        $result.status = $dispatchStatus
        $result.dispatchStatus = $dispatchStatus
        $result.terminationReason = $terminationReason
        $result.termination_reason = $terminationReason

        $dispatchDocument = $dispatchInspectBinding.Document
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'status' -Value $dispatchStatus
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'completed_stages' -Value (@((Get-DispatchJsonProperty -Object $dispatchDocument -Name 'completed_stages')) + @('inspect') | Select-Object -Unique)
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'failed_stage' -Value $(if ($dispatchStatus -eq 'failed') { 'inspect' } else { $null })
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'error_code' -Value $(if ($dispatchStatus -eq 'failed') { if ($lastEventType -eq 'turn.failed') { 'CodexTurnFailed' } else { 'DispatchInspectFailed' } } else { $null })
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'error' -Value $(if ($dispatchStatus -eq 'failed') { $terminationReason } else { $null })
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'termination_reason' -Value $terminationReason
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'process_exit_code' -Value ([int]$ProcessExitCode)
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'inspect_status' -Value $dispatchStatus
        Set-DispatchJsonPropertyValue -Object $dispatchDocument -Name 'inspect_success' -Value ([bool]$executionResult.success)
        $null = Write-DispatchAtomicJsonDocument -Path $dispatchInspectBinding.Path -Document $dispatchDocument -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath @($TargetPath)
    }
    return Protect-DispatchInspectResult -Result $result -SecretExposure $secretExposure
}
