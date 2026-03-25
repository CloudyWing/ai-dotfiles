[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$path = $data.tool_input.file_path
if ($path -and $path -match '\.md$') {
    Write-Output "[check-markdown hook] $path was written. Please run check-markdown skill to verify Markdown formatting."
}
