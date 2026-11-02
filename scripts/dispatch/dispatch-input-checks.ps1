#Requires -Version 5.1

function New-DispatchInputFinding {
    [CmdletBinding()]
    param([string]$CheckId, [string]$Severity, [string]$Code, [string]$Field, [string]$Message, [string]$Expected, [string]$Received, [string]$Source)
    [pscustomobject]@{ check_id = $CheckId; severity = $Severity; code = $Code; field = $Field; message = $Message; expected = $Expected; received = $Received; source = $Source }
}

function Get-DispatchOrderLocation {
    [CmdletBinding()]
    param([string]$SourceRoot, [string]$ExecutionRoot, [string]$LineSlug, [string]$DispatchSlug)
    $name = 'dispatch-order-' + $DispatchSlug + '.md'
    [pscustomobject]@{
        source = Join-Path $SourceRoot ('.local\ai-sessions\handoff\' + $name)
        worktree = Join-Path $ExecutionRoot ('.local\ai-sessions\handoff\' + $LineSlug + '\' + $name)
    }
}

function Test-DispatchOrderRequiresDesign {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$TaskBody, [string]$LineSlug)
    return $TaskBody -match ('(?i)handoff[\\/]' + [regex]::Escape($LineSlug) + '[\\/]design\.md\b')
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

function Invoke-DispatchInputChecks {
    [CmdletBinding()]
    param([ValidateSet('Request', 'Worktree')][string]$Stage, [Parameter(Mandatory)][object]$Context)
    if ($Stage -ne 'Request') { return }
    if (-not (Test-DispatchRequiredIdentifierResolvable -ConfiguredIdentifier ([string]$Context.RequiredIdentifier) -DispatchKind ([string]$Context.DispatchKind) -TaskType ([string]$Context.TaskType) -EvidencePackPath ([string]$Context.EvidencePackPath) -TargetPath @($Context.TargetPath))) {
        New-DispatchInputFinding -CheckId 'DI-IDENT' -Severity 'error' -Code 'DispatchRequestMissingField' -Field 'required_identifier' -Message '無法從 target_path 推導 required_identifier，請提供該欄位。' -Expected 'required_identifier 或具有檔名的 target_path' -Received '' -Source 'request'
    }
    if ($Context.DispatchKind -eq 'resource' -and $null -ne $Context.ResourceOrder -and (Test-DispatchOrderRequiresDesign -TaskBody ([string]$Context.ResourceOrder.TaskBody) -LineSlug ([string]$Context.LineSlug))) {
        $designPath = Join-Path $Context.SourceRoot ('.local\ai-sessions\handoff\' + $Context.LineSlug + '\design.md')
        if (-not (Test-Path -LiteralPath $designPath -PathType Leaf)) {
            New-DispatchInputFinding -CheckId 'DI-DESIGN' -Severity 'error' -Code 'DispatchInputDesignMissing' -Field 'design.md' -Message ('找不到派遣單要求的設計文件：' + $designPath) -Expected $designPath -Received '' -Source ([string]$Context.ResourceOrder.Path)
        }
    }
}

function Assert-DispatchInputFindings {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Findings, [string]$RequestPathValue)
    $errors = @($Findings | Where-Object { $_.severity -eq 'error' })
    if ($errors.Count -gt 0) {
        Throw-DispatchRequestFailure -Code $errors[0].code -Message (($errors | ForEach-Object { $_.message }) -join '；') -RequestPathValue $RequestPathValue -Field $errors[0].field -Detail ([ordered]@{ findings = @($Findings) })
    }
}
