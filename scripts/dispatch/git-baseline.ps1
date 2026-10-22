function Initialize-DispatchBoundFileCopy {
    [CmdletBinding()]
    param()

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return $false }
    if ($null -eq ('DispatchBoundFileCopy' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class DispatchBoundFileCopy : IDisposable
{
    private const uint GenericRead = 0x80000000;
    private const uint GenericWrite = 0x40000000;
    private const uint FileReadAttributes = 0x00000080;
    private const uint FileWriteAttributes = 0x00000100;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagSequentialScan = 0x08000000;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileAttributeDirectory = 0x00000010;
    private const uint FileAttributeReadOnly = 0x00000001;
    private const uint FileAttributeNormal = 0x00000080;
    private const uint FileAttributeReparsePoint = 0x00000400;
    private const int PathBufferInitialSize = 512;
    private const int PathBufferMaximumSize = 32768;
    private const int CopyBufferSize = 1024 * 1024;
    private const long RollbackBufferLimit = 16L * 1024L * 1024L;

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTimeValue { public uint Low; public uint High; }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileBasicInformation
    {
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
        public uint Reserved;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public FileTimeValue CreationTime;
        public FileTimeValue LastAccessTime;
        public FileTimeValue LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
    private static extern SafeFileHandle CreateFileW(string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleFileInformation information);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int fileInformationClass, ref FileBasicInformation information, uint bufferSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeFileHandle ReOpenFile(SafeFileHandle originalFile, uint desiredAccess, uint shareMode, uint flagsAndAttributes);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "GetFinalPathNameByHandleW")]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint pathLength, uint flags);

    private readonly SafeFileHandle _sourceRootHandle;
    private readonly SafeFileHandle _dispatchRootHandle;
    private readonly string _sourceRootFinalPath;
    private readonly string _dispatchRootFinalPath;
    private bool _disposed;

    public DispatchBoundFileCopy(string sourceRoot, string dispatchRoot)
    {
        SafeFileHandle sourceHandle = null;
        SafeFileHandle dispatchHandle = null;
        try
        {
            sourceHandle = OpenRoot(sourceRoot, "來源");
            dispatchHandle = OpenRoot(dispatchRoot, "dispatch");
            _sourceRootFinalPath = GetFinalPath(sourceHandle, "來源 root");
            _dispatchRootFinalPath = GetFinalPath(dispatchHandle, "dispatch root");
            _sourceRootHandle = sourceHandle;
            _dispatchRootHandle = dispatchHandle;
            sourceHandle = null;
            dispatchHandle = null;
        }
        finally
        {
            if (sourceHandle != null) sourceHandle.Dispose();
            if (dispatchHandle != null) dispatchHandle.Dispose();
        }
    }

    public string CopyBound(string sourcePath, string destinationPath, string relativePath)
    {
        return CopyBoundCore(sourcePath, destinationPath, relativePath, null, null);
    }

    private string CopyBoundCore(string sourcePath, string destinationPath, string relativePath, Func<Stream, Stream> destinationStreamDecorator, Action destinationAttributesRestoreProbe)
    {
        ThrowIfDisposed();
        ValidateRelativePath(relativePath);
        SafeFileHandle sourceHandle = null;
        SafeFileHandle destinationAttributesHandle = null;
        SafeFileHandle destinationHandle = null;
        FileStream sourceStream = null;
        FileStream destinationFileStream = null;
        Stream destinationStream = null;
        uint originalDestinationAttributes = 0;
        bool destinationAttributesCaptured = false;
        Exception pendingException = null;
        try
        {
            sourceHandle = OpenFile(sourcePath, GenericRead, FileShareRead, "來源");
            ValidateFileHandle(sourceHandle, _sourceRootFinalPath, relativePath, "來源", false);

            destinationAttributesHandle = OpenFile(destinationPath, FileReadAttributes | FileWriteAttributes,
                FileShareRead | FileShareWrite | FileShareDelete, "dispatch 屬性");
            ValidateFileHandle(destinationAttributesHandle, _dispatchRootFinalPath, relativePath, "dispatch", true);
            ByHandleFileInformation destinationInformation = GetInformation(destinationAttributesHandle, "dispatch file");
            originalDestinationAttributes = destinationInformation.FileAttributes;
            destinationAttributesCaptured = true;

            if ((originalDestinationAttributes & FileAttributeReadOnly) != 0)
            {
                uint writableAttributes = originalDestinationAttributes & ~FileAttributeReadOnly;
                if (writableAttributes == 0) writableAttributes = FileAttributeNormal;
                SetFileAttributesByHandle(destinationAttributesHandle, writableAttributes, relativePath);
            }

            destinationHandle = ReOpenWritableFile(destinationAttributesHandle, destinationPath);
            ValidateFileHandle(destinationHandle, _dispatchRootFinalPath, relativePath, "dispatch", true);
            sourceStream = new FileStream(sourceHandle, FileAccess.Read, CopyBufferSize, false);
            sourceHandle = null;
            destinationFileStream = new FileStream(destinationHandle, FileAccess.ReadWrite, CopyBufferSize, false);
            destinationHandle = null;
            destinationStream = destinationFileStream;
            if (destinationStreamDecorator != null)
            {
                destinationStream = destinationStreamDecorator(destinationStream);
                if (destinationStream == null) throw new IOException("目的檔串流包裝器回傳 null：" + relativePath);
            }
            return CopyWithRollback(sourceStream, destinationStream, destinationFileStream, relativePath);
        }
        catch (Exception exception)
        {
            pendingException = exception;
            throw;
        }
        finally
        {
            try
            {
                if (destinationStream != null) destinationStream.Dispose();
                else if (destinationFileStream != null) destinationFileStream.Dispose();
                else if (destinationHandle != null) destinationHandle.Dispose();
            }
            finally
            {
                try
                {
                    if (sourceStream != null) sourceStream.Dispose();
                    else if (sourceHandle != null) sourceHandle.Dispose();
                }
                finally
                {
                    try
                    {
                        if (destinationAttributesCaptured && destinationAttributesHandle != null &&
                            !destinationAttributesHandle.IsInvalid && !destinationAttributesHandle.IsClosed)
                        {
                            if (destinationAttributesRestoreProbe != null) destinationAttributesRestoreProbe();
                            uint currentDestinationAttributes = GetInformation(destinationAttributesHandle, "dispatch file").FileAttributes;
                            if (currentDestinationAttributes != originalDestinationAttributes)
                                SetFileAttributesByHandle(destinationAttributesHandle, originalDestinationAttributes, relativePath);
                        }
                    }
                    catch (Exception attributesRestoreException)
                    {
                        if (pendingException != null)
                            throw new IOException("原寫入失敗，且屬性還原也失敗：" + relativePath +
                                "；原失敗：" + pendingException.Message + "；屬性還原失敗：" + attributesRestoreException.Message,
                                new AggregateException(pendingException, attributesRestoreException));
                        throw;
                    }
                    finally
                    {
                        if (destinationAttributesHandle != null) destinationAttributesHandle.Dispose();
                    }
                }
            }
        }
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _sourceRootHandle.Dispose();
        _dispatchRootHandle.Dispose();
    }

    private static SafeFileHandle OpenRoot(string path, string label)
    {
        SafeFileHandle handle = CreateFileW(ToExtendedPath(path), FileReadAttributes,
            FileShareRead | FileShareWrite | FileShareDelete, IntPtr.Zero, OpenExisting,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero);
        if (handle == null || handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            if (handle != null) handle.Dispose();
            throw new IOException("無法以 handle 開啟" + label + "目錄：" + path, new Win32Exception(error));
        }
        try
        {
            ByHandleFileInformation information = GetInformation(handle, label + " root");
            if ((information.FileAttributes & FileAttributeDirectory) == 0) throw new IOException(label + " root 不是目錄：" + path);
            if ((information.FileAttributes & FileAttributeReparsePoint) != 0) throw new IOException(label + " root 是 reparse point：" + path);
            return handle;
        }
        catch { handle.Dispose(); throw; }
    }

    private static SafeFileHandle OpenFile(string path, uint access, uint share, string label)
    {
        SafeFileHandle handle = CreateFileW(ToExtendedPath(path), access, share, IntPtr.Zero, OpenExisting,
            FileFlagOpenReparsePoint | FileFlagSequentialScan, IntPtr.Zero);
        if (handle == null || handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            if (handle != null) handle.Dispose();
            throw new IOException("無法以 handle 開啟" + label + "檔案：" + path, new Win32Exception(error));
        }
        return handle;
    }

    private static SafeFileHandle ReOpenWritableFile(SafeFileHandle attributesHandle, string path)
    {
        SafeFileHandle handle = ReOpenFile(attributesHandle, GenericRead | GenericWrite, 0,
            FileFlagOpenReparsePoint | FileFlagSequentialScan);
        if (handle == null || handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            if (handle != null) handle.Dispose();
            throw new IOException("無法以 ReOpenFile 開啟 dispatch 寫入 handle：" + path, new Win32Exception(error));
        }
        return handle;
    }

    private static void SetFileAttributesByHandle(SafeFileHandle handle, uint fileAttributes, string relativePath)
    {
        FileBasicInformation information = new FileBasicInformation();
        information.FileAttributes = fileAttributes == 0 ? FileAttributeNormal : fileAttributes;
        uint informationSize = (uint)Marshal.SizeOf(typeof(FileBasicInformation));
        if (!SetFileInformationByHandle(handle, 0, ref information, informationSize))
            throw new IOException("無法以已驗證的 dispatch handle 設定檔案屬性：" + relativePath,
                new Win32Exception(Marshal.GetLastWin32Error()));
    }
    private static void ValidateFileHandle(SafeFileHandle handle, string rootFinalPath, string relativePath, string label, bool rejectHardLinks)
    {
        ByHandleFileInformation information = GetInformation(handle, label + " file");
        if ((information.FileAttributes & FileAttributeDirectory) != 0) throw new IOException(label + "路徑不是一般檔案：" + relativePath);
        if ((information.FileAttributes & FileAttributeReparsePoint) != 0) throw new IOException(label + "檔案是 reparse point：" + relativePath);
        if (rejectHardLinks && information.NumberOfLinks > 1)
            throw new IOException("dispatch 檔案是 hard link 別名（NumberOfLinks 大於 1）：" + relativePath);
        string actualFinalPath = GetFinalPath(handle, label + " file");
        string expectedFinalPath = AppendRelativePath(rootFinalPath, relativePath);
        if (!String.Equals(actualFinalPath, expectedFinalPath, StringComparison.OrdinalIgnoreCase))
            throw new IOException(label + "檔案 handle 最終路徑不符合 root 與相對路徑：" + relativePath);
    }

    private static ByHandleFileInformation GetInformation(SafeFileHandle handle, string label)
    {
        ByHandleFileInformation information;
        if (!GetFileInformationByHandle(handle, out information))
            throw new IOException("無法取得" + label + "的 handle 資訊。", new Win32Exception(Marshal.GetLastWin32Error()));
        return information;
    }

    private static string CopyWithRollback(Stream sourceStream, Stream destinationStream, FileStream destinationFileStream, string relativePath)
    {
        long originalLength = destinationStream.Length;
        byte[] originalBytes = null;
        if (originalLength <= RollbackBufferLimit)
        {
            originalBytes = new byte[(int)originalLength];
            destinationStream.Position = 0;
            int bytesSaved = 0;
            while (bytesSaved < originalBytes.Length)
            {
                int bytesRead = destinationStream.Read(originalBytes, bytesSaved, originalBytes.Length - bytesSaved);
                if (bytesRead == 0) throw new IOException("讀取原始 dispatch 目的檔時遇到非預期 EOF：" + relativePath);
                bytesSaved += bytesRead;
            }
        }

        try
        {
            if (originalBytes != null) destinationStream.SetLength(0);
            destinationStream.Position = 0;
            byte[] buffer = new byte[CopyBufferSize];
            long totalBytes = 0;
            using (SHA256 sha256 = SHA256.Create())
            {
                int bytesRead;
                while ((bytesRead = sourceStream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    sha256.TransformBlock(buffer, 0, bytesRead, buffer, 0);
                    destinationStream.Write(buffer, 0, bytesRead);
                    totalBytes += bytesRead;
                }
                sha256.TransformFinalBlock(new byte[0], 0, 0);
                destinationStream.SetLength(totalBytes);
                destinationStream.Flush();
                destinationFileStream.Flush(true);
                return ToLowerHex(sha256.Hash);
            }
        }
        catch (Exception copyException)
        {
            if (originalBytes == null) throw;
            try
            {
                destinationStream.Position = 0;
                destinationStream.SetLength(0);
                destinationStream.Write(originalBytes, 0, originalBytes.Length);
                destinationStream.SetLength(originalLength);
                destinationStream.Flush();
                destinationFileStream.Flush(true);
            }
            catch (Exception restoreException)
            {
                throw new IOException("dispatch 目的檔寫入失敗，且原始位元組回復也失敗：" + relativePath,
                    new AggregateException(copyException, restoreException));
            }
            throw new IOException("dispatch 目的檔寫入失敗，原始位元組已回復：" + relativePath, copyException);
        }
    }

    private static string GetFinalPath(SafeFileHandle handle, string label)
    {
        int size = PathBufferInitialSize;
        while (size <= PathBufferMaximumSize)
        {
            StringBuilder buffer = new StringBuilder(size);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0) throw new IOException("無法取得" + label + "的 final path。", new Win32Exception(Marshal.GetLastWin32Error()));
            if (length < buffer.Capacity) return TrimFinalPath(buffer.ToString());
            size = checked((int)length + 1);
        }
        throw new IOException(label + " final path 超過 Windows 路徑長度限制。");
    }

    private static string ToExtendedPath(string path)
    {
        string fullPath = Path.GetFullPath(path);
        if (fullPath.StartsWith("\\\\?\\", StringComparison.Ordinal)) return fullPath;
        if (fullPath.StartsWith("\\\\", StringComparison.Ordinal)) return "\\\\?\\UNC\\" + fullPath.Substring(2);
        return "\\\\?\\" + fullPath;
    }

    private static string TrimFinalPath(string path)
    {
        if (path.Length == 7 && path.StartsWith("\\\\?\\", StringComparison.Ordinal) && path[5] == ':') return path;
        return path.TrimEnd('\\', '/');
    }

    private static string AppendRelativePath(string rootPath, string relativePath)
    {
        string normalizedRelativePath = relativePath.Replace('/', '\\');
        if (rootPath.EndsWith("\\", StringComparison.Ordinal) || rootPath.EndsWith("/", StringComparison.Ordinal)) return rootPath + normalizedRelativePath;
        return rootPath + "\\" + normalizedRelativePath;
    }

    private static void ValidateRelativePath(string path)
    {
        if (String.IsNullOrEmpty(path) || path.IndexOf('\\') >= 0 || path.IndexOf(':') >= 0 || Path.IsPathRooted(path) || path.IndexOf('\0') >= 0)
            throw new IOException("Baseline 相對路徑異常：" + path);
        string[] parts = path.Split('/');
        for (int index = 0; index < parts.Length; index++)
            if (parts[index].Length == 0 || parts[index] == "." || parts[index] == ".." || parts[index] == ".git")
                throw new IOException("Baseline 相對路徑異常：" + path);
    }

    private static string ToLowerHex(byte[] bytes)
    {
        StringBuilder builder = new StringBuilder(bytes.Length * 2);
        for (int index = 0; index < bytes.Length; index++) builder.Append(bytes[index].ToString("x2"));
        return builder.ToString();
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException("DispatchBoundFileCopy");
    }
}
'@
}
    return $true
}

function Resolve-DispatchOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$CandidatePath,

        [AllowEmptyString()]
        [string]$SourceRoot,

        [AllowEmptyString()]
        [string]$ExecutionRoot,

        [string[]]$TargetPath = @()
    )

    try {
        $resolvedCandidate = Resolve-AbsolutePath -Path $CandidatePath
    }
    catch {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('candidate path 無法解析：' + $_.Exception.Message)
    }

    $candidateRoots = New-Object System.Collections.Generic.List[string]
    foreach ($rootValue in @($SourceRoot, $ExecutionRoot)) {
        if ([string]::IsNullOrWhiteSpace([string]$rootValue)) {
            continue
        }

        try {
            $resolvedRoot = Resolve-AbsolutePath -Path ([string]$rootValue)
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('root path 無法解析：' + $_.Exception.Message)
        }

        if (-not ($candidateRoots -contains $resolvedRoot)) {
            $candidateRoots.Add($resolvedRoot)
        }
    }

    if ($candidateRoots.Count -eq 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputRootUnavailable' -Message '未提供可驗證的 SourceRoot 或 ExecutionRoot。'
    }

    $containedRoots = New-Object System.Collections.Generic.List[string]
    foreach ($rootValue in $candidateRoots.ToArray()) {
        if (Test-PathWithinRoot -Path $resolvedCandidate -Root $rootValue) {
            $containedRoots.Add($rootValue)
        }
    }
    if ($containedRoots.Count -eq 0) {
        Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "candidate 不在 SourceRoot 或 ExecutionRoot 內：$resolvedCandidate"
    }

    foreach ($rootValue in $containedRoots.ToArray()) {
        if (-not (Test-Path -LiteralPath $rootValue -PathType Container)) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message "root 不存在或不是目錄：$rootValue"
        }

        Assert-DispatchOutputPathNoReparsePoint -Root $rootValue -Path $resolvedCandidate

        try {
            $gitState = Get-ExistingGitRepositoryState -SourceRoot $rootValue
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('Git tracked probe 無法判定：' + $_.Exception.Message)
        }

        if ($gitState.IsRepository -and -not (Test-Path -LiteralPath $resolvedCandidate -PathType Container)) {
            try {
                $trackedState = @(Get-TrackedPathState -SourceRoot $rootValue -TargetPath @($resolvedCandidate))
            }
            catch {
                Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('Git tracked probe 無法判定：' + $_.Exception.Message)
            }
            if (@($trackedState | Where-Object { $_.IsTracked }).Count -gt 0) {
                Throw-DispatchOutputFailure -Code 'DispatchOutputTrackedTarget' -Message "candidate 指向 tracked file：$resolvedCandidate"
            }
        }
    }

    $collisionRoot = if (-not [string]::IsNullOrWhiteSpace([string]$SourceRoot)) {
        Resolve-AbsolutePath -Path $SourceRoot
    }
    else {
        $candidateRoots[0]
    }
    foreach ($target in @($TargetPath)) {
        if ([string]::IsNullOrWhiteSpace([string]$target)) {
            continue
        }

        try {
            $resolvedTarget = Resolve-SourceTargetPath -Path ([string]$target) -Root $collisionRoot
        }
        catch {
            Throw-DispatchOutputFailure -Code 'DispatchOutputBoundary' -Message ('TargetPath 無法解析：' + $_.Exception.Message)
        }
        if (Test-PathWithinRoot -Path $resolvedCandidate -Root $resolvedTarget) {
            Throw-DispatchOutputFailure -Code 'DispatchOutputTargetCollision' -Message "candidate 命中 TargetPath：$resolvedCandidate; target=$resolvedTarget"
        }
    }

    return $resolvedCandidate
}

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

function Get-GitRepositoryState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $existingState = Get-ExistingGitRepositoryState -SourceRoot $SourceRoot
    if ($existingState.IsRepository) {
        return [ordered]@{
            GitOrigin = 'existing'
        }
    }

    $exception = New-Object System.InvalidOperationException('SourceRootNotGitRepository：SourceRoot 不是 Git 儲存庫。請先自行在 SourceRoot 執行 git init，再執行 Preflight。')
    $exception.Data['errorCode'] = 'SourceRootNotGitRepository'
    throw $exception
}

function Get-ExistingGitRepositoryState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot
    )

    $probe = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('-C', $SourceRoot, 'rev-parse', '--is-inside-work-tree') -AllowFailure
    if ($probe.ExitCode -eq 0 -and $probe.StdOut.Trim() -eq 'true') {
        return [ordered]@{
            IsRepository = $true
        }
    }

    $notRepository = $probe.StdErr -match '(?i)not a git repository|不是 git 儲存庫'
    if ($probe.ExitCode -ne 0 -and $notRepository) {
        return [ordered]@{
            IsRepository = $false
        }
    }

    throw "Git 前置探針失敗，未判定為可初始化的目錄。exit code $($probe.ExitCode)：$($probe.StdErr.Trim())"
}

function Get-GitOutputLines {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return @()
    }

    $nul = [char]0
    $values = @($Text -split $nul | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($values.Count -eq 1 -and $values[0] -notmatch [string]$nul) {
        $values = @($values[0] -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($values | ForEach-Object { $_.TrimEnd([char[]]@([char]13, [char]10)) })
}

function Get-DispatchTargetKind {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputPath,

        [Parameter(Mandatory)]
        [string]$FullPath,

        [Parameter(Mandatory)]
        [bool]$Exists
    )

    if ($Exists) {
        if (Test-Path -LiteralPath $FullPath -PathType Container) {
            return 'directory'
        }
        if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
            return 'file'
        }
        throw "無法判定 target_path 的實際類型：$FullPath"
    }

    if ($InputPath.EndsWith([string][char]92, [StringComparison]::Ordinal) -or $InputPath.EndsWith([string][char]47, [StringComparison]::Ordinal)) {
        return 'directory'
    }

    return 'file'
}

function Get-TrackedPathState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string[]]$TargetPath
    )

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($target in $TargetPath) {
        $fullPath = Resolve-SourceTargetPath -Path $target -Root $SourceRoot
        $relativePath = (Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot).TrimEnd([char[]]@([char]92, [char]47))
        if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = '.' }
        $trackedResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('ls-files', '--error-unmatch', '--', $relativePath) -AllowFailure
        $isTracked = $false
        if ($trackedResult.ExitCode -eq 0) {
            if ([string]::IsNullOrWhiteSpace($trackedResult.StdOut)) {
                throw "git ls-files 成功但未回傳 tracked 路徑：$relativePath"
            }
            $isTracked = $true
        }
        elseif ($trackedResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($trackedResult.StdOut) -and $trackedResult.StdErr -match '(?i)did not match any file|did not match any files|not match any file') {
            $isTracked = $false
        }
        else {
            throw "git ls-files 探針失敗，無法判定 tracked 狀態：$relativePath；exit code $($trackedResult.ExitCode)；$($trackedResult.StdErr.Trim())"
        }

        $ignoredResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('check-ignore', '--quiet', '--no-index', '--', $relativePath) -AllowFailure
        if ($ignoredResult.ExitCode -eq 0) {
            $isIgnored = $true
        }
        elseif ($ignoredResult.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($ignoredResult.StdErr)) {
            $isIgnored = $false
        }
        else {
            throw "git check-ignore 探針失敗，無法判定 ignored 狀態：$relativePath；exit code $($ignoredResult.ExitCode)；$($ignoredResult.StdErr.Trim())"
        }

        $exists = Test-Path -LiteralPath $fullPath
        $targetKind = Get-DispatchTargetKind -InputPath $target -FullPath $fullPath -Exists $exists
        $states.Add([pscustomobject]@{
                InputPath    = $target
                FullPath     = $fullPath
                RelativePath = $relativePath
                Exists       = $exists
                TargetKind   = $targetKind
                IsTracked    = $isTracked
                IsIgnored     = $isIgnored
                IsNewOutput   = -not $isTracked
            })
    }

    return @($states.ToArray())
}

function Get-NonGitTargetState {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string[]]$TargetPath
    )

    $states = New-Object System.Collections.Generic.List[object]
    foreach ($target in $TargetPath) {
        $fullPath = Resolve-SourceTargetPath -Path $target -Root $SourceRoot
        $relativePath = (Get-RelativePathFromRoot -Path $fullPath -Root $SourceRoot).TrimEnd([char[]]@([char]92, [char]47))
        if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = '.' }
        $exists = Test-Path -LiteralPath $fullPath
        $targetKind = Get-DispatchTargetKind -InputPath $target -FullPath $fullPath -Exists $exists
        $states.Add([pscustomobject]@{
                InputPath    = $target
                FullPath     = $fullPath
                RelativePath = $relativePath
                Exists       = $exists
                TargetKind   = $targetKind
                IsTracked    = $false
                IsIgnored    = $false
                IsNewOutput  = -not (Test-Path -LiteralPath $fullPath)
            })
    }

    return @($states.ToArray())
}

function Get-RequiredPreflightProperty {
    param(
        [Parameter(Mandatory)]
        [psobject]$Object,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value -or -not ($property.Value -is [string]) -or [string]::IsNullOrWhiteSpace($property.Value)) {
        throw "Preflight 輸出缺少必要欄位：$Name"
    }

    return $property.Value
}

function Test-DispatchSecretPathName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalizedPath = $Path.Replace('\', '/').TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        return $false
    }

    $fileName = $normalizedPath.Substring($normalizedPath.LastIndexOf('/') + 1)
    return $fileName -match '^(?i:(?:\.env(?:\..*)?|.*\.(?:pfx|pem|key)|secrets\..*))$'
}

function Apply-SourceCarryIn {
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $trackedFilesResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('diff', 'HEAD', '--name-only', '-z', '--no-ext-diff', '--no-renames', '--')
    $trackedFiles = @(Get-GitOutputLines -Text $trackedFilesResult.StdOut)
    $includedTrackedFiles = New-Object System.Collections.Generic.List[string]
    $excludedSecrets = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in $trackedFiles) {
        if (Test-DispatchSecretPathName -Path $relativePath) {
            $normalizedPath = $relativePath.Replace('\', '/')
            if (-not $excludedSecrets.Contains($normalizedPath)) {
                $excludedSecrets.Add($normalizedPath)
            }
            continue
        }

        $includedTrackedFiles.Add($relativePath)
    }

    $trackedPatch = ''
    if ($includedTrackedFiles.Count -gt 0) {
        $patchArguments = @('diff', 'HEAD', '--binary', '--no-ext-diff', '--no-renames', '--') + @($includedTrackedFiles.ToArray())
        $diffResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments $patchArguments
        $trackedPatch = $diffResult.StdOut
    }
    $untrackedResult = Invoke-GitCommand -WorkingDirectory $SourceRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    $untrackedFiles = @(Get-GitOutputLines -Text $untrackedResult.StdOut)
    $copiedFiles = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrEmpty($trackedPatch)) {
        $applyResult = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('apply', '--whitespace=nowarn', '--recount', '-') -StandardInput $trackedPatch -AllowFailure
        if ($applyResult.ExitCode -ne 0) {
            throw "套用來源 tracked patch 失敗，來源變更已保留。$($applyResult.StdErr.Trim())"
        }
    }

    foreach ($relativePath in $untrackedFiles) {
        if (Test-DispatchSecretPathName -Path $relativePath) {
            $normalizedPath = $relativePath.Replace('\', '/')
            if (-not $excludedSecrets.Contains($normalizedPath)) {
                $excludedSecrets.Add($normalizedPath)
            }
            continue
        }

        $sourcePath = Resolve-SourceTargetPath -Path $relativePath -Root $SourceRoot
        $destinationPath = Resolve-SourceTargetPath -Path $relativePath -Root $DispatchRoot
        if (-not (Test-PathWithinRoot -Path $sourcePath -Root $SourceRoot) -or -not (Test-PathWithinRoot -Path $destinationPath -Root $DispatchRoot)) {
            throw "未追蹤檔案路徑超出根目錄界線：$relativePath"
        }
        $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot '' -ExecutionRoot $DispatchRoot -TargetPath @()
        if (Test-Path -LiteralPath $destinationPath) {
            throw "未追蹤檔案目的路徑已存在，停止避免覆寫：$destinationPath"
        }
        $destinationParent = Split-Path -Parent $destinationPath
        $null = New-DispatchOutputDirectory -Path $destinationParent -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
        $destinationPath = Resolve-DispatchOutputPath -CandidatePath $destinationPath -SourceRoot '' -ExecutionRoot $DispatchRoot -TargetPath @()
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force:$false
        $copiedFiles.Add($relativePath)
    }

    return [ordered]@{
        TrackedPatchApplied = -not [string]::IsNullOrEmpty($trackedPatch)
        TrackedPatchLength  = $trackedPatch.Length
        UntrackedFiles      = @($untrackedFiles)
        CopiedFiles         = @($copiedFiles.ToArray())
        excludedSecrets     = @($excludedSecrets.ToArray())
    }
}

function Get-DispatchSnapshotPath {
    [CmdletBinding()]
    param(
        [string]$Root,
        [string]$Path,
        [System.Collections.Generic.HashSet[string]]$VerifiedDirectories,
        [switch]$SkipLeafCheck,
        [switch]$RootIsResolved
    )

    $invalidPath = [string]::IsNullOrEmpty($Path) -or $Path.Contains('\') -or $Path.Contains(':') -or [IO.Path]::IsPathRooted($Path)
    if (-not $invalidPath) {
        foreach ($pathPart in $Path.Split('/')) {
            if ($pathPart.Length -eq 0 -or $pathPart -in @('.', '..', '.git')) {
                $invalidPath = $true
                break
            }
        }
    }
    if ($invalidPath) {
        throw "Baseline 相對路徑異常：$Path"
    }
    if ($RootIsResolved) {
        if (-not [IO.Path]::IsPathRooted($Root)) { throw "Baseline root 必須是絕對路徑：$Root" }
        $rootPath = $Root
    }
    else {
        $rootPath = Resolve-AbsolutePath $Root
    }
    $current = $rootPath
    $parts = @('') + $Path.Split('/')
    for ($partIndex = 0; $partIndex -lt $parts.Count; $partIndex++) {
        $part = $parts[$partIndex]
        if ($part.Length -gt 0) { $current = Join-Path $current $part }
        $isLeaf = $partIndex -eq ($parts.Count - 1)
        if ($isLeaf -and $SkipLeafCheck) {
            continue
        }
        if (-not $isLeaf -and $null -ne $VerifiedDirectories -and $VerifiedDirectories.Contains($current)) {
            continue
        }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Baseline 不支援重解析點：$Path"
            }
            if (-not $isLeaf -and $null -ne $VerifiedDirectories -and $item.PSIsContainer) {
                $null = $VerifiedDirectories.Add($current)
            }
        }
    }
    if ($RootIsResolved) {
        $rootBoundary = $rootPath
        if (-not $rootBoundary.EndsWith([string][char]92, [StringComparison]::Ordinal) -and
            -not $rootBoundary.EndsWith([string][char]47, [StringComparison]::Ordinal)) {
            $rootBoundary += [IO.Path]::DirectorySeparatorChar
        }
        if (-not [string]::Equals($current, $rootPath, [StringComparison]::OrdinalIgnoreCase) -and
            -not $current.StartsWith($rootBoundary, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Baseline 路徑超出工作樹：$Path"
        }
    }
    elseif (-not (Test-PathWithinRoot $current $rootPath)) {
        throw "Baseline 路徑超出工作樹：$Path"
    }
    return $current
}
function Sync-DispatchTrackedRawBytesFromSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceRoot,

        [Parameter(Mandatory)]
        [string]$DispatchRoot
    )

    $trackedFilesResult = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '-z', '--')
    if ($trackedFilesResult.ExitCode -ne 0) {
        throw ('Preflight 無法列出 dispatch tracked 檔案：' + [string]$trackedFilesResult.StdErr.Trim())
    }
    $untrackedFilesResult = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '-z', '--others', '--exclude-standard', '--')
    if ($untrackedFilesResult.ExitCode -ne 0) {
        throw ('Preflight 無法列出 dispatch untracked 檔案：' + [string]$untrackedFilesResult.StdErr.Trim())
    }

    $trackedFileOutput = [string]$trackedFilesResult.StdOut
    $untrackedFileOutput = [string]$untrackedFilesResult.StdOut
    foreach ($fileOutput in @($trackedFileOutput, $untrackedFileOutput)) {
        if ($fileOutput.Length -gt 0 -and $fileOutput[$fileOutput.Length - 1] -ne [char]0) {
            throw 'Preflight dispatch 檔案清單格式異常。'
        }
    }

    $syncPaths = New-Object 'System.Collections.Generic.List[string]'
    $syncPathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($fileOutput in @($trackedFileOutput, $untrackedFileOutput)) {
        foreach ($relativePath in $fileOutput.Split([char]0)) {
            if ($relativePath.Length -gt 0 -and $syncPathSet.Add($relativePath)) {
                $syncPaths.Add($relativePath)
            }
        }
    }

    $sourceRootPath = Resolve-AbsolutePath -Path $SourceRoot
    $dispatchRootPath = Resolve-AbsolutePath -Path $DispatchRoot
    $sourceFastDirectoryCache = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $dispatchFastDirectoryCache = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $platformIsWindows = Test-IsWindowsPlatform
    $boundCopySession = $null
    $currentRelativePath = ''

    try {
        foreach ($relativePath in $syncPaths) {
            $currentRelativePath = $relativePath
            if (Test-DispatchSecretPathName -Path $relativePath) {
                continue
            }

            $sourceFilePath = Get-DispatchSnapshotPath -Root $sourceRootPath -Path $relativePath -VerifiedDirectories $sourceFastDirectoryCache -SkipLeafCheck -RootIsResolved
            $dispatchFilePath = Get-DispatchSnapshotPath -Root $dispatchRootPath -Path $relativePath -VerifiedDirectories $dispatchFastDirectoryCache -SkipLeafCheck -RootIsResolved

            $sourceFileInfo = New-Object -TypeName System.IO.FileInfo -ArgumentList $sourceFilePath
            $dispatchFileInfo = New-Object -TypeName System.IO.FileInfo -ArgumentList $dispatchFilePath
            $sourceFileInfo.Refresh()
            $dispatchFileInfo.Refresh()
            $sourcePathExists = $sourceFileInfo.Exists
            $dispatchPathExists = $dispatchFileInfo.Exists
            if (-not $sourcePathExists) { $sourcePathExists = [IO.Directory]::Exists((ConvertTo-FileSystemApiPath -Path $sourceFilePath)) }
            if (-not $dispatchPathExists) { $dispatchPathExists = [IO.Directory]::Exists((ConvertTo-FileSystemApiPath -Path $dispatchFilePath)) }
            if (-not $sourcePathExists -or -not $dispatchPathExists) {
                continue
            }
            if (-not $sourceFileInfo.Exists -or -not $dispatchFileInfo.Exists) {
                throw '來源或 dispatch 路徑不是一般檔案。'
            }

            $sourceAttributes = $sourceFileInfo.Attributes
            $dispatchAttributes = $dispatchFileInfo.Attributes
            if ((($sourceAttributes -band [IO.FileAttributes]::Directory) -ne 0) -or
                (($dispatchAttributes -band [IO.FileAttributes]::Directory) -ne 0)) {
                throw '來源或 dispatch 路徑不是一般檔案。'
            }
            if ((($sourceAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
                (($dispatchAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                throw '來源或 dispatch 路徑包含重解析點。'
            }
            if ($sourceFileInfo.Length -eq $dispatchFileInfo.Length) {
                continue
            }

            if (-not $platformIsWindows) {
                throw 'Preflight 起點原始位元組同步僅支援 Windows；非 Windows 平台拒絕覆寫長度不同的檔案。'
            }

            try {
                if ($null -eq $boundCopySession) {
                    $null = Initialize-DispatchBoundFileCopy
                    $boundCopySession = New-Object -TypeName DispatchBoundFileCopy -ArgumentList $sourceRootPath, $dispatchRootPath
                }
                $null = $boundCopySession.CopyBound($sourceFilePath, $dispatchFilePath, $relativePath)
            }
            catch {
                throw ('Preflight 起點原始位元組同步失敗：' + $currentRelativePath + '；' + $_.Exception.Message)
            }
        }
    }
    finally {
        if ($null -ne $boundCopySession) { $boundCopySession.Dispose() }
    }
}
function Get-DispatchWorkingTreeModes {
    [CmdletBinding()]
    param([string]$DispatchRoot)

    $result = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('diff-files', '--raw', '-z', '--')
    $parts = @($result.StdOut.Split([char]0) | Where-Object { $_.Length -gt 0 })
    if (($parts.Count % 2) -ne 0) { throw 'Baseline Git working tree mode 輸出格式異常。' }

    $modes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    for ($index = 0; $index -lt $parts.Count; $index += 2) {
        $header = $parts[$index]
        $path = $parts[$index + 1]
        if ($header -notmatch '^:(?<oldMode>[0-7]{6}) (?<newMode>[0-7]{6}) (?<oldObject>[0-9a-fA-F]{40,64}) (?<newObject>[0-9a-fA-F]{40,64}) (?<status>[A-Z])$' -or [string]::IsNullOrEmpty($path)) {
            throw 'Baseline Git working tree mode 輸出格式異常。'
        }
        if ($Matches.newMode -in @('100644', '100755')) {
            $modes[$path] = $Matches.newMode
        }
    }

    return $modes
}

function Get-DispatchFileSnapshot {
    [CmdletBinding()]
    param([string]$DispatchRoot, [string]$BaseSha, [string[]]$ApprovedAbsentPath = @(), [switch]$IncludeApprovedAbsentPath)

    if ($BaseSha -notmatch '^[a-fA-F0-9]{7,64}$') { throw 'Baseline baseSha 格式異常。' }
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    $modes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $tree = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-tree', '-r', '-z', $BaseSha, '--')
    foreach ($entry in $tree.StdOut.Split([char]0)) {
        if ($entry.Length -eq 0) { continue }
        $separator = $entry.IndexOf("`t")
        if ($separator -lt 0) { throw 'Baseline Git tree 輸出格式異常。' }
        $header = $entry.Substring(0, $separator).Split(' ')
        $path = $entry.Substring($separator + 1)
        if ($header.Count -ne 3 -or $header[0] -notin @('100644', '100755') -or $header[1] -ne 'blob') { throw "Baseline 不支援 Git kind：$path" }
        $null = $paths.Add($path)
        $modes[$path] = $header[0]
    }
    $index = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '--stage', '-z')
    foreach ($entry in $index.StdOut.Split([char]0)) {
        if ($entry.Length -eq 0) { continue }
        $separator = $entry.IndexOf("`t")
        if ($separator -lt 0) { throw 'Baseline Git index 輸出格式異常。' }
        $header = $entry.Substring(0, $separator).Split(' ')
        $path = $entry.Substring($separator + 1)
        if ($header.Count -ne 3 -or $header[0] -notin @('100644', '100755') -or $header[2] -ne '0') { throw "Baseline 不支援 Git kind 或未解決 index：$path" }
        $null = $paths.Add($path)
        $modes[$path] = $header[0]
    }
    $workingTreeModes = Get-DispatchWorkingTreeModes -DispatchRoot $DispatchRoot
    $untracked = Invoke-GitCommand -WorkingDirectory $DispatchRoot -Arguments @('ls-files', '--others', '--exclude-standard', '-z')
    foreach ($path in $untracked.StdOut.Split([char]0)) {
        if ($path.Length -eq 0) { continue }
        $null = $paths.Add($path)
        if (-not $modes.ContainsKey($path)) { $modes[$path] = '100644' }
    }
    foreach ($path in @($ApprovedAbsentPath)) {
        $fullPath = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $path
        if ($IncludeApprovedAbsentPath -or -not (Test-Path -LiteralPath $fullPath)) {
            if (Test-Path -LiteralPath $fullPath -PathType Container) { continue }
            $null = $paths.Add($path)
            if (-not $modes.ContainsKey($path)) { $modes[$path] = '100644' }
        }
    }
    foreach ($path in $paths) {
        $fullPath = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $path
        $exists = Test-Path -LiteralPath $fullPath
        $length = 0L
        $hash = $null
        if ($exists) {
            $item = Get-Item -LiteralPath $fullPath -Force
            if ($item.PSIsContainer) { throw "Baseline 不支援目錄 kind：$path" }
            $length = $item.Length
            $hash = Get-FileSha256 $fullPath
        }
        $gitMode = $modes[$path]
        if ($workingTreeModes.ContainsKey($path)) { $gitMode = $workingTreeModes[$path] }
        [pscustomobject]@{ path = $path; kind = 'file'; exists = [bool]$exists; byte_length = $length; sha256 = $hash; git_mode = $gitMode }
    }
}

function New-DispatchBaseline {
    [CmdletBinding()]
    param(
        [string]$SourceRoot, [string]$DispatchRoot,
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$LineSlug,
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$DispatchSlug,
        [string]$BaseSha,
        [string[]]$TargetPath = @()
    )

    $approvedAbsentPaths = @($TargetPath | ForEach-Object {
        $sourcePath = Resolve-SourceTargetPath -Path $_ -Root $SourceRoot
        Assert-DispatchOutputPathNoReparsePoint -Root $SourceRoot -Path $sourcePath
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            $relativePath = (Get-RelativePathFromRoot -Path $sourcePath -Root $SourceRoot).Replace('\', '/').TrimEnd([char]'/')
            if (-not [string]::IsNullOrWhiteSpace($relativePath)) { $relativePath }
        }
    })
    $record = [ordered]@{
        schema = 'ai-sessions.dispatch-baseline.v1'
        baseline_id = [guid]::NewGuid().ToString('D')
        line_slug = $LineSlug
        dispatch_slug = $DispatchSlug
        source_root = Resolve-AbsolutePath $SourceRoot
        dispatch_root = Resolve-AbsolutePath $DispatchRoot
        base_sha = $BaseSha
        created_at_utc = [datetime]::UtcNow.ToString('o')
        files = @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $BaseSha -ApprovedAbsentPath $approvedAbsentPaths)
    }
    $directory = Join-Path (Join-Path (Join-Path $record.source_root '.local/ai-sessions/history') $LineSlug) 'baselines'
    $null = New-DispatchOutputDirectory -Path $directory -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    $path = Join-Path $directory ($DispatchSlug + '-' + $record.baseline_id + '.json')
    $temporaryPath = Join-Path $directory ([guid]::NewGuid().ToString('D') + '.tmp')
    Write-Utf8NoBom -Path $temporaryPath -Content (($record | ConvertTo-Json -Depth 12) + "`n") -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    $temporaryPath = Resolve-DispatchOutputPath -CandidatePath $temporaryPath -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    $path = Resolve-DispatchOutputPath -CandidatePath $path -SourceRoot $SourceRoot -ExecutionRoot $DispatchRoot -TargetPath @()
    [IO.File]::Move((ConvertTo-FileSystemApiPath -Path $temporaryPath), (ConvertTo-FileSystemApiPath -Path $path))
    return [pscustomobject]@{ Path = $path; Sha256 = Get-FileSha256 $path }
}

function Read-DispatchBaseline {
    [CmdletBinding()]
    param([string]$Path, [string]$Sha256, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$BaseSha)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '缺少有效 Baseline 路徑或 SHA-256。' }
    $pathValue = Resolve-AbsolutePath $Path
    if ((Get-FileSha256 $pathValue) -ine $Sha256) { throw 'Baseline SHA-256 不一致。' }
    $record = ConvertFrom-DispatchJson -Content (Get-Content -LiteralPath $pathValue -Raw -Encoding UTF8)
    if ($null -eq $record -or $record -isnot [pscustomobject]) { throw 'Baseline 必須為 JSON object。' }
    foreach ($name in @('schema', 'baseline_id', 'line_slug', 'dispatch_slug', 'source_root', 'dispatch_root', 'base_sha', 'created_at_utc')) {
        $property = $record.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [string] -or [string]::IsNullOrWhiteSpace($property.Value)) { throw "Baseline 欄位異常：$name" }
    }
    $id = [guid]::Empty
    $created = [datetimeoffset]::MinValue
    if (-not [guid]::TryParseExact($record.baseline_id, 'D', [ref]$id) -or $record.created_at_utc -notmatch '^\d{4}-\d{2}-\d{2}T.*(?:Z|\+00:00)$' -or -not [datetimeoffset]::TryParse($record.created_at_utc, [ref]$created) -or $created.Offset -ne [timespan]::Zero) { throw 'Baseline ID 或 UTC 時間異常。' }
    if ($record.schema -cne 'ai-sessions.dispatch-baseline.v1' -or $record.line_slug -cne $LineSlug -or $record.dispatch_slug -cne $DispatchSlug -or $record.base_sha -cne $BaseSha) { throw 'Baseline schema／line／dispatch／baseSha 不一致。' }
    foreach ($entry in @(@('source_root', $SourceRoot), @('dispatch_root', $DispatchRoot))) {
        if (-not [string]::Equals($record.($entry[0]), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline roots 不一致。' }
    }
    $directory = Join-Path (Join-Path (Join-Path (Resolve-AbsolutePath $SourceRoot) '.local/ai-sessions/history') $LineSlug) 'baselines'
    $expectedPath = Join-Path $directory ($DispatchSlug + '-' + $record.baseline_id + '.json')
    if (-not [string]::Equals($pathValue, $expectedPath, [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline 路徑與身分不一致。' }
    $filesProperty = $record.PSObject.Properties['files']
    if ($null -eq $filesProperty -or $filesProperty.Value -isnot [array]) { throw 'Baseline files 必須為陣列。' }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $previousPath = $null
    foreach ($file in $record.files) {
        if ($null -eq $file -or $file -isnot [pscustomobject]) { throw 'Baseline file 必須為 object。' }
        foreach ($name in @('path', 'kind', 'exists', 'byte_length', 'sha256', 'git_mode')) {
            if ($null -eq $file.PSObject.Properties[$name]) { throw "Baseline file 缺少欄位：$name" }
        }
        if ($file.path -isnot [string] -or -not $seen.Add($file.path) -or ($null -ne $previousPath -and [string]::CompareOrdinal($previousPath, $file.path) -ge 0)) { throw 'Baseline file 路徑重複或未排序。' }
        $null = Get-DispatchSnapshotPath -Root $DispatchRoot -Path $file.path
        $previousPath = $file.path
        if ($file.kind -cne 'file' -or $file.exists -isnot [bool] -or $file.git_mode -cnotin @('100644', '100755') -or ($file.byte_length -isnot [int] -and $file.byte_length -isnot [long]) -or $file.byte_length -lt 0) { throw "Baseline file kind／狀態異常：$($file.path)" }
        if ($file.exists) {
            if ($file.sha256 -isnot [string] -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Baseline file hash 異常：$($file.path)" }
        }
        elseif ($null -ne $file.sha256 -or $file.byte_length -ne 0) { throw "Baseline absent 欄位異常：$($file.path)" }
    }
    return $record
}

function Get-DispatchIncrementalChanges {
    [CmdletBinding()]
    param([psobject]$Baseline, [string]$DispatchRoot)

    $before = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $after = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $paths = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
    foreach ($file in $Baseline.files) { $before[$file.path] = $file; $null = $paths.Add($file.path) }
    $approvedAbsentPaths = @($Baseline.files | Where-Object { -not $_.exists } | ForEach-Object { [string]$_.path })
    foreach ($file in @(Get-DispatchFileSnapshot -DispatchRoot $DispatchRoot -BaseSha $Baseline.base_sha -ApprovedAbsentPath $approvedAbsentPaths -IncludeApprovedAbsentPath)) { $after[$file.path] = $file; $null = $paths.Add($file.path) }
    foreach ($path in $paths) {
        $old = if ($before.ContainsKey($path)) { $before[$path] } else { $null }
        $new = if ($after.ContainsKey($path)) { $after[$path] } else { $null }
        $oldExists = $null -ne $old -and $old.exists
        $newExists = $null -ne $new -and $new.exists
        if ($oldExists -ne $newExists -or ($oldExists -and ($old.kind -cne $new.kind -or $old.git_mode -cne $new.git_mode -or $old.byte_length -ne $new.byte_length -or $old.sha256 -ine $new.sha256))) { $path }
    }
}

function Resolve-DispatchBaselineBinding {
    [CmdletBinding()]
    param([psobject]$Preflight, [string]$SourceRoot, [string]$DispatchRoot, [string]$LineSlug, [string]$DispatchSlug, [string]$BaseSha, [string]$Path, [string]$Sha256)

    if ($null -ne $Preflight) {
        foreach ($entry in @(@('sourceRoot', $SourceRoot), @('executionRoot', $DispatchRoot), @('dispatchRoot', $DispatchRoot))) {
            if (-not [string]::Equals((Get-RequiredPreflightProperty $Preflight $entry[0]), (Resolve-AbsolutePath $entry[1]), [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline Preflight roots 不一致。' }
        }
        foreach ($entry in @(@('lineSlug', $LineSlug), @('dispatchSlug', $DispatchSlug), @('baseSha', $BaseSha))) {
            if ((Get-RequiredPreflightProperty $Preflight $entry[0]) -cne $entry[1]) { throw 'Baseline Preflight 身分或 baseSha 不一致。' }
        }
        $boundPath = Get-RequiredPreflightProperty $Preflight 'baselinePath'
        $boundHash = Get-RequiredPreflightProperty $Preflight 'baselineSha256'
        if ((-not [string]::IsNullOrWhiteSpace($Path) -and -not [string]::Equals((Resolve-AbsolutePath $Path), $boundPath, [StringComparison]::OrdinalIgnoreCase)) -or (-not [string]::IsNullOrWhiteSpace($Sha256) -and $Sha256 -ine $boundHash)) { throw 'Baseline 顯式輸入與 Preflight 不一致。' }
        $Path = $boundPath
        $Sha256 = $boundHash
    }
    $record = Read-DispatchBaseline -Path $Path -Sha256 $Sha256 -SourceRoot $SourceRoot -DispatchRoot $DispatchRoot -LineSlug $LineSlug -DispatchSlug $DispatchSlug -BaseSha $BaseSha
    return [pscustomobject]@{ Path = Resolve-AbsolutePath $Path; Sha256 = $Sha256; Record = $record }
}
