#Requires -Version 7.0
# 子行程啟動與三項啟動修正（不繼承呼叫端輸出管線、子行程編碼、機密環境變數清除）。依賴 00-common.ps1。
# 引數與 prompt 由呼叫端傳入，本檔不認得 codex 的子命令。

function Initialize-RunStdHandleGuard {
    [CmdletBinding()]
    param()

    # 非 Windows 為 no-op，保留供測試在其他平台載入模組。
    if (-not [OperatingSystem]::IsWindows()) { return $false }
    if ($null -eq ('RunStdHandleGuard' -as [type])) {
        Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class RunStdHandleGuard
{
    private const int HandleFlagInherit = 1;
    private static readonly int[] StdHandleIds = new int[] { -10, -11, -12 };

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int nStdHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetHandleInformation(IntPtr hObject, out int lpdwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetHandleInformation(IntPtr hObject, int dwMask, int dwFlags);

    public static int GetInheritFlag(int stdHandleId)
    {
        IntPtr handle = GetStdHandle(stdHandleId);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { return -1; }
        int flags;
        if (!GetHandleInformation(handle, out flags)) { return -1; }
        return flags & HandleFlagInherit;
    }

    public static IntPtr[] Suspend()
    {
        List<IntPtr> suspended = new List<IntPtr>();
        foreach (int id in StdHandleIds)
        {
            IntPtr handle = GetStdHandle(id);
            if (handle == IntPtr.Zero || handle == new IntPtr(-1)) { continue; }
            int flags;
            if (!GetHandleInformation(handle, out flags)) { continue; }
            if ((flags & HandleFlagInherit) == 0) { continue; }
            if (SetHandleInformation(handle, HandleFlagInherit, 0)) { suspended.Add(handle); }
        }
        return suspended.ToArray();
    }

    public static void Restore(IntPtr[] suspended)
    {
        if (suspended == null) { return; }
        foreach (IntPtr handle in suspended)
        {
            SetHandleInformation(handle, HandleFlagInherit, HandleFlagInherit);
        }
    }
}
'@
    }
    return $true
}

function Invoke-RunWithoutStdHandleInheritance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock
    )

    # Start() 前清除呼叫端 stdin、stdout、stderr 的繼承旗標，finally 還原。
    # 呼叫端的輸出管線若被子行程繼承，呼叫端會等到子行程結束才收到管線 EOF。
    if (-not (Initialize-RunStdHandleGuard)) {
        return (& $ScriptBlock)
    }
    $suspended = [RunStdHandleGuard]::Suspend()
    try {
        return (& $ScriptBlock)
    }
    finally {
        [RunStdHandleGuard]::Restore($suspended)
    }
}

function New-RunProcessStartInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FileName,

        [AllowEmptyCollection()]
        [string[]]$Argument = @(),

        [string]$WorkingDirectory
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FileName
    if (-not [string]::IsNullOrEmpty($WorkingDirectory)) { $startInfo.WorkingDirectory = $WorkingDirectory }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($item in $Argument) { [void]$startInfo.ArgumentList.Add($item) }
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # 預設編碼依系統 code page（例如 CP950）。prompt 含中文時，非 UTF-8 的 stdin 會使子行程收到亂碼。
    $utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList @($false)
    $startInfo.StandardInputEncoding = $utf8NoBom
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom
    return $startInfo
}

function Remove-RunSecretEnvironmentVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Diagnostics.ProcessStartInfo]$StartInfo,

        [string]$ListPath = (Join-Path $PSScriptRoot 'env-denylist.psd1')
    )

    # 回傳被移除的變數名稱。名單缺少、無法匯入、結構異常時丟錯，不在沒有清除的情況下啟動。
    if (-not [IO.File]::Exists($ListPath)) {
        throw (New-RunError -Code 'RunEnvDenylistMissing' -Message ('機密環境變數名單不存在：' + $ListPath))
    }
    try {
        $list = Import-PowerShellDataFile -LiteralPath $ListPath -ErrorAction Stop
    }
    catch {
        $message = $_.Exception.Message
        if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
        throw (New-RunError -Code 'RunEnvDenylistUnreadable' -Message ('機密環境變數名單無法匯入：' + $message))
    }
    foreach ($key in @('DenyPatterns', 'KeepNames', 'KeepPatterns')) {
        if (-not $list.ContainsKey($key) -or $null -eq $list[$key] -or
            @($list[$key] | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            throw (New-RunError -Code 'RunEnvDenylistInvalid' -Message ('機密環境變數名單結構異常：無效欄位 ' + $key))
        }
    }
    if (@($list.DenyPatterns).Count -eq 0) {
        throw (New-RunError -Code 'RunEnvDenylistInvalid' -Message '機密環境變數名單結構異常：DenyPatterns 為空。')
    }

    $removed = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in @($StartInfo.EnvironmentVariables.Keys)) {
        $keep = @($list.KeepNames | Where-Object { $name -ieq $_ }).Count -gt 0 -or
            @($list.KeepPatterns | Where-Object { $name -like $_ }).Count -gt 0
        if (-not $keep -and @($list.DenyPatterns | Where-Object { $name -like $_ }).Count -gt 0) {
            $StartInfo.EnvironmentVariables.Remove($name)
            $removed.Add($name)
        }
    }
    return @($removed.ToArray())
}

function Test-RunTurnEnded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EventStreamPath,

        [string]$LastMessagePath
    )

    # 回合已結束：事件流最後一個事件為 turn.completed，且最後訊息檔存在且非空。
    # 事件流由 Invoke-RunCodexProcess 無緩衝寫入，執行中可以共享讀取。只讀檔尾，不整檔讀入。
    if ([string]::IsNullOrWhiteSpace($LastMessagePath) -or -not [IO.File]::Exists($LastMessagePath)) { return $false }
    if ((New-Object System.IO.FileInfo -ArgumentList @($LastMessagePath)).Length -eq 0) { return $false }
    try {
        $stream = New-Object System.IO.FileStream -ArgumentList @($EventStreamPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $tailLength = [int][Math]::Min([long]65536, $stream.Length)
            if ($tailLength -eq 0) { return $false }
            $null = $stream.Seek(-$tailLength, [IO.SeekOrigin]::End)
            $buffer = New-Object 'byte[]' $tailLength
            $read = $stream.Read($buffer, 0, $tailLength)
            $text = (New-Object System.Text.UTF8Encoding -ArgumentList @($false)).GetString($buffer, 0, $read)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $false
    }
    $lastLine = @($text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) | Select-Object -Last 1
    if ($null -eq $lastLine) { return $false }
    try {
        $parsed = ConvertFrom-Json -InputObject $lastLine -Depth 20
    }
    catch {
        return $false
    }
    return $parsed -is [pscustomobject] -and [string](Get-RunJsonProperty -Object $parsed -Name 'type') -ceq 'turn.completed'
}

function Invoke-RunCodexProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CodexPath,

        [Parameter(Mandatory)]
        [string[]]$Argument,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$CodexHome,

        [Parameter(Mandatory)]
        [string]$EventStreamPath,

        [Parameter(Mandatory)]
        [string]$StderrPath,

        [string]$WorkingDirectory,

        # 回合結束寬限的判斷依據；空值時不套用寬限。
        [string]$LastMessagePath,

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 1800,

        [ValidateRange(0, 3600)]
        [int]$TurnEndGraceSeconds = 60,

        # 額外設定給 Codex 行程的環境變數（例如 PLAYWRIGHT_MCP_OUTPUT_DIR，由 MCP 伺服器的 env_vars 轉給 MCP 行程）。
        [hashtable]$ExtraEnvironment = @{}
    )

    # 同步執行：啟動、寫 prompt、位元組原樣複製 stdout 與 stderr、等待結束。
    # 等待有兩個出口：總時限 TimeoutSeconds；事件流出現 turn.completed 且最後訊息非空之後，子行程 TurnEndGraceSeconds 內仍未結束。
    # 兩者都終止整棵行程樹，回傳 TerminatedBy（timeout 或 after-turn-end，否則 $null）。
    foreach ($path in @($EventStreamPath, $StderrPath)) {
        $directory = Split-Path -Parent $path
        if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    }
    $startInfo = New-RunProcessStartInfo -FileName $CodexPath -Argument $Argument -WorkingDirectory $WorkingDirectory
    $removed = @(Remove-RunSecretEnvironmentVariable -StartInfo $startInfo)
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $CodexHome
    # 沙盒內的 git 讀不到使用者家目錄的 .gitconfig 會整個失敗；不讀全域與系統設定，不擴大沙盒可讀範圍。
    $startInfo.EnvironmentVariables['GIT_CONFIG_GLOBAL'] = 'NUL'
    $startInfo.EnvironmentVariables['GIT_CONFIG_NOSYSTEM'] = '1'
    foreach ($name in @($ExtraEnvironment.Keys)) { $startInfo.EnvironmentVariables[[string]$name] = [string]$ExtraEnvironment[$name] }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $eventStream = $null
    $stderrStream = $null
    $terminatedBy = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        # bufferSize 0：不經 .NET 緩衝，事件在執行中即可被共享讀取。
        $eventStream = New-Object System.IO.FileStream -ArgumentList @($EventStreamPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 0)
        $stderrStream = New-Object System.IO.FileStream -ArgumentList @($StderrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 0)
        $null = Invoke-RunWithoutStdHandleInheritance -ScriptBlock { $process.Start() }
        $stdoutTask = $process.StandardOutput.BaseStream.CopyToAsync($eventStream)
        $stderrTask = $process.StandardError.BaseStream.CopyToAsync($stderrStream)
        try {
            $process.StandardInput.Write($Prompt)
            $process.StandardInput.Close()
        }
        catch [System.IO.IOException] {
            # 子行程未讀完 prompt 就結束（管線已關閉）。結果由結束碼與事件流判定。
        }
        $turnEndedAt = $null
        while (-not $process.WaitForExit(500)) {
            $elapsed = $stopwatch.Elapsed.TotalSeconds
            if ($elapsed -ge $TimeoutSeconds) { $terminatedBy = 'timeout'; break }
            if ($null -eq $turnEndedAt) {
                if (Test-RunTurnEnded -EventStreamPath $EventStreamPath -LastMessagePath $LastMessagePath) { $turnEndedAt = $elapsed }
            }
            elseif ($elapsed - $turnEndedAt -ge $TurnEndGraceSeconds) { $terminatedBy = 'after-turn-end'; break }
        }
        if ($null -ne $terminatedBy) {
            try { $process.Kill($true) } catch { $null = $_ }
            $null = $process.WaitForExit(10000)
        }
        else {
            $process.WaitForExit()
        }
        # 子行程已結束。孫行程若仍握著管線，最多再等 10 秒讓兩個複製工作收尾。
        $null = [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 10000)
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            TerminatedBy = $terminatedBy
            RemovedEnvironmentVariable = $removed
        }
    }
    finally {
        if ($null -ne $eventStream) { $eventStream.Dispose() }
        if ($null -ne $stderrStream) { $stderrStream.Dispose() }
        $process.Dispose()
    }
}
