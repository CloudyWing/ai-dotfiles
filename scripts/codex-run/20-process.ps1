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

        [string]$WorkingDirectory
    )

    # 同步執行：啟動、寫 prompt、位元組原樣複製 stdout 與 stderr、等待結束。不設逾時。
    foreach ($path in @($EventStreamPath, $StderrPath)) {
        $directory = Split-Path -Parent $path
        if (-not [IO.Directory]::Exists($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
    }
    $startInfo = New-RunProcessStartInfo -FileName $CodexPath -Argument $Argument -WorkingDirectory $WorkingDirectory
    $removed = @(Remove-RunSecretEnvironmentVariable -StartInfo $startInfo)
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $CodexHome

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $eventStream = $null
    $stderrStream = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $eventStream = New-Object System.IO.FileStream -ArgumentList @($EventStreamPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $stderrStream = New-Object System.IO.FileStream -ArgumentList @($StderrPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
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
        $process.WaitForExit()
        # 子行程已結束。孫行程若仍握著管線，最多再等 10 秒讓兩個複製工作收尾。
        $null = [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 10000)
        $eventStream.Flush()
        $stderrStream.Flush()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            DurationSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            RemovedEnvironmentVariable = $removed
        }
    }
    finally {
        if ($null -ne $eventStream) { $eventStream.Dispose() }
        if ($null -ne $stderrStream) { $stderrStream.Dispose() }
        $process.Dispose()
    }
}
