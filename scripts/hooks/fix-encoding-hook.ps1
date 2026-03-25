[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

if ($data.tool_name -ne 'Write') { exit 0 }

$path = $data.tool_input.file_path
if (-not $path) { exit 0 }

$ext = [System.IO.Path]::GetExtension($path).ToLower()
$alwaysBom = @('.ps1', '.csv')
$neverBom = @('.md', '.json', '.xml', '.yaml', '.yml', '.sh', '.txt')

try {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)

    if ($alwaysBom -contains $ext) {
        if (-not $hasBom) {
            Write-Output "[fix-encoding hook] WARNING: $path is missing UTF-8 BOM. '$ext' files require BOM. Please rewrite with BOM or run /fix-file-encoding."
        }
    } elseif ($neverBom -contains $ext) {
        if ($hasBom) {
            Write-Output "[fix-encoding hook] WARNING: $path has unexpected UTF-8 BOM. '$ext' files should not have BOM. Please rewrite without BOM or run /fix-file-encoding."
        }
    }
} catch { exit 0 }
