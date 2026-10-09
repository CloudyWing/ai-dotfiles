function Test-IsWindowsPlatform {
    return [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT
}

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

        [switch]$AllowFailure
    )

    $startInfo = New-ProcessStartInfo -FileName $FileName -WorkingDirectory $WorkingDirectory -Arguments $Arguments -RedirectOutput
    $process = New-Object System.Diagnostics.Process
    $null = ($process.StartInfo = $startInfo)
    try {
        if (-not $process.Start()) {
            throw "無法啟動外部命令：$FileName"
        }

        if ($null -ne $StandardInput) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            $inputBytes = $utf8NoBom.GetBytes($StandardInput)
            $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
            $process.StandardInput.BaseStream.Flush()
        }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
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

        [switch]$AllowFailure
    )

    $gitPath = Get-GitPath
    return Invoke-ExternalCommand -FileName $gitPath -WorkingDirectory $WorkingDirectory -Arguments $Arguments -StandardInput $StandardInput -AllowFailure:$AllowFailure
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
