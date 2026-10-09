#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Preflight', 'Prepare', 'Start', 'Inspect', 'Collect', 'QuotaProbe', 'Dispatch', 'Cleanup', 'DiagnoseModelEnvironment')]
    [string]$Operation,

    [string]$SourceRoot,

    [string]$DispatchRoot,

    [string]$ExecutionRoot,

    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$LineSlug,

    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
    [string]$DispatchSlug,

    [string]$CallerSessionId,

    [ValidateSet('readonly', 'write')]
    [string]$WriteMode = 'readonly',

    [string[]]$TargetPath,

    [string]$ResultPath,

    [string]$DispatchResultPath,

    [string]$RequestPath,

    [string]$FailureReceiptPath,

    [string]$PrepareResultPath,

    [string]$PreflightResultPath,

    [string]$CodexPath,

    [string]$PromptPath,

    [ValidateSet('default', 'advisor')]
    [string]$Profile = 'default',

    [ValidateSet('Valid', 'PostResetNoSnapshot', 'SnapshotExpired', 'SnapshotUnavailable', 'ServiceRejected')]
    [string]$InitialQuotaState = 'PostResetNoSnapshot',

    [ValidateSet('primary', 'secondary', 'both', 'unknown')]
    [string]$TriggerWindow = 'unknown',

    [ValidateRange(1, 2)]
    [int]$ProbeAttempt = 1,

    [string]$CodexHome,

    [string]$ThreadId,

    [string]$StartedAtUtc,

    [string]$Model,

    [string]$ReasoningEffort,

    [string]$TaskType = 'unspecified',

    [string]$SessionMode = 'cold-start',

    [ValidateSet('user-explicit')]
    [string]$AdvisorRequestSource,

    [Nullable[double]]$SecondaryDaysToReset,

    [Nullable[double]]$SecondaryRemainingPercent,

    [Alias('DowngradeInstruction')]
    [switch]$InterruptionSafeguard,

    [string]$QuotaBeforePath,

    [string]$QuotaAfterPath,

    [string]$CalibrationPath,

    [string]$ScopePlanPath,

    [switch]$ContinueFromScopePlan,

    [string[]]$RequestedUnit,

    [ValidateSet('workflow-phase', 'resource-target', 'advisor-evidence-question')]
    [string]$UnitKind,

    [ValidateRange(0, 100)]
    [Nullable[double]]$PrimaryBudgetPercent,

    [ValidateRange(0, 100)]
    [Nullable[double]]$PrimaryReservePercent,

    [string]$EvidencePackPath,

    [string]$AdvisorConsultReportPath,

    [ValidateRange(5, 60)]
    [int]$AbortGraceSeconds = 30,

    [string]$BudgetMonitorPath,

    [string[]]$AddDirectory,

    [switch]$Search,

    [string[]]$CodexParentOption,

    [string]$ResumeThreadId,

    [string]$EventStreamPath,

    [string]$StdoutPath,

    [string]$ErrorStreamPath,

    [string]$LastMessagePath,

    [string]$RunRecordPath,

    [string]$ThreadIdPath,

    [string]$PidRecordPath,

    [Parameter(Mandatory = $false)]
    [Nullable[int]]$ProcessExitCode,

    [string]$RequiredIdentifier,

    [switch]$WaitForCompletion,

    [string]$BaseSha,

    [string]$BaselinePath,

    [string]$BaselineSha256,

    [ValidateSet('workflow', 'resource')]
    [string]$DispatchKind,

    [string]$RequirementSummaryPath,

    [AllowEmptyString()]
    [string]$SelectedRequirement,

    [string[]]$ReportPath,

    [string]$ReviewerReportPath,

    [switch]$ApplyCollectedChanges,

    [string[]]$EvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$script:InvocationBoundParameters = [ordered]@{}
foreach ($boundName in $PSBoundParameters.Keys) {
    $script:InvocationBoundParameters[[string]$boundName] = $PSBoundParameters[$boundName]
}
$script:RequestContext = $null
$script:CallerSessionIdentity = $null
$script:DispatchStageBinding = $null
$script:RequestLiteralValues = @()
$script:RequestPrepareArtifacts = @()
$script:RequestManualPrepareArtifacts = @()
$script:RequestAutoPrepareArtifacts = @()
$script:RequestResourceOrder = $null
$script:DispatchWaitForCompletion = $true
$script:WaitForStartProcessExit = $false
$script:ResolvedRequestedUnit = @()
$script:WorkflowCollectContractVersion = 'workflow-collect-v1'
$script:AddDirectoryExplicit = $script:InvocationBoundParameters.Contains('AddDirectory')
$script:SearchExplicit = $script:InvocationBoundParameters.Contains('Search')
$script:CodexParentOptionExplicit = $script:InvocationBoundParameters.Contains('CodexParentOption')
$script:ProfileExplicit = $script:InvocationBoundParameters.Contains('Profile')
$script:DispatchEntryScriptRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'dispatch\common-runtime.ps1')
. (Join-Path $PSScriptRoot 'dispatch\git-baseline.ps1')
. (Join-Path $PSScriptRoot 'dispatch\dispatch-scope.ps1')
. (Join-Path $PSScriptRoot 'dispatch\dispatch-evidence.ps1')
. (Join-Path $PSScriptRoot 'dispatch\quota-observation.ps1')
. (Join-Path $PSScriptRoot 'dispatch\advisor-evidence.ps1')
. (Join-Path $PSScriptRoot 'dispatch\process-identity.ps1')
. (Join-Path $PSScriptRoot 'dispatch\reviewer-contract.ps1')
. (Join-Path $PSScriptRoot 'dispatch\run-recovery.ps1')
. (Join-Path $PSScriptRoot 'dispatch\prepare-stage.ps1')
. (Join-Path $PSScriptRoot 'dispatch\dispatch-lifecycle.ps1')
. (Join-Path $PSScriptRoot 'dispatch\start-lifecycle.ps1')
. (Join-Path $PSScriptRoot 'dispatch\inspect-lifecycle.ps1')
. (Join-Path $PSScriptRoot 'dispatch\collect-contract.ps1')
. (Join-Path $PSScriptRoot 'dispatch\cleanup.ps1')
. (Join-Path $PSScriptRoot 'dispatch\Invoke-DispatchConcurrency.ps1')





































































































































































































































































































































































































































































































































































































































function Write-OperationResult {
    param(
        [Parameter(Mandatory)]
        [System.Collections.IDictionary]$Result
    )

    $json = ConvertTo-Json -InputObject $Result -Depth 12
    if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
        $guardSourceRoot = Get-DispatchScriptVariableValue -Name 'SourceRoot'
        $guardExecutionRoot = Get-DispatchScriptVariableValue -Name 'ExecutionRoot'
        $guardTargetPath = @(Get-DispatchScriptVariableValue -Name 'TargetPath')
        $resolvedResultPath = Resolve-DispatchOutputPath -CandidatePath $ResultPath -SourceRoot ([string]$guardSourceRoot) -ExecutionRoot ([string]$guardExecutionRoot) -TargetPath $guardTargetPath
        $persistResult = $true
        $errorCode = [string](Get-DispatchResultPropertyValue -Object $Result -Names @('errorCode', 'error_code'))
        $prepareResultPath = [string](Get-DispatchResultPropertyValue -Object $Result -Names @('prepareResultPath', 'prepare_result_path'))
        if ($errorCode -ceq 'PrepareResultCollision' -and -not [string]::IsNullOrWhiteSpace($prepareResultPath)) {
            try {
                $resolvedPrepareResultPath = Resolve-AbsolutePath -Path $prepareResultPath
                if ([string]::Equals($resolvedResultPath, $resolvedPrepareResultPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $persistResult = $false
                }
            }
            catch {
                $persistResult = $false
            }
        }
        if ($persistResult) {
            $resolvedResultPath = Resolve-DispatchOutputPath -CandidatePath $resolvedResultPath -SourceRoot ([string]$guardSourceRoot) -ExecutionRoot ([string]$guardExecutionRoot) -TargetPath $guardTargetPath
            Write-Utf8NoBom -Path $resolvedResultPath -Content ($json + "
") -SourceRoot ([string]$guardSourceRoot) -ExecutionRoot ([string]$guardExecutionRoot) -TargetPath $guardTargetPath
        }
    }
    Write-Output $json
}

function Get-DispatchOperationExitCode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Operation,

        [AllowNull()]
        [object]$Result
    )

    if ($Operation -ieq 'Dispatch' -and [string](Get-DispatchResultPropertyValue -Object $Result -Names @('status')) -ceq 'failed') {
        return 1
    }

    if ($Operation -ieq 'Inspect') {
        $nativeExitCode = Get-DispatchResultPropertyValue -Object $Result -Names @('processExitCode', 'process_exit_code')
        if ($null -ne $nativeExitCode) {
            return [int]$nativeExitCode
        }
    }

    return 0
}

try {
    $null = Apply-DispatchRequest
    Assert-DispatchSessionMode
    if ($Operation -in @('Preflight', 'Prepare', 'Start', 'Dispatch', 'Cleanup') -or ($Operation -eq 'Collect' -and $ApplyCollectedChanges) -or ($null -ne $script:RequestContext -and [bool]$script:RequestContext.field_presence.caller_session_id)) {
        $requestCallerSessionId = $null
        $requestCallerSessionIdProvided = $false
        if ($null -ne $script:RequestContext -and [bool]$script:RequestContext.field_presence.caller_session_id) {
            $requestCallerSessionIdProvided = $true
            $requestCallerSessionId = [string]$script:RequestContext.caller_session_id
        }
        $script:CallerSessionIdentity = Get-DispatchCallerSessionIdentity `
            -RequestCallerSessionId $requestCallerSessionId `
            -RequestCallerSessionIdProvided $requestCallerSessionIdProvided `
            -CliCallerSessionId ([string]$CallerSessionId) `
            -CliCallerSessionIdProvided $script:InvocationBoundParameters.Contains('CallerSessionId')
    }
    $result = switch ($Operation) {
        'Preflight' { Invoke-Preflight }
        'Prepare'   { Invoke-Prepare -GuardTargetPath @($TargetPath) }
        'Start'     { Invoke-Start }
        'Inspect'   { Invoke-Inspect }
        'Dispatch'  {
            $dispatchResult = Invoke-Dispatch
            $script:ResultPath = $null
            $dispatchResult
        }
        'Collect'   { Invoke-Collect -ApplyCollectedChanges:$ApplyCollectedChanges }
        'Cleanup'   { Invoke-Cleanup }
        'QuotaProbe' { Invoke-QuotaProbe }
        'DiagnoseModelEnvironment' { Invoke-ModelEnvironmentDiagnostic }
        default     { throw "不支援的 operation：$Operation" }
    }
    if ($null -ne $script:CallerSessionIdentity -and $result -is [System.Collections.IDictionary]) {
        $result.caller_session_fingerprint = [string]$script:CallerSessionIdentity.Fingerprint
        $result.caller_session_source = [string]$script:CallerSessionIdentity.Source
    }
    if ($null -ne $script:RequestContext -and $result -is [System.Collections.IDictionary]) {
        $result.dispatch_request = Get-DispatchRequestEvidence
    }
    $dispatchExitCode = Get-DispatchOperationExitCode -Operation $Operation -Result $result
    Write-OperationResult -Result $result
    exit $dispatchExitCode
}
catch {
    $operationResultProperty = $_.Exception.Data['operationResult']
    if ($null -ne $operationResultProperty -and $operationResultProperty -is [System.Collections.IDictionary]) {
        if ([string](Get-DispatchResultPropertyValue -Object $operationResultProperty -Names @('error_code')) -ceq 'DispatchRequestMissingField' -and [string](Get-DispatchResultPropertyValue -Object $operationResultProperty -Names @('field')) -ceq 'RequestPath') {
            [Console]::Out.WriteLine((ConvertTo-Json -InputObject $operationResultProperty -Depth 100 -Compress))
        }
        else {
            Write-OperationResult -Result $operationResultProperty
        }
    }
    [Console]::Error.WriteLine(('Invoke-CodexDispatch.ps1 失敗：{0}' -f $_.Exception.Message))
    exit 1
}
