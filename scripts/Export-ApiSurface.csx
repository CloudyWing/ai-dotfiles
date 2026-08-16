#!/usr/bin/env dotnet-script
// 前置需求：dotnet tool install -g dotnet-script
#r "nuget: Microsoft.CodeAnalysis.CSharp, 4.11.0"
#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

Console.OutputEncoding = Encoding.UTF8;

if (Args.Count != 1)
{
    Console.Error.WriteLine("用法：dotnet script Export-ApiSurface.csx -- <solution.sln-or-slnx>");
    Environment.Exit(1);
}

try
{
    string solutionPath = Path.GetFullPath(Args[0]);
    List<string> projectPaths = LoadProjectPaths(solutionPath);
    List<ApiType> apiTypes = new();

    foreach (string projectPath in projectPaths)
    {
        string projectName = Path.GetFileNameWithoutExtension(projectPath);
        string projectDirectory = Path.GetDirectoryName(projectPath) ?? Directory.GetCurrentDirectory();

        foreach (string sourcePath in EnumerateSourceFiles(projectDirectory))
        {
            SyntaxTree syntaxTree = CSharpSyntaxTree.ParseText(
                File.ReadAllText(sourcePath),
                CSharpParseOptions.Default.WithLanguageVersion(LanguageVersion.Latest),
                sourcePath);

            foreach (BaseTypeDeclarationSyntax declaration in syntaxTree.GetRoot()
                         .DescendantNodes()
                         .OfType<BaseTypeDeclarationSyntax>()
                         .Where(IsPublicSurface))
            {
                apiTypes.Add(new ApiType(
                    projectName,
                    GetQualifiedName(declaration),
                    GetTypeKind(declaration),
                    GetAccessibility(declaration),
                    GetRelativePath(projectDirectory, sourcePath)));
            }
        }
    }

    string solutionDirectory = Path.GetDirectoryName(solutionPath) ?? Directory.GetCurrentDirectory();
    string outputPath = Path.Combine(solutionDirectory, ".local", "ai-context", "api-surface.md");
    WriteReport(outputPath, solutionPath, apiTypes);
    Console.WriteLine($"已輸出公開 API 表面：{outputPath}");
}
catch (Exception exception)
{
    Console.Error.WriteLine($"輸出公開 API 表面失敗：{exception.Message}");
    Environment.Exit(1);
}

static List<string> LoadProjectPaths(string solutionPath)
{
    if (!File.Exists(solutionPath))
    {
        throw new FileNotFoundException($"找不到方案檔：{solutionPath}");
    }

    string solutionDirectory = Path.GetDirectoryName(solutionPath) ?? Directory.GetCurrentDirectory();
    List<string> projectPaths = new();
    if (Path.GetExtension(solutionPath).Equals(".slnx", StringComparison.OrdinalIgnoreCase))
    {
        XDocument solutionDocument = XDocument.Load(solutionPath);
        foreach (XElement projectElement in solutionDocument.Descendants()
                     .Where(element => element.Name.LocalName.Equals("Project", StringComparison.OrdinalIgnoreCase)))
        {
            XAttribute? pathAttribute = projectElement.Attribute("Path");
            if (pathAttribute is null)
            {
                continue;
            }

            string projectPath = Path.GetFullPath(Path.Combine(
                solutionDirectory,
                pathAttribute.Value.Replace('\\', Path.DirectorySeparatorChar)));
            if (File.Exists(projectPath))
            {
                projectPaths.Add(projectPath);
            }
        }
    }
    else
    {
        string solutionText = File.ReadAllText(solutionPath);
        MatchCollection matches = Regex.Matches(
            solutionText,
            "Project\\(\\\"[^\\\"]+\\\"\\)\\s*=\\s*\\\"[^\\\"]+\\\",\\s*\\\"([^\\\"]+\\.csproj)\\\"",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        projectPaths.AddRange(matches
            .Select(match => match.Groups[1].Value.Replace('\\', Path.DirectorySeparatorChar))
            .Select(relativePath => Path.GetFullPath(Path.Combine(solutionDirectory, relativePath)))
            .Where(File.Exists));
    }

    projectPaths = projectPaths
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
        .ToList();

    if (projectPaths.Count == 0)
    {
        throw new InvalidDataException("方案中沒有可讀取的 C# 專案參考。");
    }

    return projectPaths;
}

static IEnumerable<string> EnumerateSourceFiles(string projectDirectory)
{
    return Directory.EnumerateFiles(projectDirectory, "*.cs", SearchOption.AllDirectories)
        .Where(path => path.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .All(segment => !segment.Equals("bin", StringComparison.OrdinalIgnoreCase)
                            && !segment.Equals("obj", StringComparison.OrdinalIgnoreCase)
                            && !segment.Equals(".git", StringComparison.OrdinalIgnoreCase)))
        .OrderBy(path => path, StringComparer.OrdinalIgnoreCase);
}

static bool IsPublicSurface(BaseTypeDeclarationSyntax declaration)
{
    return HasPublicApiAccessibility(declaration)
        && declaration.Ancestors()
            .OfType<BaseTypeDeclarationSyntax>()
            .All(HasPublicApiAccessibility);
}

static bool HasPublicApiAccessibility(BaseTypeDeclarationSyntax declaration)
{
    SyntaxTokenList modifiers = declaration.Modifiers;
    return !modifiers.Any(SyntaxKind.PrivateKeyword)
        && (modifiers.Any(SyntaxKind.PublicKeyword) || modifiers.Any(SyntaxKind.ProtectedKeyword));
}

static string GetQualifiedName(BaseTypeDeclarationSyntax declaration)
{
    List<string> names = declaration.Ancestors()
        .OfType<BaseTypeDeclarationSyntax>()
        .Reverse()
        .Select(GetTypeIdentifier)
        .ToList();

    names.Add(GetTypeIdentifier(declaration));

    string namespaceName = string.Join(
        ".",
        declaration.Ancestors()
            .OfType<BaseNamespaceDeclarationSyntax>()
            .Reverse()
            .Select(namespaceDeclaration => namespaceDeclaration.Name.ToString()));

    if (!string.IsNullOrWhiteSpace(namespaceName))
    {
        names.Insert(0, namespaceName);
    }

    return string.Join(".", names);
}

static string GetTypeIdentifier(BaseTypeDeclarationSyntax declaration)
{
    return declaration switch
    {
        EnumDeclarationSyntax enumDeclaration => enumDeclaration.Identifier.ValueText,
        _ => ((TypeDeclarationSyntax)declaration).Identifier.ValueText
    };
}

static string GetTypeKind(BaseTypeDeclarationSyntax declaration)
{
    return declaration switch
    {
        ClassDeclarationSyntax => "class",
        InterfaceDeclarationSyntax => "interface",
        StructDeclarationSyntax => "struct",
        EnumDeclarationSyntax => "enum",
        RecordDeclarationSyntax recordDeclaration when recordDeclaration.ClassOrStructKeyword.IsKind(SyntaxKind.StructKeyword) => "record struct",
        RecordDeclarationSyntax => "record class",
        _ => "type"
    };
}

static string GetAccessibility(BaseTypeDeclarationSyntax declaration)
{
    if (declaration.Modifiers.Any(SyntaxKind.PublicKeyword))
    {
        return "public";
    }

    if (declaration.Modifiers.Any(SyntaxKind.ProtectedKeyword))
    {
        return declaration.Modifiers.Any(SyntaxKind.InternalKeyword)
            ? "protected internal"
            : "protected";
    }

    return "internal";
}

static string GetRelativePath(string baseDirectory, string sourcePath)
{
    return Path.GetRelativePath(baseDirectory, sourcePath).Replace(Path.DirectorySeparatorChar, '/');
}

static void WriteReport(string outputPath, string solutionPath, IEnumerable<ApiType> apiTypes)
{
    string? outputDirectory = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDirectory))
    {
        Directory.CreateDirectory(outputDirectory);
    }

    StringBuilder report = new();
    report.AppendLine("# 公開 API 表面");
    report.AppendLine();
    report.AppendLine($"來源方案：`{Path.GetFileName(solutionPath)}`");
    report.AppendLine();
    report.AppendLine("| 專案 | 型別 | 種類 | 存取層級 | 來源檔案 |");
    report.AppendLine("| --- | --- | --- | --- | --- |");

    List<ApiType> orderedTypes = apiTypes
        .OrderBy(apiType => apiType.Project, StringComparer.OrdinalIgnoreCase)
        .ThenBy(apiType => apiType.QualifiedName, StringComparer.OrdinalIgnoreCase)
        .ToList();

    if (orderedTypes.Count == 0)
    {
        report.AppendLine("| （無） | 尚未找到 public 或 protected 型別 |  |  |  |");
    }
    else
    {
        foreach (ApiType apiType in orderedTypes)
        {
            report.AppendLine($"| {EscapeMarkdown(apiType.Project)} | `{EscapeMarkdown(apiType.QualifiedName)}` | {apiType.Kind} | {apiType.Accessibility} | `{EscapeMarkdown(apiType.SourcePath)}` |");
        }
    }

    File.WriteAllText(outputPath, report.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
}

static string EscapeMarkdown(string value)
{
    return value.Replace("|", "\\|");
}

internal sealed record ApiType(
    string Project,
    string QualifiedName,
    string Kind,
    string Accessibility,
    string SourcePath);
