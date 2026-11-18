#Requires -Version 7.0

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
