[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$allowedTools = @('Write', 'Edit')
if ($allowedTools -notcontains $data.tool_name) { exit 0 }

$path = $data.tool_input.file_path
if (-not $path) { exit 0 }

$ext = [System.IO.Path]::GetExtension($path).ToLower()

# Markdown 格式檢查提示
if ($ext -eq '.md') {
    Write-Output "[post-edit-write hook] $path was written. Please run check-markdown skill to verify Markdown formatting."

    # 全形破折號禁用檢查（連續兩個 U+2014）
    $dashPattern = "$([char]0x2014)$([char]0x2014)"
    try {
        $mdLines = [System.IO.File]::ReadAllLines($path)
        $hits = for ($i = 0; $i -lt $mdLines.Count; $i++) {
            if ($mdLines[$i].Contains($dashPattern)) { "  line $($i + 1): $($mdLines[$i].Trim())" }
        }
        if ($hits) {
            Write-Output "[post-edit-write hook] WARNING: $path contains forbidden full-width dash (two consecutive U+2014). Replace with comma/semicolon or split into separate sentences:"
            $hits | ForEach-Object { Write-Output $_ }
        }
    } catch {}
}

# BOM 規範檢查
$alwaysBom = @('.ps1', '.csv')
$neverBom = @('.md', '.json', '.xml', '.yaml', '.yml', '.sh', '.txt')

try {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    if ($alwaysBom -contains $ext) {
        if (-not $hasBom) {
            Write-Output "[post-edit-write hook] WARNING: $path is missing UTF-8 BOM. '$ext' files require BOM. Please rewrite with BOM or run /fix-file-encoding."
        }
    } elseif ($neverBom -contains $ext) {
        if ($hasBom) {
            Write-Output "[post-edit-write hook] WARNING: $path has unexpected UTF-8 BOM. '$ext' files should not have BOM. Please rewrite without BOM or run /fix-file-encoding."
        }
    }
} catch { exit 0 }
