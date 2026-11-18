#Requires -Version 7.0

function Assert-DispatchOutputPathNoReparsePoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $resolvedRoot = Normalize-DispatchRootPath -Path $Root
    $resolvedPath = Resolve-AbsolutePath -Path $Path
    if (-not [string]::Equals($resolvedRoot, $resolvedPath, [System.StringComparison]::OrdinalIgnoreCase) -and -not (Test-PathWithinRoot -Path $resolvedPath -Root $resolvedRoot)) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "candidate 不在 root 內：$resolvedPath"
    }
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root 不存在或不是目錄：$resolvedRoot"
    }

    $rootComponent = $resolvedRoot
    while (-not [string]::IsNullOrWhiteSpace($rootComponent)) {
        if (Test-Path -LiteralPath $rootComponent) {
            $componentItem = Get-Item -LiteralPath $rootComponent -Force -ErrorAction Stop
            if (($componentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root path 不可包含 ReparsePoint：$rootComponent"
            }
        }
        $parentComponent = Split-Path -Parent $rootComponent
        if ([string]::Equals($parentComponent, $rootComponent, [StringComparison]::OrdinalIgnoreCase)) { break }
        $rootComponent = $parentComponent
    }
    $currentPath = $resolvedRoot
    $rootItem = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root 不可為 ReparsePoint：$currentPath"
    }

    $relativePath = $resolvedPath.Substring($resolvedRoot.Length).TrimStart([char[]]@('\', '/'))
    foreach ($part in @($relativePath -split '[\\/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $currentPath = Join-Path -Path $currentPath -ChildPath $part
        if (Test-Path -LiteralPath $currentPath) {
            $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "candidate path 不可包含 ReparsePoint：$currentPath"
            }
        }
    }
}
