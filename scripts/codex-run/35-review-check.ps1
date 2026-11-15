#Requires -Version 7.0
# 審查報告的 finding 清單檢查。只檢查 manifest 的標題、區塊、編號、嚴重度與狀態，不比對報告正文。依賴 00-common.ps1。

function Test-RunReviewReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ReportPath
    )

    # 回傳 valid、errors、findings。errors 每筆為「<finding 編號或 findings[<索引>]> <欄位>: <原因>」，索引從 0 起算。
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $finish = {
        return [pscustomobject]@{ valid = ($errors.Count -eq 0); errors = [string[]]@($errors.ToArray()); findings = @($findings.ToArray()) }
    }
    if (-not [IO.File]::Exists($ReportPath)) {
        $errors.Add('manifest: report file not found')
        return (& $finish)
    }
    $text = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetString([IO.File]::ReadAllBytes($ReportPath))

    $headings = [regex]::Matches($text, '(?m)^##[ \t]+Finding manifest[ \t]*\r?$')
    if ($headings.Count -eq 0) {
        $errors.Add('manifest: heading not found')
        return (& $finish)
    }
    if ($headings.Count -gt 1) {
        $errors.Add('manifest: heading count ' + $headings.Count)
        return (& $finish)
    }
    $remaining = $text.Substring($headings[0].Index + $headings[0].Length)
    $nextHeading = [regex]::Match($remaining, '(?m)^##[ \t]+')
    $section = if ($nextHeading.Success) { $remaining.Substring(0, $nextHeading.Index) } else { $remaining }
    $blocks = [regex]::Matches($section, '(?ms)^```json[ \t]*\r?\n(?<json>.*?)^```[ \t]*\r?$')
    if ($blocks.Count -ne 1) {
        $errors.Add('manifest: json block count ' + $blocks.Count)
        return (& $finish)
    }
    try {
        $manifest = ConvertFrom-Json -InputObject $blocks[0].Groups['json'].Value -Depth 20
    }
    catch {
        $errors.Add('manifest: json invalid: ' + $_.Exception.Message)
        return (& $finish)
    }
    $findingsProperty = if ($manifest -is [pscustomobject]) { $manifest.PSObject.Properties['findings'] } else { $null }
    $schemaProperty = if ($manifest -is [pscustomobject]) { $manifest.PSObject.Properties['schema'] } else { $null }
    if ($null -eq $schemaProperty -or [string]$schemaProperty.Value -cne 'codex-run.review-findings.v1') {
        $errors.Add('manifest: schema invalid')
        return (& $finish)
    }
    if ($null -eq $findingsProperty -or $findingsProperty.Value -isnot [array]) {
        $errors.Add('manifest: findings must be an array')
        return (& $finish)
    }

    $seenIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $index = -1
    foreach ($finding in @($findingsProperty.Value)) {
        $index++
        $placeholder = 'findings[' + $index + ']'
        if ($finding -isnot [pscustomobject]) {
            $errors.Add($placeholder + ' finding: not an object')
            continue
        }
        $idValue = $finding.PSObject.Properties['id']
        $label = $placeholder
        if ($null -eq $idValue -or $idValue.Value -isnot [string] -or [string]::IsNullOrEmpty($idValue.Value)) {
            $errors.Add($placeholder + ' id: missing')
        }
        else {
            $id = [string]$idValue.Value
            $label = $id
            if ($id -cnotmatch '^(?:F-[0-9]{3}|T[0-9]{3}[A-Z]?)$') { $errors.Add($label + " id: invalid value '" + $id + "'") }
            elseif (-not $seenIds.Add($id)) { $errors.Add($label + ' id: duplicate') }
        }
        foreach ($field in @(
                @{ name = 'severity'; allowed = @('Critical', 'Major', 'Minor') },
                @{ name = 'status'; allowed = @('open', 'closed', 'withdrawn', 'accepted') })) {
            $property = $finding.PSObject.Properties[$field.name]
            if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrEmpty($property.Value)) {
                $errors.Add($label + ' ' + $field.name + ': missing')
            }
            elseif ($field.allowed -cnotcontains $property.Value) {
                $errors.Add($label + ' ' + $field.name + ": invalid value '" + $property.Value + "'")
            }
        }
        $summaryProperty = $finding.PSObject.Properties['summary']
        if ($null -eq $summaryProperty -or $summaryProperty.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($summaryProperty.Value)) {
            $errors.Add($label + ' summary: empty')
        }
        $severityProperty = $finding.PSObject.Properties['severity']
        $statusProperty = $finding.PSObject.Properties['status']
        $findings.Add([pscustomobject]@{
                id = if ($null -eq $idValue) { $null } else { $idValue.Value }
                severity = if ($null -eq $severityProperty) { $null } else { $severityProperty.Value }
                status = if ($null -eq $statusProperty) { $null } else { $statusProperty.Value }
                summary = if ($null -eq $summaryProperty) { $null } else { $summaryProperty.Value }
            })
    }
    return (& $finish)
}
