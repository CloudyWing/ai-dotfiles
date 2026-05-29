[Console]::InputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$raw = [Console]::In.ReadToEnd()
try { $data = $raw | ConvertFrom-Json } catch { exit 0 }

$allowedTools = @('Write', 'Edit')
if ($allowedTools -notcontains $data.tool_name) { exit 0 }

$path = $data.tool_input.file_path
if (-not $path) { exit 0 }

$ext = [System.IO.Path]::GetExtension($path).ToLower()

# Markdown 排版檢查提示
if ($ext -eq '.md') {
    Write-Output "[post-edit-write hook] $path was written. Please run check-markdown skill to verify Markdown formatting."

    $dashPattern = "$([char]0x2014)$([char]0x2014)"   # 連續兩個 U+2014
    $colon = [char]0xFF1A                              # 全形冒號 U+FF1A
    try {
        $mdLines = [System.IO.File]::ReadAllLines($path)
        $dashHits = @()
        $colonHits = @()
        $inFence = $false
        $colonLeadWhitelist = @('如下', '例', '例如', '注意', '說明', '步驟', '格式', '適用情境', '限制', '用途', '條件', '定義', '原則')

        for ($i = 0; $i -lt $mdLines.Count; $i++) {
            $line = $mdLines[$i]

            # fenced code block 內整段跳過
            if ($line -match '^\s*```') { $inFence = -not $inFence; continue }
            if ($inFence) { continue }

            # 移除行內 `code` span，避免程式碼內符號誤判
            $scan = [regex]::Replace($line, '`[^`]*`', '')

            # 全形破折號（句中轉折）
            if ($scan.Contains($dashPattern)) {
                $dashHits += "  line $($i + 1): $($line.Trim())"
            }

            # 散文式冒號候選：CJK：CJK，冒號非行尾，冒號後為完整句（以。」結尾），且引言非標籤白名單
            if ($scan -match "[一-鿿]$colon[一-鿿]") {
                $parts = $scan -split $colon, 2
                $lead = $parts[0].Trim()
                $tail = $parts[1].Trim()
                $isLabel = $false
                foreach ($w in $colonLeadWhitelist) { if ($lead.EndsWith($w)) { $isLabel = $true; break } }
                if (-not $isLabel -and $tail -ne '' -and $tail -match '[。」]\s*$') {
                    $colonHits += "  line $($i + 1): $($line.Trim())"
                }
            }
        }

        if ($dashHits) {
            Write-Output "[post-edit-write hook] WARNING: $path contains forbidden full-width dash (two consecutive U+2014). Replace with comma/semicolon or split into separate sentences:"
            $dashHits | ForEach-Object { Write-Output $_ }
        }
        if ($colonHits) {
            Write-Output "[post-edit-write hook] REVIEW: $path has candidate prose-colon lines (mid-sentence CJK colon with a full-sentence tail). Confirm each is not a narrative 'X:Y' continuation; legit lead-ins (e.g. '...如下:') and label fields are acceptable:"
            $colonHits | ForEach-Object { Write-Output $_ }
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
