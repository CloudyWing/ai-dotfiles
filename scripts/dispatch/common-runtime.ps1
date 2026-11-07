function Test-IsWindowsPlatform {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

$script:DispatchGitDefaultTimeoutSeconds = 600

function ConvertTo-FileSystemApiPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-IsWindowsPlatform)) {
        return $Path
    }
    if ($Path.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        return $Path
    }
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($fullPath.StartsWith('\\', [System.StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $fullPath.Substring(2)
    }
    return '\\?\' + $fullPath
}

function Invoke-FileReplaceWithRetry {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$Source,

        [AllowNull()]
        [AllowEmptyString()]
        [object]$Destination,

        [AllowNull()]
        [AllowEmptyString()]
        [object]$BackupPath,

        [ValidateRange(1, 6)]
        [int]$MaxAttempts = 6
    )

    $retryDelaysMilliseconds = @(50, 100, 200, 400, 800)
    $attempt = 0
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $sourceApiPath = if ($null -eq $Source) { [System.Management.Automation.Language.NullString]::Value } elseif ([string]::IsNullOrEmpty([string]$Source)) { [string]$Source } else { ConvertTo-FileSystemApiPath -Path ([string]$Source) }
            $destinationApiPath = if ($null -eq $Destination) { [System.Management.Automation.Language.NullString]::Value } elseif ([string]::IsNullOrEmpty([string]$Destination)) { [string]$Destination } else { ConvertTo-FileSystemApiPath -Path ([string]$Destination) }
            $backupApiPath = if ($null -eq $BackupPath) { [System.Management.Automation.Language.NullString]::Value } elseif ([string]::IsNullOrEmpty([string]$BackupPath)) { [string]$BackupPath } else { ConvertTo-FileSystemApiPath -Path ([string]$BackupPath) }
            if ($null -eq $BackupPath) {
                [System.IO.File]::Replace($sourceApiPath, $destinationApiPath, [System.Management.Automation.Language.NullString]::Value)
            }
            else {
                [System.IO.File]::Replace($sourceApiPath, $destinationApiPath, $backupApiPath)
            }
            return [pscustomobject]@{
                source      = $Source
                destination = $Destination
                backup_path = $BackupPath
                attempts    = $attempt
            }
        }
        catch {
            $originalException = $_.Exception
            $replaceException = $originalException.GetBaseException()
            $hresultHex = ([int]$replaceException.HResult).ToString('X8')
            $isRetryableType = $replaceException -is [System.IO.IOException] -or $replaceException -is [System.UnauthorizedAccessException]
            $isRetryableHResult = $hresultHex -in @('80070497', '80070020', '80070005')
            if ($isRetryableType -and $isRetryableHResult -and $attempt -lt $MaxAttempts) {
                Start-Sleep -Milliseconds $retryDelaysMilliseconds[$attempt - 1]
                continue
            }

            $destinationForMessage = if ($null -eq $Destination) { '<null>' } elseif ([string]::IsNullOrEmpty([string]$Destination)) { '<empty>' } else { [string]$Destination }
            $failureMessage = '{0}; destination={1}; attempts={2}' -f $replaceException.Message, $destinationForMessage, $attempt
            if ($replaceException -is [System.IO.IOException]) {
                $wrappedException = New-Object System.IO.IOException($failureMessage, $originalException)
            }
            elseif ($replaceException -is [System.UnauthorizedAccessException]) {
                $wrappedException = New-Object System.UnauthorizedAccessException($failureMessage, $originalException)
            }
            else {
                $wrappedException = New-Object System.InvalidOperationException($failureMessage, $originalException)
            }
            throw $wrappedException
        }
    }
}

function Resolve-AbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw '路徑不可為空。'
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        throw "路徑必須是絕對路徑：$Path"
    }

    return [System.IO.Path]::GetFullPath($Path)
}

function Normalize-DispatchRootPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $volumeRoot = [System.IO.Path]::GetPathRoot($resolvedPath)
    if ([string]::Equals($resolvedPath, $volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $volumeRoot
    }

    return $resolvedPath.TrimEnd([char[]]@([char]92, [char]47))
}

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $fullRoot = Normalize-DispatchRootPath -Path $Root
    if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $hasTrailingSeparator = $fullRoot.EndsWith([string][char]92, [System.StringComparison]::Ordinal) -or $fullRoot.EndsWith([string][char]47, [System.StringComparison]::Ordinal)
    $rootWithSeparator = if ($hasTrailingSeparator) { $fullRoot } else { $fullRoot + [System.IO.Path]::DirectorySeparatorChar }
    return $fullPath.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-DispatchScriptVariableValue {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $variable = Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $variable) {
        return $null
    }

    return $variable.Value
}

function Resolve-DispatchOutputPathFromContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CandidatePath,

        [string]$SourceRoot,

        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath

    return Resolve-DispatchOutputPath `
        -CandidatePath $CandidatePath `
        -SourceRoot $context.SourceRoot `
        -ExecutionRoot $context.ExecutionRoot `
        -TargetPath $context.TargetPath
}

function Get-DispatchOutputPathContext {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    $sourceRootValue = if ([string]::IsNullOrWhiteSpace($SourceRoot)) { [string](Get-DispatchScriptVariableValue -Name 'SourceRoot') } else { $SourceRoot }
    $executionRootValue = if ([string]::IsNullOrWhiteSpace($ExecutionRoot)) { [string](Get-DispatchScriptVariableValue -Name 'ExecutionRoot') } else { $ExecutionRoot }
    $targetPathValue = if ($null -ne $TargetPath) {
        @($TargetPath)
    }
    else {
        @((Get-DispatchScriptVariableValue -Name 'TargetPath'))
    }

    return [pscustomobject]@{
        SourceRoot = $sourceRootValue
        ExecutionRoot = $executionRootValue
        TargetPath = $targetPathValue
    }
}

function Throw-DispatchOutputFailure {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DispatchOutputRootUnavailable', 'DispatchOutputBoundary', 'DispatchOutputTrackedTarget', 'DispatchOutputTargetCollision')]
        [string]$Code,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $exception = New-Object System.InvalidOperationException(('{0}：{1}' -f $Code, $Message))
    $exception.Data['outputCode'] = $Code
    $exception.Data['errorCode'] = $Code
    throw $exception
}

function New-DispatchOutputDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath,

        [string[]]$AllowedRoot = @()
    )

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $resolvedPath = Resolve-AbsolutePath -Path $Path
    $outputRoots = @(@($context.SourceRoot, $context.ExecutionRoot) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $allowedRoots = @($AllowedRoot | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($outputRoots.Count -eq 0 -and $allowedRoots.Count -eq 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputRootUnavailable' -Message '建立目錄時沒有可驗證的 SourceRoot、ExecutionRoot 或白名單 root。'
    }

    $matchingOutputRoot = $null
    foreach ($rootValue in $outputRoots) {
        if (Test-PathWithinRoot -Path $resolvedPath -Root ([string]$rootValue)) {
            $matchingOutputRoot = [string]$rootValue
            break
        }
    }

    if ($null -ne $matchingOutputRoot) {
        $resolvedPath = Resolve-DispatchOutputPath `
            -CandidatePath $resolvedPath `
            -SourceRoot $context.SourceRoot `
            -ExecutionRoot $context.ExecutionRoot `
            -TargetPath $context.TargetPath
        $verificationRoot = Normalize-DispatchRootPath -Path $matchingOutputRoot
    }
    else {
        $matchingAllowedRoot = $null
        foreach ($rootValue in $allowedRoots) {
            if (Test-PathWithinRoot -Path $resolvedPath -Root ([string]$rootValue)) {
                $matchingAllowedRoot = Resolve-AbsolutePath -Path ([string]$rootValue)
                break
            }
        }
        if ($null -eq $matchingAllowedRoot) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "directory path 不在 SourceRoot、ExecutionRoot 或白名單 root 內：$resolvedPath"
        }

        $resolvedPath = Resolve-DispatchOutputPath -CandidatePath $resolvedPath -SourceRoot '' -ExecutionRoot $matchingAllowedRoot -TargetPath @()
        $verificationRoot = Normalize-DispatchRootPath -Path $matchingAllowedRoot
    }

    Assert-DispatchOutputPathNoReparsePoint -Root $verificationRoot -Path $resolvedPath
    $relativePath = $resolvedPath.Substring($verificationRoot.Length).TrimStart([char[]]@('\', '/'))
    $currentPath = $verificationRoot
    foreach ($part in @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $currentPath = Join-Path -Path $currentPath -ChildPath $part
        Assert-DispatchOutputPathNoReparsePoint -Root $verificationRoot -Path $currentPath
        if (-not (Test-Path -LiteralPath $currentPath -PathType Container)) {
            try {
                $null = New-Item -ItemType Directory -Path $currentPath -ErrorAction Stop
            }
            catch {
                if (-not (Test-Path -LiteralPath $currentPath -PathType Container)) {
                    throw
                }
            }
        }
        Assert-DispatchOutputPathNoReparsePoint -Root $verificationRoot -Path $currentPath
    }

    Assert-DispatchOutputPathNoReparsePoint -Root $verificationRoot -Path $resolvedPath
    return $resolvedPath
}

function Get-RelativePathFromRoot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $fullPath = Resolve-AbsolutePath -Path $Path
    $fullRoot = Normalize-DispatchRootPath -Path $Root
    if (-not (Test-PathWithinRoot -Path $fullPath -Root $fullRoot)) {
        throw "路徑超出根目錄界線：$fullPath；根目錄：$fullRoot"
    }

    if ([string]::Equals($fullPath, $fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }

    $hasTrailingSeparator = $fullRoot.EndsWith([string][char]92, [System.StringComparison]::Ordinal) -or $fullRoot.EndsWith([string][char]47, [System.StringComparison]::Ordinal)
    $rootWithSeparator = if ($hasTrailingSeparator) { $fullRoot } else { $fullRoot + [System.IO.Path]::DirectorySeparatorChar }
    return $fullPath.Substring($rootWithSeparator.Length)
}

function Resolve-SourceTargetPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Root
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        $fullPath = Resolve-AbsolutePath -Path $Path
    }
    else {
        $fullPath = [System.IO.Path]::GetFullPath((Join-Path -Path $Root -ChildPath $Path))
    }

    if (-not (Test-PathWithinRoot -Path $fullPath -Root $Root)) {
        throw "目標路徑超出 sourceRoot：$fullPath"
    }

    return $fullPath
}

function Get-CommandPath {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "找不到命令：$Name"
    }

    $path = $command.Source
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $command.Path
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = $command.Definition
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "無法解析命令的實體路徑：$Name"
    }

    return Resolve-AbsolutePath -Path $path
}

function Test-ProcessStartInfoArgumentList {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo
    )

    return $null -ne $StartInfo.PSObject.Properties['ArgumentList']
}

function ConvertTo-WindowsProcessArgument {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -eq 0) {
        return '""'
    }

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    return '"' + $escaped + '"'
}

function Add-ProcessArguments {
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    if (Test-ProcessStartInfoArgumentList -StartInfo $StartInfo) {
        foreach ($argument in $Arguments) {
            [void]$StartInfo.ArgumentList.Add($argument)
        }
        return
    }

    $StartInfo.Arguments = (($Arguments | ForEach-Object {
                ConvertTo-WindowsProcessArgument -Value $_
            }) -join ' ')
}

function New-ProcessStartInfo {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$RedirectOutput
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    Add-ProcessArguments -StartInfo $startInfo -Arguments $Arguments

    if ($RedirectOutput) {
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
        if ($null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) {
            $startInfo.StandardInputEncoding = $utf8NoBom
        }
        $startInfo.StandardOutputEncoding = $utf8NoBom
        $startInfo.StandardErrorEncoding = $utf8NoBom
    }

    return $startInfo
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [AllowEmptyString()]
        [string]$StandardInput,

        [switch]$AllowFailure,

        [ValidateRange(0, 2147483)]
        [int]$TimeoutSeconds = 0
    )

    $startInfo = New-ProcessStartInfo -FileName $FileName -WorkingDirectory $WorkingDirectory -Arguments $Arguments -RedirectOutput
    $process = New-Object System.Diagnostics.Process
    $null = ($process.StartInfo = $startInfo)
    try {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        if (-not $process.Start()) {
            throw "無法啟動外部命令：$FileName"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        [byte[]]$inputBytes = @()
        $timedOut = $false
        $processExited = $false
        $pipeTimedOut = $false
        if ($null -ne $StandardInput) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $inputBytes = $utf8NoBom.GetBytes($StandardInput)
            try {
                $writeTask = $process.StandardInput.BaseStream.WriteAsync($inputBytes, 0, $inputBytes.Length)
                $remaining = if ($TimeoutSeconds -eq 0) { -1 } else { [int][Math]::Max(0, ($TimeoutSeconds * 1000) - $watch.ElapsedMilliseconds) }
                if (-not $writeTask.Wait($remaining)) { $timedOut = $true }
                if (-not $timedOut) { $process.StandardInput.BaseStream.Flush() }
            }
            catch {
                $writeException = $_.Exception
                while (($writeException -is [System.Management.Automation.MethodInvocationException] -or $writeException -is [System.AggregateException]) -and $null -ne $writeException.InnerException) { $writeException = $writeException.InnerException }
                if ($writeException -isnot [System.IO.IOException]) { throw }
            }
        }
        if (-not $timedOut) {
            try { $process.StandardInput.Close() } catch [System.IO.IOException] { }
            $remaining = if ($TimeoutSeconds -eq 0) { -1 } else { [int][Math]::Max(0, ($TimeoutSeconds * 1000) - $watch.ElapsedMilliseconds) }
            if (-not $process.WaitForExit($remaining)) { $timedOut = $true } else { $processExited = $true }
        }
        if (-not $timedOut -and $TimeoutSeconds -gt 0) {
            $remaining = [int][Math]::Max(0, ($TimeoutSeconds * 1000) - $watch.ElapsedMilliseconds)
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), $remaining)) {
                $timedOut = $true
                $pipeTimedOut = $true
            }
        }
        if ($timedOut) {
            try {
                if (-not $processExited -and -not $process.HasExited) {
                    $killTree = $process.GetType().GetMethod('Kill', [type[]]@([bool]))
                    if ($null -ne $killTree) { $process.Kill($true) } else { $process.Kill() }
                }
            }
            catch [System.InvalidOperationException] { }
            if (-not $processExited) { $null = $process.WaitForExit(5000) }
            $stdout = ''
            $stderr = ''
            try { $null = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 2000) } catch { }
            if ($stdoutTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) { $stdout = [string]$stdoutTask.Result }
            if ($stderrTask.Status -eq [Threading.Tasks.TaskStatus]::RanToCompletion) { $stderr = [string]$stderrTask.Result }
            $tail = if ($stderr.Length -gt 512) { $stderr.Substring($stderr.Length - 512) } else { $stderr }
            $command = (@([IO.Path]::GetFileName($FileName)) + @($Arguments | Select-Object -First 3)) -join ' '
            $timeoutDescription = if ($pipeTimedOut) { '程序已結束，但輸出管線尚未關閉' } else { '已終止該程序' }
            $message = 'DispatchExternalCommandTimeout：外部命令 {0} 於 {1} 秒內未完成，{2}；stdin {3} 位元組、已讀 stdout {4} 字元、stderr {5} 字元；stderr 末段：{6}' -f $command, $TimeoutSeconds, $timeoutDescription, $inputBytes.Length, $stdout.Length, $stderr.Length, $tail
            $timeoutException = New-Object System.TimeoutException($message)
            $timeoutException.Data['errorCode'] = 'DispatchExternalCommandTimeout'
            $timeoutException.Data['timeoutSeconds'] = $TimeoutSeconds
            $timeoutException.Data['elapsedMs'] = $watch.ElapsedMilliseconds
            $timeoutException.Data['command'] = $command
            $timeoutException.Data['stdinBytes'] = $inputBytes.Length
            throw $timeoutException
        }
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout
            StdErr   = $stderr
        }

        if (-not $AllowFailure -and $result.ExitCode -ne 0) {
            throw "外部命令失敗，exit code $($result.ExitCode)：$FileName $($Arguments -join ' ')
$($result.StdErr)"
        }

        return $result
    }
    finally {
        $process.Dispose()
    }
}

function Get-GitPath {
    if (Test-IsWindowsPlatform) {
        return Get-CommandPath -Name 'git.exe'
    }

    return Get-CommandPath -Name 'git'
}

function Invoke-GitCommand {
    param(
        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [AllowEmptyString()]
        [string]$StandardInput,

        [switch]$AllowFailure,

        [int]$TimeoutSeconds
    )

    $gitPath = Get-GitPath
    if (-not $PSBoundParameters.ContainsKey('TimeoutSeconds')) { $TimeoutSeconds = $script:DispatchGitDefaultTimeoutSeconds }
    return Invoke-ExternalCommand -FileName $gitPath -WorkingDirectory $WorkingDirectory -Arguments $Arguments -StandardInput $StandardInput -AllowFailure:$AllowFailure -TimeoutSeconds $TimeoutSeconds
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath
    )

    $context = Get-DispatchOutputPathContext -SourceRoot $SourceRoot -ExecutionRoot $ExecutionRoot -TargetPath $TargetPath
    $writePath = Resolve-DispatchOutputPathFromContext -CandidatePath $Path -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $parent = Split-Path -Parent $writePath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $null = New-DispatchOutputDirectory -Path $parent -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    }
    $writePath = Resolve-DispatchOutputPathFromContext -CandidatePath $writePath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath

    $encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList @($false)
    $fileSystemPath = ConvertTo-FileSystemApiPath -Path $writePath
    $writePath = Resolve-DispatchOutputPathFromContext -CandidatePath $writePath -SourceRoot $context.SourceRoot -ExecutionRoot $context.ExecutionRoot -TargetPath $context.TargetPath
    $fileSystemPath = ConvertTo-FileSystemApiPath -Path $writePath
    [System.IO.File]::WriteAllText($fileSystemPath, $Content, $encoding)
}
