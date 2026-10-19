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

if (Args.Count is < 1 or > 2) {
    Console.Error.WriteLine("用法：dotnet script Export-ProjectGraph.csx -- <solution.sln-or-slnx> [outputPath]");
    Environment.Exit(1);
}

try {
    string solutionPath = Path.GetFullPath(Args[0]);
    List<string> projectPaths = LoadProjectPaths(solutionPath);
    Dictionary<string, ProjectId> projectIds = projectPaths.ToDictionary(
        path => path,
        _ => ProjectId.CreateNewId(),
        StringComparer.OrdinalIgnoreCase
    );

    using AdhocWorkspace workspace = new();
    List<(string ProjectName, string Include)> unresolvedReferences = new();
    Solution solution = CreateSolution(workspace, projectPaths, projectIds, unresolvedReferences);
    string solutionDirectory = Path.GetDirectoryName(solutionPath) ?? Directory.GetCurrentDirectory();
    string outputPath = Args.Count == 2
        ? Path.GetFullPath(Args[1])
        : Path.Combine(solutionDirectory, ".local", "ai-context", "project-graph.md");
    WriteReport(outputPath, solutionPath, solution, unresolvedReferences);
    Console.WriteLine($"已輸出專案相依圖：{outputPath}");
} catch (Exception exception) {
    Console.Error.WriteLine($"輸出專案相依圖失敗：{exception.Message}");
    Environment.Exit(1);
}

static List<string> LoadProjectPaths(string solutionPath) {
    if (!File.Exists(solutionPath)) {
        throw new FileNotFoundException($"找不到方案檔：{solutionPath}");
    }

    string solutionDirectory = Path.GetDirectoryName(solutionPath) ?? Directory.GetCurrentDirectory();
    List<string> projectPaths = new();
    if (Path.GetExtension(solutionPath).Equals(".slnx", StringComparison.OrdinalIgnoreCase)) {
        XDocument solutionDocument = XDocument.Load(solutionPath);
        foreach (XElement projectElement in solutionDocument.Descendants()
                     .Where(element => element.Name.LocalName.Equals("Project", StringComparison.OrdinalIgnoreCase))
        ) {
            XAttribute? pathAttribute = projectElement.Attribute("Path");
            if (pathAttribute is null) {
                continue;
            }

            string projectPath = Path.GetFullPath(Path.Combine(
                solutionDirectory,
                pathAttribute.Value.Replace('\\', Path.DirectorySeparatorChar)
            ));
            if (File.Exists(projectPath) && !IsExcludedProjectPath(solutionDirectory, projectPath)) {
                projectPaths.Add(projectPath);
            }
        }
    } else {
        string solutionText = File.ReadAllText(solutionPath);
        MatchCollection matches = Regex.Matches(
            solutionText,
            "Project\\(\\\"[^\\\"]+\\\"\\)\\s*=\\s*\\\"[^\\\"]+\\\",\\s*\\\"([^\\\"]+\\.csproj)\\\"",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant
        );

        projectPaths.AddRange(matches
            .Select(match => match.Groups[1].Value.Replace('\\', Path.DirectorySeparatorChar))
            .Select(relativePath => Path.GetFullPath(Path.Combine(solutionDirectory, relativePath)))
            .Where(File.Exists)
            .Where(projectPath => !IsExcludedProjectPath(solutionDirectory, projectPath))
        );
    }

    projectPaths = projectPaths
        .Distinct(StringComparer.OrdinalIgnoreCase)
        .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
        .ToList();

    if (projectPaths.Count == 0) {
        throw new InvalidDataException("方案中沒有可讀取的 C# 專案參考。");
    }

    return projectPaths;
}

static bool IsExcludedProjectPath(string solutionDirectory, string projectPath) {
    HashSet<string> excludedDirectoryNames = new(StringComparer.OrdinalIgnoreCase) {
        ".git",
        ".local",
        "bin",
        "obj",
        "dist",
        "out",
        "build",
        "target",
        "node_modules",
        "__pycache__",
        ".next",
        ".nuxt",
        ".svelte-kit",
        ".turbo",
        ".parcel-cache",
        ".output",
        ".vite",
        ".angular"
    };
    string relativePath = Path.GetRelativePath(solutionDirectory, projectPath);
    return relativePath
        .Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
        .Any(excludedDirectoryNames.Contains);
}

static Solution CreateSolution(
    AdhocWorkspace workspace,
    IEnumerable<string> projectPaths,
    IReadOnlyDictionary<string, ProjectId> projectIds,
    List<(string ProjectName, string Include)> unresolvedReferences
) {
    Solution solution = workspace.CurrentSolution;

    foreach (string projectPath in projectPaths) {
        string projectName = Path.GetFileNameWithoutExtension(projectPath);
        ProjectInfo projectInfo = ProjectInfo.Create(
            projectIds[projectPath],
            VersionStamp.Create(),
            projectName,
            projectName,
            LanguageNames.CSharp,
            filePath: projectPath,
            compilationOptions: new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary),
            parseOptions: CSharpParseOptions.Default.WithLanguageVersion(LanguageVersion.Latest)
        );

        solution = solution.AddProject(projectInfo);
    }

    foreach (string projectPath in projectPaths) {
        List<ProjectReference> references = LoadProjectReferences(projectPath, projectIds, unresolvedReferences);
        if (references.Count > 0) {
            solution = solution.AddProjectReferences(projectIds[projectPath], references);
        }
    }

    return solution;
}

static List<ProjectReference> LoadProjectReferences(
    string projectPath,
    IReadOnlyDictionary<string, ProjectId> projectIds,
    List<(string ProjectName, string Include)> unresolvedReferences
) {
    string projectDirectory = Path.GetDirectoryName(projectPath) ?? Directory.GetCurrentDirectory();
    XDocument projectDocument = XDocument.Load(projectPath, LoadOptions.PreserveWhitespace);
    Dictionary<string, string> properties = LoadSimpleProperties(projectDocument);
    List<ProjectReference> references = new();

    foreach (XElement referenceElement in projectDocument.Descendants()
                 .Where(element => element.Name.LocalName.Equals("ProjectReference", StringComparison.OrdinalIgnoreCase))
    ) {
        XAttribute? includeAttribute = referenceElement.Attribute("Include");
        if (includeAttribute is null) {
            continue;
        }

        string originalInclude = includeAttribute.Value;
        string[] includeItems = originalInclude.Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        foreach (string includeItem in includeItems) {
            if (!TryExpandProjectReference(includeItem, projectDirectory, properties, out string expandedInclude)) {
                unresolvedReferences.Add((Path.GetFileNameWithoutExtension(projectPath), includeItem));
                continue;
            }

            string normalizedInclude = expandedInclude.Replace('\\', '/');
            if (normalizedInclude.IndexOfAny(new[] { '*', '?' }) >= 0) {
                string wildcardPattern = Path.IsPathRooted(expandedInclude)
                    ? normalizedInclude
                    : Path.GetFullPath(Path.Combine(projectDirectory, expandedInclude)).Replace('\\', '/');
                string escapedPattern = Regex.Escape(wildcardPattern)
                    .Replace("\\*\\*/", "(?:.*/)?", StringComparison.Ordinal)
                    .Replace("\\*\\*", ".*", StringComparison.Ordinal)
                    .Replace("\\*", "[^/]*", StringComparison.Ordinal)
                    .Replace("\\?", "[^/]", StringComparison.Ordinal);
                Regex wildcardRegex = new(
                    "^" + escapedPattern + "$",
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant
                );
                string[] matchedProjects = projectIds.Keys
                    .Where(path => wildcardRegex.IsMatch(path.Replace('\\', '/')))
                    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                    .ToArray();
                if (matchedProjects.Length == 0) {
                    unresolvedReferences.Add((Path.GetFileNameWithoutExtension(projectPath), includeItem));
                    continue;
                }

                foreach (string matchedProject in matchedProjects) {
                    references.Add(new ProjectReference(projectIds[matchedProject]));
                }
            } else {
                string referencePath = Path.GetFullPath(Path.Combine(
                    projectDirectory,
                    expandedInclude.Replace('\\', Path.DirectorySeparatorChar)
                ));

                if (projectIds.TryGetValue(referencePath, out ProjectId? referenceId) && referenceId is not null) {
                    references.Add(new ProjectReference(referenceId));
                } else {
                    unresolvedReferences.Add((Path.GetFileNameWithoutExtension(projectPath), includeItem));
                }
            }
        }
    }

    return references;
}

static Dictionary<string, string> LoadSimpleProperties(XDocument projectDocument) {
    Dictionary<string, string> properties = new(StringComparer.OrdinalIgnoreCase);
    foreach (XElement propertyElement in projectDocument.Descendants()
                 .Where(element => element.Parent?.Name.LocalName.Equals("PropertyGroup", StringComparison.OrdinalIgnoreCase) == true)) {
        string value = propertyElement.Value.Trim();
        if (value.Length > 0 && !value.Contains("$(", StringComparison.Ordinal)) {
            properties[propertyElement.Name.LocalName] = value;
        }
    }

    return properties;
}

static bool TryExpandProjectReference(
    string include,
    string projectDirectory,
    IReadOnlyDictionary<string, string> properties,
    out string expandedInclude
) {
    expandedInclude = include;
    string projectDirectoryWithSeparator = projectDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
        + Path.DirectorySeparatorChar;
    Dictionary<string, string> builtInProperties = new(StringComparer.OrdinalIgnoreCase) {
        ["MSBuildThisFileDirectory"] = projectDirectoryWithSeparator,
        ["MSBuildProjectDirectory"] = projectDirectory
    };

    for (int iteration = 0; iteration < 32; iteration++) {
        bool changed = false;
        expandedInclude = Regex.Replace(expandedInclude, @"\$\(([^)]+)\)", match => {
            string propertyName = match.Groups[1].Value;
            if (builtInProperties.TryGetValue(propertyName, out string? builtInValue)) {
                changed = true;
                return builtInValue;
            }

            if (properties.TryGetValue(propertyName, out string? propertyValue)) {
                changed = true;
                return propertyValue;
            }

            return match.Value;
        }, RegexOptions.CultureInvariant);

        if (!changed) {
            break;
        }
    }

    return !Regex.IsMatch(expandedInclude, @"\$\([^)]+\)", RegexOptions.CultureInvariant);
}

static void WriteReport(
    string outputPath,
    string solutionPath,
    Solution solution,
    IReadOnlyCollection<(string ProjectName, string Include)> unresolvedReferences
) {
    string? outputDirectory = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDirectory)) {
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

    foreach (Project project in solution.Projects.OrderBy(project => project.Name, StringComparer.OrdinalIgnoreCase)) {
        report.AppendLine($"    {mermaidIds[project.Id]}[\"{EscapeMermaid(project.Name)}\"]");
    }

    bool hasReference = false;
    foreach (Project project in solution.Projects.OrderBy(project => project.Name, StringComparer.OrdinalIgnoreCase)) {
        foreach (ProjectReference reference in project.ProjectReferences) {
            if (!projects.TryGetValue(reference.ProjectId, out Project? referencedProject) || referencedProject is null) {
                continue;
            }

            report.AppendLine($"    {mermaidIds[project.Id]} --> {mermaidIds[referencedProject.Id]}");
            hasReference = true;
        }
    }

    if (!hasReference) {
        report.AppendLine("    NoReference[\"無專案相依\"]");
    }

    report.AppendLine("```");
    report.AppendLine();
    report.AppendLine("| 專案 | 相依專案 |");
    report.AppendLine("| --- | --- |");

    foreach (Project project in solution.Projects.OrderBy(project => project.Name, StringComparer.OrdinalIgnoreCase)) {
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

    if (unresolvedReferences.Count > 0) {
        report.AppendLine();
        report.AppendLine("## 未解析的 ProjectReference");
        report.AppendLine();
        foreach ((string projectName, string include) in unresolvedReferences
                     .OrderBy(reference => reference.ProjectName, StringComparer.OrdinalIgnoreCase)
                     .ThenBy(reference => reference.Include, StringComparer.Ordinal)) {
            report.AppendLine($"- `{EscapeMarkdown(projectName)}`：`{EscapeMarkdown(include)}`");
        }
    }

    File.WriteAllText(outputPath, report.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
}

static string EscapeMarkdown(string value) {
    return value.Replace("|", "\\|");
}

static string EscapeMermaid(string value) {
    return value.Replace("\"", "'");
}
