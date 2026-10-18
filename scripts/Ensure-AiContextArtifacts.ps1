[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectRoot,

    [Parameter(Mandatory)]
    [ValidateSet('Export-ApiSurface', 'Export-TypeHierarchy', 'Export-ProjectGraph', 'graphify')]
    [string]$ToolName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Get-Sha256Text {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [System.Convert]::ToHexString($sha256.ComputeHash($Bytes)).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Sha256Text -Bytes ([System.IO.File]::ReadAllBytes($Path))
}

function Get-RelativeSlashPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )

    $relativePath = [System.IO.Path]::GetRelativePath($Root, $Path)
    return $relativePath.Replace([System.IO.Path]::DirectorySeparatorChar, '/')
}

function Test-ExcludedSourceFileName {
    param([Parameter(Mandatory)][string]$Path)

    $fileName = [System.IO.Path]::GetFileName($Path)
    $extension = [System.IO.Path]::GetExtension($fileName)
    return $fileName -ieq '.env' -or
        $fileName.StartsWith('.env.', [System.StringComparison]::OrdinalIgnoreCase) -or
        $extension -ieq '.pfx' -or
        $extension -ieq '.pem' -or
        $extension -ieq '.key' -or
        $fileName.StartsWith('secrets.', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-SolutionFile {
    param([Parameter(Mandatory)][string]$Root)

    $solutions = @(
        [System.IO.Directory]::EnumerateFiles($Root, '*', [System.IO.SearchOption]::TopDirectoryOnly) |
            Where-Object {
                $extension = [System.IO.Path]::GetExtension($_)
                $extension -ieq '.sln' -or $extension -ieq '.slnx'
            } |
            Sort-Object
    )
    if ($solutions.Count -ne 1) {
        throw "ProjectRoot 必須在根目錄包含唯一一個 .sln 或 .slnx；實際數量：$($solutions.Count)"
    }

    return [string]$solutions[0]
}

function Get-SolutionProjectPaths {
    param([Parameter(Mandatory)][string]$SolutionPath)

    $solutionDirectory = [System.IO.Path]::GetDirectoryName($SolutionPath)
    $projectPaths = [System.Collections.Generic.List[string]]::new()
    if ([System.IO.Path]::GetExtension($SolutionPath) -ieq '.slnx') {
        $document = [System.Xml.Linq.XDocument]::Load($SolutionPath)
        foreach ($element in $document.Descendants()) {
            if ($element.Name.LocalName -ine 'Project') {
                continue
            }

            $pathAttribute = $element.Attributes() |
                Where-Object { $_.Name.LocalName -ieq 'Path' } |
                Select-Object -First 1
            if ($null -eq $pathAttribute) {
                continue
            }

            $relativePath = ([string]$pathAttribute.Value).Replace(
                '\',
                [System.IO.Path]::DirectorySeparatorChar
            )
            $projectPath = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($solutionDirectory, $relativePath)
            )
            if ([System.IO.File]::Exists($projectPath)) {
                $projectPaths.Add($projectPath)
            }
        }
    }
    else {
        $solutionText = [System.IO.File]::ReadAllText($SolutionPath)
        $pattern = 'Project\("[^"]+"\)\s*=\s*"[^"]+",\s*"(?<path>[^"]+\.csproj)"'
        $matches = [System.Text.RegularExpressions.Regex]::Matches(
            $solutionText,
            $pattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        foreach ($match in $matches) {
            $relativePath = ([string]$match.Groups['path'].Value).Replace(
                '\',
                [System.IO.Path]::DirectorySeparatorChar
            )
            $projectPath = [System.IO.Path]::GetFullPath(
                [System.IO.Path]::Combine($solutionDirectory, $relativePath)
            )
            if ([System.IO.File]::Exists($projectPath)) {
                $projectPaths.Add($projectPath)
            }
        }
    }

    $uniqueProjectPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $relativeProjectPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($projectPath in $projectPaths) {
        if ($uniqueProjectPaths.Add($projectPath)) {
            $relativeProjectPaths.Add((Get-RelativeSlashPath -Root $solutionDirectory -Path $projectPath))
        }
    }
    $sortedRelativePaths = [string[]]$relativeProjectPaths.ToArray()
    [System.Array]::Sort($sortedRelativePaths, [System.StringComparer]::Ordinal)

    $sortedProjectPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativePath in $sortedRelativePaths) {
        $nativeRelativePath = $relativePath.Replace(
            '/',
            [System.IO.Path]::DirectorySeparatorChar
        )
        $sortedProjectPaths.Add([System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine($solutionDirectory, $nativeRelativePath)
        ))
    }
    if ($sortedProjectPaths.Count -eq 0) {
        throw 'Solution 中沒有可讀取的 C# 專案參考。'
    }

    return $sortedProjectPaths.ToArray()
}

function Get-SourceRelativePaths {
    param(
        [Parameter(Mandatory)][string]$ProjectRootPath,
        [Parameter(Mandatory)][string]$SearchRoot,
        [switch]$CSharpOnly
    )

    $excludedNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($name in @(
        '.git', '.local', 'bin', 'obj', 'dist', 'out', 'build', 'target',
        'node_modules', '__pycache__'
    )) {
        $null = $excludedNames.Add($name)
    }

    $pendingDirectories = [System.Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($SearchRoot)
    $relativePaths = [System.Collections.Generic.List[string]]::new()
    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Pop()
        foreach ($filePath in [System.IO.Directory]::EnumerateFiles($currentDirectory)) {
            if (-not $CSharpOnly -and (Test-ExcludedSourceFileName -Path $filePath)) {
                continue
            }
            if ($CSharpOnly -and [System.IO.Path]::GetExtension($filePath) -ine '.cs') {
                continue
            }

            $relativePaths.Add((Get-RelativeSlashPath -Root $ProjectRootPath -Path $filePath))
        }
        foreach ($directoryPath in [System.IO.Directory]::EnumerateDirectories($currentDirectory)) {
            $directoryInfo = [System.IO.DirectoryInfo]::new($directoryPath)
            if ($excludedNames.Contains($directoryInfo.Name)) {
                continue
            }
            if (($directoryInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }

            $pendingDirectories.Push($directoryPath)
        }
    }

    $sortedPaths = [string[]]$relativePaths.ToArray()
    [System.Array]::Sort($sortedPaths, [System.StringComparer]::Ordinal)
    return $sortedPaths
}

function Get-NativeCommandResult {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $outputLines = @(& $ExecutablePath @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $outputText = ($outputLines | ForEach-Object { $_.ToString() }) -join [System.Environment]::NewLine
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = $outputText
    }
}

function Get-ToolVersion {
    param([Parameter(Mandatory)][string]$CommandName)

    $command = Get-Command -Name $CommandName -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $result = Get-NativeCommandResult -ExecutablePath $command.Source -Arguments @('--version')
    if ($result.ExitCode -ne 0) {
        throw "$CommandName --version 失敗，exit code=$($result.ExitCode)：$($result.Output)"
    }

    $version = ($result.Output -split '\r?\n' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "$CommandName --version 未回傳版本。"
    }

    return [pscustomobject]@{
        Path = $command.Source
        Version = $version
    }
}

function Get-IndexCells {
    param([Parameter(Mandatory)][string]$Line)

    $trimmedLine = $Line.Trim()
    if (-not $trimmedLine.StartsWith('|') -or -not $trimmedLine.EndsWith('|')) {
        throw "Index 資料列不是五欄 Markdown 表格：$Line"
    }
    $segments = [System.Collections.Generic.List[string]]::new()
    $cell = [System.Text.StringBuilder]::new()
    for ($index = 0; $index -lt $trimmedLine.Length; $index++) {
        $character = $trimmedLine[$index]
        if ($character -eq '\' -and $index + 1 -lt $trimmedLine.Length) {
            $nextCharacter = $trimmedLine[$index + 1]
            if ($nextCharacter -eq '\' -or $nextCharacter -eq '|') {
                $null = $cell.Append($nextCharacter)
                $index++
                continue
            }
        }

        if ($character -eq '|') {
            $segments.Add($cell.ToString())
            $null = $cell.Clear()
            continue
        }

        $null = $cell.Append($character)
    }
    $segments.Add($cell.ToString())
    if ($segments.Count -ne 7) {
        throw "Index 資料列欄數不是五欄：$Line"
    }

    return @($segments[1..5] | ForEach-Object { $_.Trim() })
}

function Escape-IndexCell {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $escaped = [System.Text.StringBuilder]::new()
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\' -or $character -eq '|') {
            $null = $escaped.Append('\')
        }
        $null = $escaped.Append($character)
    }

    return $escaped.ToString()
}

function Get-IndexRows {
    param([Parameter(Mandatory)][string]$IndexPath)

    $rows = [System.Collections.Generic.List[object]]::new()
    if (-not [System.IO.File]::Exists($IndexPath)) {
        return $rows.ToArray()
    }

    $lines = [System.IO.File]::ReadAllLines($IndexPath, [System.Text.Encoding]::UTF8)
    if ($lines.Count -lt 2) {
        throw '既有 index.md 必須包含五欄標頭與分隔列。'
    }
    $expectedHeaders = @('工具', '產物路徑', '重產命令', '來源指紋', '產生時間')
    $headers = Get-IndexCells -Line $lines[0]
    $headersMatch = $headers.Count -eq $expectedHeaders.Count
    for ($headerIndex = 0; $headersMatch -and $headerIndex -lt $expectedHeaders.Count; $headerIndex++) {
        $headersMatch = $headers[$headerIndex] -ceq $expectedHeaders[$headerIndex]
    }
    if (-not $headersMatch) {
        throw '既有 index.md 標頭不符合固定五欄規格。'
    }
    foreach ($separator in Get-IndexCells -Line $lines[1]) {
        if ($separator -notmatch '^:?-{3,}:?$') {
            throw '既有 index.md 分隔列格式無效。'
        }
    }

    $toolNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $artifactPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    for ($lineIndex = 2; $lineIndex -lt $lines.Count; $lineIndex++) {
        if ([string]::IsNullOrWhiteSpace($lines[$lineIndex])) {
            continue
        }

        $cells = Get-IndexCells -Line $lines[$lineIndex]
        if (@($cells | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw "既有 index.md 有空白欄位，行號：$($lineIndex + 1)"
        }
        if ($cells[3] -ne '不適用' -and $cells[3] -notmatch '^sha256:v1:[0-9a-f]{64}$') {
            throw "既有 index.md 有無效來源指紋，行號：$($lineIndex + 1)"
        }
        if (-not $toolNames.Add($cells[0])) {
            throw "既有 index.md 有重複工具列：$($cells[0])"
        }
        if (-not $artifactPaths.Add($cells[1])) {
            throw "既有 index.md 有重複產物路徑：$($cells[1])"
        }

        $rows.Add([pscustomobject]@{
            Tool = $cells[0]
            ArtifactPath = $cells[1]
            RebuildCommand = $cells[2]
            SourceFingerprint = $cells[3]
            GeneratedAt = $cells[4]
        })
    }

    return $rows.ToArray()
}

function Test-ArtifactComplete {
    param(
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][bool]$IsDirectory
    )

    if ($IsDirectory) {
        if (-not [System.IO.Directory]::Exists($ArtifactPath)) {
            return $false
        }
        $graphFilePath = [System.IO.Path]::Combine($ArtifactPath, 'graph.json')
        return [System.IO.File]::Exists($graphFilePath) -and
            (Get-Item -LiteralPath $graphFilePath).Length -gt 0
    }

    return [System.IO.File]::Exists($ArtifactPath) -and
        (Get-Item -LiteralPath $ArtifactPath).Length -gt 0
}

function Remove-ArtifactPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][bool]$IsDirectory
    )

    if ($IsDirectory) {
        if ([System.IO.Directory]::Exists($Path)) {
            [System.IO.Directory]::Delete($Path, $true)
        }
    }
    elseif ([System.IO.File]::Exists($Path)) {
        [System.IO.File]::Delete($Path)
    }
}

function Move-ArtifactPath {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][bool]$IsDirectory
    )

    if ($IsDirectory) {
        [System.IO.Directory]::Move($Source, $Destination)
    }
    else {
        [System.IO.File]::Move($Source, $Destination)
    }
}

function Get-IndexText {
    param([Parameter(Mandatory)][object[]]$Rows)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('| 工具 | 產物路徑 | 重產命令 | 來源指紋 | 產生時間 |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($row in $Rows) {
        $lines.Add(('| {0} | {1} | {2} | {3} | {4} |' -f
            (Escape-IndexCell -Value ([string]$row.Tool)),
            (Escape-IndexCell -Value ([string]$row.ArtifactPath)),
            (Escape-IndexCell -Value ([string]$row.RebuildCommand)),
            (Escape-IndexCell -Value ([string]$row.SourceFingerprint)),
            (Escape-IndexCell -Value ([string]$row.GeneratedAt))
        ))
    }

    $crlf = [string][char]13 + [string][char]10
    return [string]::Join($crlf, $lines.ToArray()) + $crlf
}

function Get-ManifestFingerprint {
    param(
        [Parameter(Mandatory)][string]$ProjectRootPath,
        [AllowEmptyString()]
        [Parameter(Mandatory)][string]$SolutionPath,
        [AllowEmptyCollection()]
        [Parameter(Mandatory)][string[]]$ProjectPaths,
        [Parameter(Mandatory)][string]$ToolVersion,
        [Parameter(Mandatory)][string]$NormalizedCommand,
        [AllowEmptyString()]
        [Parameter(Mandatory)][string]$GeneratorRelativePath,
        [AllowEmptyString()]
        [Parameter(Mandatory)][string]$GeneratorPath,
        [Parameter(Mandatory)][string]$EnsureScriptPath
    )

    $records = [System.Collections.Generic.List[string]]::new()
    $records.Add('schema=ai-context-source-manifest.v1')
    $records.Add("tool=$ToolName")
    $records.Add("tool-version=$ToolVersion")
    $records.Add("command=$NormalizedCommand")
    if (-not [string]::IsNullOrWhiteSpace($GeneratorRelativePath)) {
        $records.Add("generator=$GeneratorRelativePath")
        $records.Add("generator-sha256=$(Get-FileSha256 -Path $GeneratorPath)")
    }
    $records.Add("ensure-sha256=$(Get-FileSha256 -Path $EnsureScriptPath)")

    $sourceRecords = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        $solutionRelativePath = Get-RelativeSlashPath -Root $ProjectRootPath -Path $SolutionPath
        $sourceRecords.Add("solution|$solutionRelativePath|$(Get-FileSha256 -Path $SolutionPath)")
    }
    foreach ($projectPath in $ProjectPaths) {
        $projectRelativePath = Get-RelativeSlashPath -Root $ProjectRootPath -Path $projectPath
        if ($ToolName -eq 'Export-ProjectGraph') {
            $sourceRecords.Add("project|$projectRelativePath|$(Get-FileSha256 -Path $projectPath)")
            $projectDirectory = [System.IO.Path]::GetDirectoryName($projectPath)
            [xml]$projectDocument = [System.IO.File]::ReadAllText($projectPath)
            foreach ($reference in $projectDocument.SelectNodes("//*[local-name()='ProjectReference']")) {
                $includeValue = [string]$reference.GetAttribute('Include')
                if ([string]::IsNullOrWhiteSpace($includeValue)) {
                    continue
                }

                $referencePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine(
                    $projectDirectory,
                    $includeValue.Replace('\', [System.IO.Path]::DirectorySeparatorChar)
                ))
                if ($ProjectPaths -icontains $referencePath) {
                    $referenceRelativePath = Get-RelativeSlashPath -Root $ProjectRootPath -Path $referencePath
                    $sourceRecords.Add("project-reference|$projectRelativePath|$referenceRelativePath")
                }
            }
        }
        else {
            $sourceRecords.Add("project-path|$projectRelativePath")
            $projectDirectory = [System.IO.Path]::GetDirectoryName($projectPath)
            $projectSources = Get-SourceRelativePaths -ProjectRootPath $ProjectRootPath -SearchRoot $projectDirectory -CSharpOnly
            foreach ($sourceRelativePath in $projectSources) {
                $sourcePath = [System.IO.Path]::Combine(
                    $ProjectRootPath,
                    $sourceRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
                )
                $sourceRecords.Add("source|$sourceRelativePath|$(Get-FileSha256 -Path $sourcePath)")
            }
        }
    }

    if ($ToolName -eq 'graphify') {
        $graphifySources = Get-SourceRelativePaths -ProjectRootPath $ProjectRootPath -SearchRoot $ProjectRootPath
        foreach ($sourceRelativePath in $graphifySources) {
            $sourcePath = [System.IO.Path]::Combine(
                $ProjectRootPath,
                $sourceRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            )
            $sourceRecords.Add("source|$sourceRelativePath|$(Get-FileSha256 -Path $sourcePath)")
        }
    }

    $sortedSourceRecords = [string[]]$sourceRecords.ToArray()
    [System.Array]::Sort($sortedSourceRecords, [System.StringComparer]::Ordinal)
    foreach ($sourceRecord in $sortedSourceRecords) {
        $records.Add($sourceRecord)
    }

    $manifestText = [string]::Join([string][char]10, $records.ToArray()) + [string][char]10
    $encoding = [System.Text.UTF8Encoding]::new($false)
    return "sha256:v1:$(Get-Sha256Text -Bytes $encoding.GetBytes($manifestText))"
}

try {
    $projectRootPath = [System.IO.Path]::GetFullPath($ProjectRoot)
    if (-not [System.IO.Directory]::Exists($projectRootPath)) {
        throw "ProjectRoot 不存在：$projectRootPath"
    }

    $aiContextRoot = [System.IO.Path]::Combine($projectRootPath, '.local', 'ai-context')
    $indexPath = [System.IO.Path]::Combine($aiContextRoot, 'index.md')
    $ensureScriptPath = [System.IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)

    $artifactRelativePath = ''
    $isDirectoryArtifact = $false
    $generatorRelativePath = ''
    $normalizedCommand = ''
    $rebuildCommand = ''
    $commandName = ''
    switch ($ToolName) {
        'Export-ApiSurface' {
            $artifactRelativePath = '.local/ai-context/api-surface.md'
            $generatorRelativePath = 'scripts/Export-ApiSurface.csx'
            $normalizedCommand = 'dotnet-script scripts/Export-ApiSurface.csx -- <solution-file> <temporary-output-file>'
            $commandName = 'dotnet-script'
        }
        'Export-TypeHierarchy' {
            $artifactRelativePath = '.local/ai-context/type-hierarchy.md'
            $generatorRelativePath = 'scripts/Export-TypeHierarchy.csx'
            $normalizedCommand = 'dotnet-script scripts/Export-TypeHierarchy.csx -- <solution-file> <temporary-output-file>'
            $commandName = 'dotnet-script'
        }
        'Export-ProjectGraph' {
            $artifactRelativePath = '.local/ai-context/project-graph.md'
            $generatorRelativePath = 'scripts/Export-ProjectGraph.csx'
            $normalizedCommand = 'dotnet-script scripts/Export-ProjectGraph.csx -- <solution-file> <temporary-output-file>'
            $commandName = 'dotnet-script'
        }
        'graphify' {
            $artifactRelativePath = '.local/ai-context/graphify/graphify-out/'
            $isDirectoryArtifact = $true
            $normalizedCommand = 'graphify extract <ProjectRoot> --out .local/ai-context/graphify/<temporary-output-directory>'
            $commandName = 'graphify'
        }
    }

    $artifactPath = [System.IO.Path]::Combine(
        $projectRootPath,
        $artifactRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    )
    $aiAgentsRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..'))
    $rebuildCommand = 'pwsh -NoProfile -File "{0}" -ProjectRoot "{1}" -ToolName {2}' -f
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($aiAgentsRoot, 'scripts', 'Ensure-AiContextArtifacts.ps1')),
        $projectRootPath,
        $ToolName
    $generatorPath = if ([string]::IsNullOrWhiteSpace($generatorRelativePath)) {
        ''
    }
    else {
        [System.IO.Path]::GetFullPath([System.IO.Path]::Combine(
            (Split-Path -Parent $PSScriptRoot),
            $generatorRelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
        ))
    }
    $existingRows = @(Get-IndexRows -IndexPath $indexPath)
    $existingRow = $existingRows |
        Where-Object { $_.Tool -ceq $ToolName } |
        Select-Object -First 1
    $artifactIsComplete = Test-ArtifactComplete -ArtifactPath $artifactPath -IsDirectory $isDirectoryArtifact

    $solutionPath = ''
    $projectPaths = @()
    if ($ToolName -ne 'graphify') {
        $solutionPath = Get-SolutionFile -Root $projectRootPath
        $projectPaths = Get-SolutionProjectPaths -SolutionPath $solutionPath
    }
    if (-not $isDirectoryArtifact -and -not [System.IO.File]::Exists($generatorPath)) {
        throw "找不到產生器：$generatorPath"
    }

    $tool = Get-ToolVersion -CommandName $commandName
    $manifestFingerprint = Get-ManifestFingerprint -ProjectRootPath $projectRootPath -SolutionPath $solutionPath -ProjectPaths $projectPaths -ToolVersion $tool.Version -NormalizedCommand $normalizedCommand -GeneratorRelativePath $generatorRelativePath -GeneratorPath $generatorPath -EnsureScriptPath $ensureScriptPath

    if ($null -ne $existingRow -and
        $existingRow.ArtifactPath -ceq $artifactRelativePath -and
        $existingRow.RebuildCommand -ceq $rebuildCommand -and
        $existingRow.SourceFingerprint -ceq $manifestFingerprint -and
        $artifactIsComplete) {
        Write-Host '未變更'
        exit 0
    }

    $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($artifactPath))
    $null = [System.IO.Directory]::CreateDirectory($aiContextRoot)
    $nonce = [System.Guid]::NewGuid().ToString('N')
    $temporaryArtifactRoot = ''
    if ($isDirectoryArtifact) {
        $artifactParent = [System.IO.Path]::GetDirectoryName($artifactPath)
        $temporaryArtifactRoot = [System.IO.Path]::Combine($artifactParent, ".tmp-$nonce")
        $temporaryArtifactPath = [System.IO.Path]::Combine($temporaryArtifactRoot, 'graphify-out')
        $null = [System.IO.Directory]::CreateDirectory($temporaryArtifactRoot)
    }
    else {
        $temporaryArtifactPath = [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($artifactPath),
            "$([System.IO.Path]::GetFileNameWithoutExtension($artifactPath)).$nonce.tmp$([System.IO.Path]::GetExtension($artifactPath))"
        )
    }

    $temporaryIndexPath = "$indexPath.$nonce.tmp"
    $artifactBackupPath = "$artifactPath.$nonce.backup"
    $indexBackupPath = "$indexPath.$nonce.backup"
    $artifactBackedUp = $false
    $artifactPromoted = $false
    $indexReplaced = $false
    $indexCreated = $false
    $promotionComplete = $false
    try {
        if ($ToolName -eq 'graphify') {
            $arguments = @('extract', $projectRootPath, '--out', $temporaryArtifactRoot)
        }
        else {
            $arguments = @($generatorPath, '--', $solutionPath, $temporaryArtifactPath)
        }

        $generationResult = Get-NativeCommandResult -ExecutablePath $tool.Path -Arguments $arguments
        if ($generationResult.ExitCode -ne 0) {
            throw "$ToolName 產生失敗，exit code=$($generationResult.ExitCode)：$($generationResult.Output)"
        }
        if (-not (Test-ArtifactComplete -ArtifactPath $temporaryArtifactPath -IsDirectory $isDirectoryArtifact)) {
            throw "$ToolName 輸出不完整，暫存產物不存在或為空。"
        }

        $generatedAt = [System.DateTime]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $newRow = [pscustomobject]@{
            Tool = $ToolName
            ArtifactPath = $artifactRelativePath
            RebuildCommand = $rebuildCommand
            SourceFingerprint = $manifestFingerprint
            GeneratedAt = $generatedAt
        }
        $indexRows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $existingRows) {
            if ($row.Tool -cne $ToolName) {
                $indexRows.Add($row)
            }
        }
        $indexRows.Add($newRow)
        [System.IO.File]::WriteAllText(
            $temporaryIndexPath,
            (Get-IndexText -Rows $indexRows.ToArray()),
            [System.Text.UTF8Encoding]::new($false)
        )

        if ($isDirectoryArtifact) {
            if ([System.IO.Directory]::Exists($artifactPath)) {
                Move-ArtifactPath -Source $artifactPath -Destination $artifactBackupPath -IsDirectory $true
                $artifactBackedUp = $true
            }
            Move-ArtifactPath -Source $temporaryArtifactPath -Destination $artifactPath -IsDirectory $true
            $artifactPromoted = $true
        }
        elseif ([System.IO.File]::Exists($artifactPath)) {
            [System.IO.File]::Replace($temporaryArtifactPath, $artifactPath, $artifactBackupPath)
            $artifactBackedUp = $true
            $artifactPromoted = $true
        }
        else {
            [System.IO.File]::Move($temporaryArtifactPath, $artifactPath)
            $artifactPromoted = $true
        }

        if ([System.IO.File]::Exists($indexPath)) {
            [System.IO.File]::Replace($temporaryIndexPath, $indexPath, $indexBackupPath)
            $indexReplaced = $true
        }
        else {
            [System.IO.File]::Move($temporaryIndexPath, $indexPath)
            $indexCreated = $true
        }
        $promotionComplete = $true
    }
    catch {
        if ($promotionComplete) {
            Write-Warning '產物與索引已提升；清理錯誤不觸發回滾。'
        }
        else {
            if ($indexReplaced -and [System.IO.File]::Exists($indexBackupPath)) {
                if ([System.IO.File]::Exists($indexPath)) {
                    [System.IO.File]::Replace($indexBackupPath, $indexPath, $null)
                }
                else {
                    [System.IO.File]::Move($indexBackupPath, $indexPath)
                }
            }
            elseif ($indexCreated -and [System.IO.File]::Exists($indexPath)) {
                [System.IO.File]::Delete($indexPath)
            }

            if ($artifactPromoted) {
                Remove-ArtifactPath -Path $artifactPath -IsDirectory $isDirectoryArtifact
            }
            if ($artifactBackedUp) {
                Move-ArtifactPath -Source $artifactBackupPath -Destination $artifactPath -IsDirectory $isDirectoryArtifact
            }
        }
        throw
    }
    finally {
        try {
            if ([System.IO.File]::Exists($temporaryArtifactPath)) {
                [System.IO.File]::Delete($temporaryArtifactPath)
            }
            if ([System.IO.Directory]::Exists($temporaryArtifactRoot)) {
                [System.IO.Directory]::Delete($temporaryArtifactRoot, $true)
            }
            if ([System.IO.File]::Exists($temporaryIndexPath)) {
                [System.IO.File]::Delete($temporaryIndexPath)
            }
        }
        catch {
            Write-Warning "暫存清理失敗：$($_.Exception.Message)"
        }
    }

    if ([System.IO.Directory]::Exists($artifactBackupPath) -or
        [System.IO.File]::Exists($artifactBackupPath)) {
        try {
            Remove-ArtifactPath -Path $artifactBackupPath -IsDirectory $isDirectoryArtifact
        }
        catch {
            Write-Warning "已更新，但無法清理舊產物備份：$($_.Exception.Message)"
        }
    }
    if ([System.IO.File]::Exists($indexBackupPath)) {
        try {
            [System.IO.File]::Delete($indexBackupPath)
        }
        catch {
            Write-Warning "已更新，但無法清理舊索引備份：$($_.Exception.Message)"
        }
    }
    Write-Host '已更新'
    exit 0
}
catch {
    Write-Error -Message $_.Exception.Message
    exit 1
}
