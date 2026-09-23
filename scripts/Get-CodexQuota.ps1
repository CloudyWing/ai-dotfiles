#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$CodexHome = $env:CODEX_HOME,

    [string]$SnapshotPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CodexHomeDirectory {
    param(
        [string]$ConfiguredCodexHome
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredCodexHome)) {
        return [System.IO.Path]::GetFullPath($ConfiguredCodexHome)
    }

    $userProfile = [System.Environment]::GetFolderPath(
        [System.Environment+SpecialFolder]::UserProfile
    )
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        throw '無法判定使用者 Profile 路徑，請設定 CODEX_HOME。'
    }

    return (Join-Path -Path $userProfile -ChildPath '.codex')
}



function Get-FileSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        $sha256.Dispose()
    }
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return $null
    }
    foreach ($name in $Names) {
        if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
            if ($null -ne $Object[$name]) {
                return $Object[$name]
            }
            continue
        }
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function Get-QuotaApiField {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return [pscustomobject]@{
            Exists = $false
            Value  = $null
        }
    }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            return [pscustomobject]@{
                Exists = $true
                Value  = $Object[$Name]
            }
        }
        return [pscustomobject]@{
            Exists = $false
            Value  = $null
        }
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return [pscustomobject]@{
            Exists = $false
            Value  = $null
        }
    }

    return [pscustomobject]@{
        Exists = $true
        Value  = $property.Value
    }
}

function Test-QuotaApiObject {
    param(
        [AllowNull()]
        [object]$Value
    )

    return (
        $null -ne $Value -and
        ($Value -is [System.Collections.IDictionary] -or
            $Value -is [System.Management.Automation.PSCustomObject])
    )
}

function Get-QuotaApiValueTypeName {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return 'null'
    }

    return $Value.GetType().Name
}

function Test-QuotaApiNumber {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value -or $Value -is [bool]) {
        return $false
    }

    $typeCode = [System.Type]::GetTypeCode($Value.GetType())
    return $typeCode -in @(
        [System.TypeCode]::SByte,
        [System.TypeCode]::Byte,
        [System.TypeCode]::Int16,
        [System.TypeCode]::UInt16,
        [System.TypeCode]::Int32,
        [System.TypeCode]::UInt32,
        [System.TypeCode]::Int64,
        [System.TypeCode]::UInt64,
        [System.TypeCode]::Single,
        [System.TypeCode]::Double,
        [System.TypeCode]::Decimal
    )
}

function ConvertTo-QuotaApiNumber {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-QuotaApiNumber -Value $Value)) {
        throw ('ResponseFormatFailure; field={0}; expected=Number; actual={1}' -f
            $Path,
            (Get-QuotaApiValueTypeName -Value $Value))
    }

    try {
        $number = [Convert]::ToDouble($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        throw ('ResponseFormatFailure; field={0}; expected=Number; actual={1}' -f
            $Path,
            (Get-QuotaApiValueTypeName -Value $Value))
    }

    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw ('ResponseFormatFailure; field={0}; expected=FiniteNumber; actual={1}' -f
            $Path,
            (Get-QuotaApiValueTypeName -Value $Value))
    }

    return $number
}

function ConvertTo-QuotaApiInteger {
    param(
        [Parameter(Mandatory)]
        [object]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $number = ConvertTo-QuotaApiNumber -Value $Value -Path $Path
    if ([math]::Truncate($number) -ne $number) {
        throw ('ResponseFormatFailure; field={0}; expected=Integer; actual=Number' -f $Path)
    }

    try {
        return [int64]$number
    }
    catch {
        throw ('ResponseRangeFailure; field={0}; category=OutOfRange' -f $Path)
    }
}

function Get-CodexQuotaAuthorizationHeaders {
    param(
        [Parameter(Mandatory)]
        [string]$CodexHomePath
    )

    $authPath = Join-Path -Path $CodexHomePath -ChildPath 'auth.json'
    if (-not (Test-Path -LiteralPath $authPath -PathType Leaf)) {
        throw ('AuthenticationDataUnavailable; path={0}' -f $authPath)
    }

    try {
        $authDocument = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw ('AuthenticationDataInvalid; path={0}' -f $authPath)
    }

    $tokensField = Get-QuotaApiField -Object $authDocument -Name 'tokens'
    if (-not $tokensField.Exists -or -not (Test-QuotaApiObject -Value $tokensField.Value)) {
        throw 'AuthenticationFieldInvalid; field=tokens'
    }

    $accessTokenField = Get-QuotaApiField -Object $tokensField.Value -Name 'access_token'
    if (-not $accessTokenField.Exists -or
        $accessTokenField.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$accessTokenField.Value)) {
        throw 'AuthenticationFieldInvalid; field=tokens.access_token'
    }

    $accountIdField = Get-QuotaApiField -Object $tokensField.Value -Name 'account_id'
    if (-not $accountIdField.Exists -or
        $accountIdField.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$accountIdField.Value)) {
        throw 'AuthenticationFieldInvalid; field=tokens.account_id'
    }

    return @{
        Authorization         = 'Bearer ' + [string]$accessTokenField.Value
        'OpenAI-Beta'         = 'codex-1'
        originator            = 'Codex Desktop'
        'ChatGPT-Account-ID'  = [string]$accountIdField.Value
    }
}

function Get-QuotaApiFailureClassification {
    param(
        [Parameter(Mandatory)]
        [System.Exception]$Exception
    )

    $currentException = $Exception
    while ($null -ne $currentException) {
        $responseField = Get-QuotaApiField -Object $currentException -Name 'Response'
        if ($responseField.Exists -and $null -ne $responseField.Value) {
            $statusField = Get-QuotaApiField -Object $responseField.Value -Name 'StatusCode'
            if ($statusField.Exists -and $null -ne $statusField.Value) {
                try {
                    $statusCode = [int]$statusField.Value
                    if ($statusCode -ge 100 -and $statusCode -le 599) {
                        return [pscustomobject]@{
                            Category   = 'HttpFailure'
                            StatusCode = $statusCode
                        }
                    }
                }
                catch {
                }
            }
        }

        $webStatusField = Get-QuotaApiField -Object $currentException -Name 'Status'
        if ($webStatusField.Exists -and $null -ne $webStatusField.Value) {
            $webStatus = [string]$webStatusField.Value
            if ($webStatus -in @('NameResolutionFailure', 'ProxyNameResolutionFailure')) {
                return [pscustomobject]@{
                    Category   = 'DnsFailure'
                    StatusCode = $null
                }
            }
            if ($webStatus -eq 'Timeout' -or $webStatus -eq 'RequestCanceled') {
                return [pscustomobject]@{
                    Category   = 'Timeout'
                    StatusCode = $null
                }
            }
        }

        if ($currentException -is [System.TimeoutException] -or
            $currentException -is [System.Threading.Tasks.TaskCanceledException]) {
            return [pscustomobject]@{
                Category   = 'Timeout'
                StatusCode = $null
            }
        }

        if ($currentException -is [System.Net.Sockets.SocketException]) {
            $socketError = [string]$currentException.SocketErrorCode
            if ($socketError -in @('HostNotFound', 'TryAgain', 'NoData', 'NoRecovery', 'NonAuthoritativeHost')) {
                return [pscustomobject]@{
                    Category   = 'DnsFailure'
                    StatusCode = $null
                }
            }
        }

        $currentException = $currentException.InnerException
    }

    return [pscustomobject]@{
        Category   = 'ConnectionFailure'
        StatusCode = $null
    }
}

function Get-QuotaApiResponse {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Headers,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds
    )

    $endpoint = 'https://chatgpt.com/backend-api/wham/usage'
    try {
        $httpResponse = Invoke-WebRequest -Uri $endpoint -Method Get -Headers $Headers -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $failure = Get-QuotaApiFailureClassification -Exception $_.Exception
        if ($failure.Category -eq 'HttpFailure') {
            throw ('QuotaApiFailure; category=HttpFailure; status={0}' -f $failure.StatusCode)
        }
        if ($failure.Category -eq 'DnsFailure') {
            throw ('QuotaApiFailure; category=DnsFailure; host=chatgpt.com')
        }
        if ($failure.Category -eq 'Timeout') {
            throw ('QuotaApiFailure; category=Timeout; timeout_seconds={0}' -f $TimeoutSeconds)
        }
        throw 'QuotaApiFailure; category=ConnectionFailure; host=chatgpt.com'
    }

    $statusField = Get-QuotaApiField -Object $httpResponse -Name 'StatusCode'
    if ($statusField.Exists -and $null -ne $statusField.Value) {
        try {
            $statusCode = [int]$statusField.Value
            if ($statusCode -lt 200 -or $statusCode -ge 300) {
                throw ('QuotaApiFailure; category=HttpFailure; status={0}' -f $statusCode)
            }
        }
        catch {
            if ($_.Exception.Message -like 'QuotaApiFailure;*') {
                throw
            }
            throw 'QuotaApiFailure; category=HttpFailure; status=unknown'
        }
    }

    $contentField = Get-QuotaApiField -Object $httpResponse -Name 'Content'
    if (-not $contentField.Exists -or $contentField.Value -isnot [string]) {
        throw 'ResponseFormatFailure; field=response; expected=JSON'
    }

    try {
        $parsedResponse = [string]$contentField.Value | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw 'ResponseFormatFailure; field=response; category=InvalidJson'
    }

    if (-not (Test-QuotaApiObject -Value $parsedResponse)) {
        throw ('ResponseFormatFailure; field=response; expected=Object; actual={0}' -f
            (Get-QuotaApiValueTypeName -Value $parsedResponse))
    }

    return [pscustomobject]@{
        Body       = [string]$contentField.Value
        ParsedBody = $parsedResponse
        Endpoint   = $endpoint
    }
}

function ConvertFrom-QuotaApiWindow {
    param(
        [Parameter(Mandatory)]
        [object]$RateLimit,

        [Parameter(Mandatory)]
        [string]$WindowName,

        [Parameter(Mandatory)]
        [string]$SourceFile,

        [Parameter(Mandatory)]
        [DateTimeOffset]$ObservedAtUtc
    )

    $windowPath = 'rate_limit.{0}_window' -f $WindowName
    $windowField = Get-QuotaApiField -Object $RateLimit -Name ($WindowName + '_window')
    if (-not $windowField.Exists -or -not (Test-QuotaApiObject -Value $windowField.Value)) {
        throw ('ResponseFormatFailure; field={0}; expected=Object; actual={1}' -f
            $windowPath,
            (Get-QuotaApiValueTypeName -Value $windowField.Value))
    }

    $requiredFields = @('used_percent', 'limit_window_seconds', 'reset_after_seconds', 'reset_at')
    $values = @{}
    foreach ($fieldName in $requiredFields) {
        $field = Get-QuotaApiField -Object $windowField.Value -Name $fieldName
        $fieldPath = $windowPath + '.' + $fieldName
        if (-not $field.Exists) {
            throw ('ResponseFormatFailure; field={0}; category=Missing' -f $fieldPath)
        }
        if ($null -eq $field.Value) {
            throw ('ResponseFormatFailure; field={0}; category=Null' -f $fieldPath)
        }
        $values[$fieldName] = $field.Value
    }

    $usedPercent = ConvertTo-QuotaApiNumber -Value $values['used_percent'] -Path ($windowPath + '.used_percent')
    if ($usedPercent -lt 0 -or $usedPercent -gt 100) {
        throw ('ResponseRangeFailure; field={0}.used_percent; category=OutOfRange; value={1}' -f
            $windowPath,
            (Format-InvariantNumber -Value $usedPercent))
    }

    $limitWindowSeconds = ConvertTo-QuotaApiInteger -Value $values['limit_window_seconds'] -Path ($windowPath + '.limit_window_seconds')
    if ($limitWindowSeconds -le 0 -or ($limitWindowSeconds % 60) -ne 0) {
        throw ('ResponseRangeFailure; field={0}.limit_window_seconds; category=UnsupportedRange' -f $windowPath)
    }

    $resetAfterSeconds = ConvertTo-QuotaApiNumber -Value $values['reset_after_seconds'] -Path ($windowPath + '.reset_after_seconds')
    if ($resetAfterSeconds -lt 0) {
        throw ('ResponseRangeFailure; field={0}.reset_after_seconds; category=OutOfRange' -f $windowPath)
    }

    $resetsAt = ConvertTo-QuotaApiInteger -Value $values['reset_at'] -Path ($windowPath + '.reset_at')
    if ($resetsAt -le 0) {
        throw ('ResponseRangeFailure; field={0}.reset_at; category=OutOfRange' -f $windowPath)
    }
    try {
        $null = [DateTimeOffset]::FromUnixTimeSeconds($resetsAt)
    }
    catch {
        throw ('ResponseRangeFailure; field={0}.reset_at; category=OutOfRange' -f $windowPath)
    }

    return [pscustomobject]@{
        WindowName         = $WindowName
        UsedPercent        = $usedPercent
        RemainingPercent   = 100.0 - $usedPercent
        WindowMinutes      = [int64]($limitWindowSeconds / 60)
        ResetsAt           = $resetsAt
        DaysToReset        = $resetAfterSeconds / 86400.0
        SourceFile         = $SourceFile
        EventTimestamp     = $ObservedAtUtc
        EventTimestampUnix = $ObservedAtUtc.ToUnixTimeSeconds()
        RecordIndex        = 0
    }
}

function ConvertFrom-QuotaApiResponse {
    param(
        [Parameter(Mandatory)]
        [object]$Response,

        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [string]$ResponseSha256,

        [Parameter(Mandatory)]
        [DateTimeOffset]$ObservedAtUtc
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $rateLimitField = Get-QuotaApiField -Object $Response -Name 'rate_limit'
    $rateLimit = $null
    if (-not $rateLimitField.Exists -or -not (Test-QuotaApiObject -Value $rateLimitField.Value)) {
        $errors.Add('ResponseFormatFailure; field=rate_limit; expected=Object')
    }
    else {
        $rateLimit = $rateLimitField.Value
    }

    $allowedKnown = $false
    $allowedValue = $null
    $limitReachedKnown = $false
    $limitReachedValue = $null
    $rateLimitReachedType = $null
    $spendControlReachedKnown = $false
    $spendControlReachedValue = $null
    $spendReachedField = [pscustomobject]@{
        Exists = $false
        Value  = $null
    }

    $allowedField = Get-QuotaApiField -Object $rateLimit -Name 'allowed'
    if (-not $allowedField.Exists -or $null -eq $allowedField.Value) {
        $errors.Add('ResponseFormatFailure; field=rate_limit.allowed; category=MissingOrNull')
    }
    elseif ($allowedField.Value -isnot [bool]) {
        $errors.Add(('ResponseFormatFailure; field=rate_limit.allowed; expected=Boolean; actual={0}' -f
            (Get-QuotaApiValueTypeName -Value $allowedField.Value)))
    }
    else {
        $allowedKnown = $true
        $allowedValue = [bool]$allowedField.Value
    }

    $limitReachedField = Get-QuotaApiField -Object $rateLimit -Name 'limit_reached'
    if (-not $limitReachedField.Exists -or $null -eq $limitReachedField.Value) {
        $errors.Add('ResponseFormatFailure; field=rate_limit.limit_reached; category=MissingOrNull')
    }
    elseif ($limitReachedField.Value -isnot [bool]) {
        $errors.Add(('ResponseFormatFailure; field=rate_limit.limit_reached; expected=Boolean; actual={0}' -f
            (Get-QuotaApiValueTypeName -Value $limitReachedField.Value)))
    }
    else {
        $limitReachedKnown = $true
        $limitReachedValue = [bool]$limitReachedField.Value
    }

    $reachedTypeField = Get-QuotaApiField -Object $rateLimit -Name 'rate_limit_reached_type'
    if ($reachedTypeField.Exists -and $null -ne $reachedTypeField.Value) {
        if ($reachedTypeField.Value -isnot [string]) {
            $errors.Add(('ResponseFormatFailure; field=rate_limit.rate_limit_reached_type; expected=String; actual={0}' -f
                (Get-QuotaApiValueTypeName -Value $reachedTypeField.Value)))
        }
        else {
            $rateLimitReachedType = [string]$reachedTypeField.Value
        }
    }

    $spendControlField = Get-QuotaApiField -Object $Response -Name 'spend_control'
    if ($spendControlField.Exists -and $null -ne $spendControlField.Value) {
        if (-not (Test-QuotaApiObject -Value $spendControlField.Value)) {
            $errors.Add(('ResponseFormatFailure; field=spend_control; expected=Object; actual={0}' -f
                (Get-QuotaApiValueTypeName -Value $spendControlField.Value)))
        }
        else {
            $spendReachedField = Get-QuotaApiField -Object $spendControlField.Value -Name 'reached'
            if ($spendReachedField.Exists -and $null -ne $spendReachedField.Value) {
                if ($spendReachedField.Value -isnot [bool]) {
                    $errors.Add(('ResponseFormatFailure; field=spend_control.reached; expected=Boolean; actual={0}' -f
                        (Get-QuotaApiValueTypeName -Value $spendReachedField.Value)))
                }
                else {
                    $spendControlReachedKnown = $true
                    $spendControlReachedValue = [bool]$spendReachedField.Value
                }
            }
        }
    }

    if (-not $spendControlReachedKnown -and
        ($null -eq $spendControlField.Value -or -not $spendControlField.Exists -or (Test-QuotaApiObject -Value $spendControlField.Value))) {
        if (-not $spendControlField.Exists -or
            ($null -ne $spendControlField.Value -and (Test-QuotaApiObject -Value $spendControlField.Value) -and -not $spendReachedField.Exists)) {
            $errors.Add('ResponseStateFailure; field=spend_control.reached; category=Missing')
        }
        else {
            $errors.Add('ResponseStateFailure; field=spend_control.reached; category=Null')
        }
    }

    if ($limitReachedKnown -and $limitReachedValue -and
        (-not $reachedTypeField.Exists -or
            $null -eq $reachedTypeField.Value -or
            [string]::IsNullOrWhiteSpace($rateLimitReachedType))) {
        $errors.Add('ResponseFormatFailure; field=rate_limit.rate_limit_reached_type; category=RequiredWhenLimitReached')
    }
    if ($limitReachedKnown -and -not $limitReachedValue -and
        $null -ne $rateLimitReachedType -and
        -not [string]::IsNullOrWhiteSpace($rateLimitReachedType)) {
        $errors.Add('ResponseStateFailure; field=rate_limit.rate_limit_reached_type; category=ContradictorySignal')
    }

    $serviceRejected = (
        ($allowedKnown -and -not $allowedValue) -or
        ($limitReachedKnown -and $limitReachedValue) -or
        ($spendControlReachedKnown -and $spendControlReachedValue)
    )

    $observedAtText = $ObservedAtUtc.ToUniversalTime().ToString('o')
    $sourceFile = $Endpoint + ' requested_at_utc=' + $observedAtText
    $windowResults = @{}
    if ($null -ne $rateLimit) {
        foreach ($windowName in @('primary', 'secondary')) {
            try {
                $windowResults[$windowName] = ConvertFrom-QuotaApiWindow -RateLimit $rateLimit -WindowName $windowName -SourceFile $sourceFile -ObservedAtUtc $ObservedAtUtc
            }
            catch {
                $errors.Add($_.Exception.Message)
            }
        }
    }

    $spendControlEvidence = $null
    if ($spendControlField.Exists -and (Test-QuotaApiObject -Value $spendControlField.Value)) {
        $spendEvidenceField = Get-QuotaApiField -Object $spendControlField.Value -Name 'reached'
        if ($spendEvidenceField.Exists) {
            $spendControlEvidence = $spendEvidenceField.Value
        }
    }

    $signalEvidence = [ordered]@{
        api_endpoint            = $Endpoint
        observed_at_utc         = $observedAtText
        response_sha256         = $ResponseSha256
        allowed                 = if ($allowedField.Exists) { $allowedField.Value } else { $null }
        limit_reached           = if ($limitReachedField.Exists) { $limitReachedField.Value } else { $null }
        rate_limit_reached_type = if ($reachedTypeField.Exists) { $reachedTypeField.Value } else { $null }
        spend_control_reached   = $spendControlEvidence
    }

    $serviceRejection = $null
    $serviceRejectionEvidence = $null
    if ($serviceRejected) {
        $reasonCode = 'service-rejection'
        if ($allowedKnown -and -not $allowedValue) {
            $reasonCode = 'not-allowed'
        }
        elseif ($limitReachedKnown -and $limitReachedValue) {
            $reasonCode = 'limit-reached'
        }
        elseif ($spendControlReachedKnown -and $spendControlReachedValue) {
            $reasonCode = 'spend-control'
        }

        $rejectionWindow = 'unknown'
        if ($rateLimitReachedType -match '(?i)primary') {
            $rejectionWindow = 'primary'
        }
        elseif ($rateLimitReachedType -match '(?i)secondary') {
            $rejectionWindow = 'secondary'
        }
        $rejectionResetAt = $null
        if ($rejectionWindow -in @('primary', 'secondary') -and $null -ne $windowResults[$rejectionWindow]) {
            $rejectionResetAt = [int64]$windowResults[$rejectionWindow].ResetsAt
        }

        $serviceRejection = [ordered]@{
            status              = 'quota-rejected'
            window              = $rejectionWindow
            reason_code         = $reasonCode
            observed_at_utc     = $observedAtText
            raw_evidence_path   = $Endpoint
            raw_evidence_sha256 = $ResponseSha256
            resets_at           = $rejectionResetAt
            retry_allowed       = $false
        }
        $serviceRejectionEvidence = $signalEvidence
    }

    if ($serviceRejected) {
        $errorMessage = 'QuotaApiServiceRejected; ' + ($errors -join '; ')
        if ([string]::IsNullOrWhiteSpace(($errors -join ''))) {
            $errorMessage = 'QuotaApiServiceRejected; refusal flags are present.'
        }
        return [pscustomobject]@{
            State                    = 'ServiceRejected'
            ErrorMessage             = $errorMessage
            Primary                  = $null
            Secondary                = $null
            Observations             = $null
            ServiceRejection         = $serviceRejection
            ServiceRejectionEvidence = $serviceRejectionEvidence
            CapturedAtUtc            = $null
        }
    }

    if ($errors.Count -gt 0 -or
        -not $allowedKnown -or -not $allowedValue -or
        -not $limitReachedKnown -or $limitReachedValue -or
        -not $spendControlReachedKnown -or $spendControlReachedValue) {
        return [pscustomobject]@{
            State                    = 'SnapshotUnavailable'
            ErrorMessage             = 'QuotaApiResponseInvalid; ' + ($errors -join '; ')
            Primary                  = $null
            Secondary                = $null
            Observations             = $null
            ServiceRejection         = $null
            ServiceRejectionEvidence = $null
            CapturedAtUtc            = $null
        }
    }

    if ($null -eq $windowResults['primary'] -or $null -eq $windowResults['secondary']) {
        return [pscustomobject]@{
            State                    = 'SnapshotUnavailable'
            ErrorMessage             = 'QuotaApiResponseInvalid; both primary_window and secondary_window are required.'
            Primary                  = $null
            Secondary                = $null
            Observations             = $null
            ServiceRejection         = $null
            ServiceRejectionEvidence = $null
            CapturedAtUtc            = $null
        }
    }

    $observations = [ordered]@{
        primary   = New-QuotaObservation -WindowName 'primary' -Candidate $windowResults['primary']
        secondary = New-QuotaObservation -WindowName 'secondary' -Candidate $windowResults['secondary']
    }

    return [pscustomobject]@{
        State                    = 'Valid'
        ErrorMessage             = $null
        Primary                  = $windowResults['primary']
        Secondary                = $windowResults['secondary']
        Observations             = $observations
        ServiceRejection         = $null
        ServiceRejectionEvidence = $null
        CapturedAtUtc            = $observedAtText
    }
}

function Get-StringSha256 {
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-QuotaApiSnapshotDocument {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$State,

        [AllowNull()]
        [string]$CapturedAtUtc,

        [AllowNull()]
        [object]$Primary,

        [AllowNull()]
        [object]$Secondary,

        [AllowNull()]
        [object]$Observations,

        [AllowNull()]
        [object]$ServiceRejection,

        [AllowNull()]
        [object]$ServiceRejectionEvidence,

        [AllowNull()]
        [string]$ErrorMessage,

        [AllowNull()]
        [string]$CodexHomePath
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        throw ('QuotaSnapshotTargetAlreadyExists; path={0}' -f $Path)
    }

    $document = [ordered]@{
        schema                     = 'ai-sessions.quota-snapshot.v1'
        captured_at_utc            = $CapturedAtUtc
        state                      = $State
        primary                    = $null
        secondary                  = $null
        observations               = $Observations
        service_rejection          = $ServiceRejection
        service_rejection_evidence = $ServiceRejectionEvidence
        error                      = $ErrorMessage
        codex_home                 = $CodexHomePath
    }

    foreach ($window in @(
            [pscustomobject]@{ Name = 'primary'; Value = $Primary }
            [pscustomobject]@{ Name = 'secondary'; Value = $Secondary }
        )) {
        if ($null -eq $window.Value) {
            continue
        }

        $document[$window.Name] = [ordered]@{
            used_percent      = [double]$window.Value.UsedPercent
            remaining_percent = [double]$window.Value.RemainingPercent
            window_minutes    = [int64]$window.Value.WindowMinutes
            resets_at         = [int64]$window.Value.ResetsAt
            source_file       = [string]$window.Value.SourceFile
            days_to_reset     = [double]$window.Value.DaysToReset
            window_days       = [double]$window.Value.WindowMinutes / 1440.0
        }
    }

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    $content = ($document | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    $bytes = $encoding.GetBytes($content)
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}



function Get-ObservationFreshness {
    param(
        [Parameter(Mandatory)]
        [DateTimeOffset]$ObservedAtUtc,

        [int]$MaxAgeMinutes = 30
    )

    $ageMinutes = ([DateTimeOffset]::UtcNow - $ObservedAtUtc).TotalMinutes
    if ($ageMinutes -ge 0 -and $ageMinutes -le $MaxAgeMinutes) {
        return 'fresh'
    }
    if ($ageMinutes -gt $MaxAgeMinutes) {
        return 'stale'
    }
    return 'unknown'
}

function New-QuotaObservation {
    param(
        [Parameter(Mandatory)]
        [string]$WindowName,

        [Parameter(Mandatory)]
        [pscustomobject]$Candidate
    )

    return [ordered]@{
        used_percent      = [double]$Candidate.UsedPercent
        remaining_percent = 100.0 - [double]$Candidate.UsedPercent
        observed_at_utc   = $Candidate.EventTimestamp.ToUniversalTime().ToString('o')
        source            = [string]$Candidate.SourceFile
        freshness         = Get-ObservationFreshness -ObservedAtUtc $Candidate.EventTimestamp.ToUniversalTime()
        window            = $WindowName
        resets_at         = [int64]$Candidate.ResetsAt
    }
}

function ConvertTo-ServiceRejectionDocumentValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ServiceRejection,

        [switch]$IncludeAudit
    )

    if ($null -eq $ServiceRejection) {
        return $null
    }

    $rawEvidencePath = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_path', 'RawEvidencePath'))
    $rawEvidenceFile = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_file', 'RawEvidenceFileName'))
    if ([string]::IsNullOrWhiteSpace($rawEvidenceFile) -and -not [string]::IsNullOrWhiteSpace($rawEvidencePath)) {
        $rawEvidenceFile = Split-Path -Leaf $rawEvidencePath
    }

    $observedAtValue = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('observed_at_utc', 'ObservedAtUtc')
    $observedAtText = if ($null -eq $observedAtValue) { '' } else { [string]$observedAtValue }
    try {
        $observedAtText = ([DateTimeOffset]$observedAtValue).ToUniversalTime().ToString('o')
    }
    catch {
    }

    $document = [ordered]@{
        status              = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('status', 'Status'))
        window              = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('window', 'Window'))
        reason_code         = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('reason_code', 'ReasonCode'))
        observed_at_utc     = $observedAtText
        raw_evidence_path   = $rawEvidencePath
        raw_evidence_sha256 = [string](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('raw_evidence_sha256', 'RawEvidenceSha256'))
        resets_at           = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('resets_at', 'ResetsAt')
        retry_allowed       = [bool](Get-ObjectPropertyValue -Object $ServiceRejection -Names @('retry_allowed', 'RetryAllowed'))
    }

    if ($IncludeAudit) {
        $supersededValue = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('superseded')
        $supersededByValue = Get-ObjectPropertyValue -Object $ServiceRejection -Names @('superseded_by_observation')
        $supersededByDocument = $null
        if ($null -ne $supersededByValue) {
            $supersededObservedAtValue = Get-ObjectPropertyValue -Object $supersededByValue -Names @('observed_at_utc')
            $supersededObservedAtText = if ($null -eq $supersededObservedAtValue) { $null } else { [string]$supersededObservedAtValue }
            try {
                $supersededObservedAtText = ([DateTimeOffset]$supersededObservedAtValue).ToUniversalTime().ToString('o')
            }
            catch {
            }
            $recordIndexValue = Get-ObjectPropertyValue -Object $supersededByValue -Names @('record_index')
            $supersededByDocument = [ordered]@{
                window          = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('window'))
                observed_at_utc = $supersededObservedAtText
                source_file     = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('source_file'))
                source_path     = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('source_path'))
                freshness       = [string](Get-ObjectPropertyValue -Object $supersededByValue -Names @('freshness'))
                record_index    = if ($null -eq $recordIndexValue) { $null } else { [int64]$recordIndexValue }
            }
        }
        $document['raw_evidence_file'] = $rawEvidenceFile
        $document['superseded'] = if ($null -eq $supersededValue) { $false } else { [bool]$supersededValue }
        $document['superseded_by_observation'] = $supersededByDocument
    }

    return $document
}



function New-UnknownQuotaObservation {
    param(
        [Parameter(Mandatory)]
        [string]$WindowName,

        [AllowNull()]
        [object]$Window
    )

    if ($null -eq $Window) {
        return [ordered]@{
            used_percent      = $null
            remaining_percent = $null
            observed_at_utc   = $null
            source            = 'snapshot-unavailable'
            freshness         = 'unknown'
            window            = $WindowName
            resets_at         = $null
        }
    }
    return [ordered]@{
        used_percent      = [double]$Window.used_percent
        remaining_percent = [double]$Window.remaining_percent
        observed_at_utc   = $null
        source            = [string]$Window.source_file
        freshness         = 'unknown'
        window            = $WindowName
        resets_at         = [int64]$Window.resets_at
    }
}



function Format-InvariantNumber {
    param(
        [Parameter(Mandatory)]
        [double]$Value
    )

    return $Value.ToString('0.########', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-InvariantInteger {
    param(
        [Parameter(Mandatory)]
        [int64]$Value
    )

    return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

function Write-QuotaWindow {
    param(
        [Parameter(Mandatory)]
        [string]$WindowName,

        [Parameter(Mandatory)]
        [pscustomobject]$Snapshot,

        [Parameter(Mandatory)]
        [int64]$CurrentUnixTime
    )

    $prefix = $WindowName + '_'
    $remainingPercent = 100.0 - [double]$Snapshot.UsedPercent
    $daysToReset = if ($null -ne $Snapshot.PSObject.Properties['DaysToReset']) {
        [double]$Snapshot.DaysToReset
    }
    else {
        ([double]$Snapshot.ResetsAt - [double]$CurrentUnixTime) / 86400.0
    }
    $windowDays = [double]$Snapshot.WindowMinutes / 1440.0
    $resetsAtLocal = [DateTimeOffset]::FromUnixTimeSeconds([long]$Snapshot.ResetsAt).ToLocalTime().ToString(
        'yyyy-MM-dd HH:mm',
        [System.Globalization.CultureInfo]::InvariantCulture
    )

    Write-Output ($prefix + 'used_percent=' + (Format-InvariantNumber -Value $Snapshot.UsedPercent))
    Write-Output ($prefix + 'remaining_percent=' + (Format-InvariantNumber -Value $remainingPercent))
    Write-Output ($prefix + 'days_to_reset=' + (Format-InvariantNumber -Value $daysToReset))
    Write-Output ($prefix + 'window_minutes=' + (Format-InvariantInteger -Value $Snapshot.WindowMinutes))
    Write-Output ($prefix + 'window_days=' + (Format-InvariantNumber -Value $windowDays))
    Write-Output ($prefix + 'resets_at=' + (Format-InvariantInteger -Value $Snapshot.ResetsAt))
    Write-Output ($prefix + 'resets_at_local=' + $resetsAtLocal)
    Write-Output ($prefix + 'source_file=' + $Snapshot.SourceFile)
}





$quotaState = 'SnapshotUnavailable'
$quotaModel = $null
$codexHomePath = $null
$serviceRejection = $null
$serviceRejectionEvidence = $null
$quotaApiError = $null

try {
    $codexHomePath = Get-CodexHomeDirectory -ConfiguredCodexHome $CodexHome
    $headers = Get-CodexQuotaAuthorizationHeaders -CodexHomePath $codexHomePath
    $quotaObservedAtUtc = [DateTimeOffset]::UtcNow
    $currentUnixTime = $quotaObservedAtUtc.ToUnixTimeSeconds()
    $apiResponse = Get-QuotaApiResponse -Headers $headers -TimeoutSeconds 30
    $responseSha256 = Get-StringSha256 -Value $apiResponse.Body
    $quotaModel = ConvertFrom-QuotaApiResponse -Response $apiResponse.ParsedBody -Endpoint $apiResponse.Endpoint -ResponseSha256 $responseSha256 -ObservedAtUtc $quotaObservedAtUtc
    $quotaState = [string]$quotaModel.State
    $serviceRejection = $quotaModel.ServiceRejection
    $serviceRejectionEvidence = $quotaModel.ServiceRejectionEvidence

    if ($quotaState -ne 'Valid') {
        throw [string]$quotaModel.ErrorMessage
    }

    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        Write-QuotaApiSnapshotDocument -Path ([System.IO.Path]::GetFullPath($SnapshotPath)) -State 'Valid' -CapturedAtUtc $quotaModel.CapturedAtUtc -Primary $quotaModel.Primary -Secondary $quotaModel.Secondary -Observations $quotaModel.Observations -ServiceRejection $null -ServiceRejectionEvidence $null -ErrorMessage $null -CodexHomePath $codexHomePath
    }

    Write-QuotaWindow -WindowName 'primary' -Snapshot $quotaModel.Primary -CurrentUnixTime $currentUnixTime
    Write-QuotaWindow -WindowName 'secondary' -Snapshot $quotaModel.Secondary -CurrentUnixTime $currentUnixTime
    exit 0
}
catch {
    $quotaApiError = $_.Exception.Message
    if ($quotaState -eq 'Valid') {
        $quotaState = 'SnapshotUnavailable'
        $serviceRejection = $null
        $serviceRejectionEvidence = $null
    }

    if ($null -ne $quotaModel -and $quotaState -ne 'Valid') {
        $quotaApiError = [string]$quotaModel.ErrorMessage
        $serviceRejection = $quotaModel.ServiceRejection
        $serviceRejectionEvidence = $quotaModel.ServiceRejectionEvidence
    }

    if (-not [string]::IsNullOrWhiteSpace($SnapshotPath)) {
        try {
            Write-QuotaApiSnapshotDocument -Path ([System.IO.Path]::GetFullPath($SnapshotPath)) -State $quotaState -CapturedAtUtc $null -Primary $null -Secondary $null -Observations $null -ServiceRejection $serviceRejection -ServiceRejectionEvidence $serviceRejectionEvidence -ErrorMessage $quotaApiError -CodexHomePath $codexHomePath
        }
        catch {
            [Console]::Error.WriteLine(('quota snapshot 寫入失敗：{0}' -f $_.Exception.Message))
        }
    }
    [Console]::Error.WriteLine(('Get-CodexQuota.ps1 失敗：{0}' -f $quotaApiError))
    exit 1
}
