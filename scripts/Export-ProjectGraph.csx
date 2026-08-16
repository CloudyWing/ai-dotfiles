#!/usr/bin/env dotnet-script
// 前置需求：dotnet tool install -g dotnet-script
#r "nuget: Microsoft.CodeAnalysis.CSharp.Workspaces, 4.11.0"
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

Console.OutputEncoding = Encoding.UTF8;

if (Args.Count != 1)
{
    Console.Error.WriteLine("用法：dotnet script Export-ProjectGraph.csx -- <solution.sln-or-slnx>");
    Environment.Exit(1);
}

try
{
    string solutionPath = Path.GetFullPath(Args[0]);
    List<string> projectPaths = LoadProjectPaths(solutionPath);
    Dictionary<string, ProjectId> projectIds = projectPaths.ToDictionary(
        path => path,
        _ => ProjectId.CreateNewId(),
        StringComparer.OrdinalIgnoreCase);

    using AdhocWorkspace workspace = new();
    Solution solution = CreateSolution(workspace, projectPaths, projectIds);
    string solutionDirectory = Path.GetDirectoryName(solutionPath) ?? Directory.GetCurrentDirectory();
    string outputPath = Path.Combine(solutionDirectory, ".local", "ai-context", "project-graph.md");
    WriteReport(outputPath, solutionPath, solution);
    Console.WriteLine($"已輸出專案相依圖：{outputPath}");
}
catch (Exception exception)
{
    Console.Error.WriteLine($"輸出專案相依圖失敗：{exception.Message}");
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

static Solution CreateSolution(
    AdhocWorkspace workspace,
    IEnumerable<string> projectPaths,
    IReadOnlyDictionary<string, ProjectId> projectIds)
{
    Solution solution = workspace.CurrentSolution;

    foreach (string projectPath in projectPaths)
    {
        string projectName = Path.GetFileNameWithoutExtension(projectPath);
        ProjectInfo projectInfo = ProjectInfo.Create(
            projectIds[projectPath],
            VersionStamp.Create(),
            projectName,
            projectName,
            LanguageNames.CSharp,
            filePath: projectPath,
            compilationOptions: new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary),
            parseOptions: CSharpParseOptions.Default.WithLanguageVersion(LanguageVersion.Latest));

        solution = solution.AddProject(projectInfo);
    }

    foreach (string projectPath in projectPaths)
    {
        List<ProjectReference> references = LoadProjectReferences(projectPath, projectIds);
        if (references.Count > 0)
        {
            solution = solution.AddProjectReferences(projectIds[projectPath], references);
        }
    }

    return solution;
}

static List<ProjectReference> LoadProjectReferences(
    string projectPath,
    IReadOnlyDictionary<string, ProjectId> projectIds)
{
    string projectDirectory = Path.GetDirectoryName(projectPath) ?? Directory.GetCurrentDirectory();
    XDocument projectDocument = XDocument.Load(projectPath, LoadOptions.PreserveWhitespace);
    List<ProjectReference> references = new();

    foreach (XElement referenceElement in projectDocument.Descendants()
                 .Where(element => element.Name.LocalName.Equals("ProjectReference", StringComparison.OrdinalIgnoreCase)))
    {
        XAttribute? includeAttribute = referenceElement.Attribute("Include");
        if (includeAttribute is null)
        {
            continue;
        }

        string referencePath = Path.GetFullPath(Path.Combine(
            projectDirectory,
            includeAttribute.Value.Replace('\\', Path.DirectorySeparatorChar)));

        if (projectIds.TryGetValue(referencePath, out ProjectId? referenceId) && referenceId is not null)
        {
            references.Add(new ProjectReference(referenceId));
        }
    }

    return references;
}

static void WriteReport(
    string outputPath,
    string solutionPath,
    Solution solution)
{
    string? outputDirectory = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDirectory))
    {
        Directory.CreateDirectory(outputDirectory);
    }

    Dictionary<ProjectId, Project> projects = solution.Projects.ToDictionary(project => project.Id);
    Dictionary<ProjectId, string> mermaidIds = solution.Projects
        .OrderBy(project => project.FilePath ?? project.Name, StringComparer.OrdinalIgnoreCase)
        .Select((project, index) => new { project.Id, MermaidId = $"Project_{index + 1}" })
        .ToDictionary(item => item.Id, item => item.MermaidId);
    StringBuilder report = new();
    report.AppendLine("# 專案相依圖");
    report.AppendLine();
    report.AppendLine($"來源方案：`{Path.GetFileName(solutionPath)}`");
    report.AppendLine();
    report.AppendLine("```mermaid");
    report.AppendLine("flowchart LR");

    foreach (Project project in solution.Projects.OrderBy(project => project.Name, StringComparer.OrdinalIgnoreCase))
    {
        report.AppendLine($"    {mermaidIds[project.Id]}[\"{EscapeMermaid(project.Name)}\"]");
    }

    bool hasReference = false;
    foreach (Project project in solution.Projects.OrderBy(project => project.Name, StringComparer.OrdinalIgnoreCase))
    {
        foreach (ProjectReference reference in project.ProjectReferences)
        {
            if (!projects.TryGetValue(reference.ProjectId, out Project? referencedProject) || referencedProject is null)
            {
                continue;
            }

            report.AppendLine($"    {mermaidIds[project.Id]} --> {mermaidIds[referencedProject.Id]}");
            hasReference = true;
        }
    }

    if (!hasReference)
    {
        report.AppendLine("    NoReference[\"無專案相依\"]");
    }

    report.AppendLine("```");
    report.AppendLine();
    report.AppendLine("| 專案 | 相依專案 |");
    report.AppendLine("| --- | --- |");

    foreach (Project project in solution.Projects.OrderBy(project => project.Name, StringComparer.OrdinalIgnoreCase))
    {
        List<string> referencedNames = project.ProjectReferences
            .Where(reference => projects.ContainsKey(reference.ProjectId))
            .Select(reference => projects[reference.ProjectId].Name)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToList();

        string referencesText = referencedNames.Count == 0
            ? "（無）"
            : string.Join(", ", referencedNames.Select(name => $"`{EscapeMarkdown(name)}`"));
        report.AppendLine($"| `{EscapeMarkdown(project.Name)}` | {referencesText} |");
    }

    File.WriteAllText(outputPath, report.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
}

static string EscapeMarkdown(string value)
{
    return value.Replace("|", "\\|");
}

static string EscapeMermaid(string value)
{
    return value.Replace("\"", "'");
}
