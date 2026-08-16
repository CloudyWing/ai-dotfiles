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
    Console.Error.WriteLine("用法：dotnet script Export-TypeHierarchy.csx -- <solution.sln-or-slnx>");
    Environment.Exit(1);
}

try
{
    string solutionPath = Path.GetFullPath(Args[0]);
    List<string> projectPaths = LoadProjectPaths(solutionPath);
    List<TypeHierarchyEntry> hierarchy = new();

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
                         .Where(declaration => declaration is not EnumDeclarationSyntax))
            {
                BaseListSyntax? baseList = declaration.BaseList;
                string baseTypes = baseList is null
                    ? "（無明確基底型別）"
                    : string.Join(
                        ", ",
                        baseList.Types.Select(baseType => baseType.Type.ToString()));

                hierarchy.Add(new TypeHierarchyEntry(
                    projectName,
                    GetQualifiedName(declaration),
                    GetTypeKind(declaration),
                    GetAccessibility(declaration),
                    baseTypes,
                    GetRelativePath(projectDirectory, sourcePath)));
            }
        }
    }

    string solutionDirectory = Path.GetDirectoryName(solutionPath) ?? Directory.GetCurrentDirectory();
    string outputPath = Path.Combine(solutionDirectory, ".local", "ai-context", "type-hierarchy.md");
    WriteReport(outputPath, solutionPath, hierarchy);
    Console.WriteLine($"已輸出型別繼承關係：{outputPath}");
}
catch (Exception exception)
{
    Console.Error.WriteLine($"輸出型別繼承關係失敗：{exception.Message}");
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

    if (declaration.Modifiers.Any(SyntaxKind.PrivateKeyword))
    {
        return "private";
    }

    return "internal";
}

static string GetRelativePath(string baseDirectory, string sourcePath)
{
    return Path.GetRelativePath(baseDirectory, sourcePath).Replace(Path.DirectorySeparatorChar, '/');
}

static void WriteReport(string outputPath, string solutionPath, IEnumerable<TypeHierarchyEntry> entries)
{
    string? outputDirectory = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDirectory))
    {
        Directory.CreateDirectory(outputDirectory);
    }

    StringBuilder report = new();
    report.AppendLine("# 型別繼承關係");
    report.AppendLine();
    report.AppendLine($"來源方案：`{Path.GetFileName(solutionPath)}`");
    report.AppendLine();
    report.AppendLine("| 專案 | 型別 | 種類 | 存取層級 | 明確基底型別或介面 | 來源檔案 |");
    report.AppendLine("| --- | --- | --- | --- | --- | --- |");

    List<TypeHierarchyEntry> orderedEntries = entries
        .OrderBy(entry => entry.Project, StringComparer.OrdinalIgnoreCase)
        .ThenBy(entry => entry.QualifiedName, StringComparer.OrdinalIgnoreCase)
        .ToList();

    if (orderedEntries.Count == 0)
    {
        report.AppendLine("| （無） | 尚未找到型別宣告 |  |  |  |  |");
    }
    else
    {
        foreach (TypeHierarchyEntry entry in orderedEntries)
        {
            report.AppendLine($"| {EscapeMarkdown(entry.Project)} | `{EscapeMarkdown(entry.QualifiedName)}` | {entry.Kind} | {entry.Accessibility} | `{EscapeMarkdown(entry.BaseTypes)}` | `{EscapeMarkdown(entry.SourcePath)}` |");
        }
    }

    File.WriteAllText(outputPath, report.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
}

static string EscapeMarkdown(string value)
{
    return value.Replace("|", "\\|");
}

internal sealed record TypeHierarchyEntry(
    string Project,
    string QualifiedName,
    string Kind,
    string Accessibility,
    string BaseTypes,
    string SourcePath);
