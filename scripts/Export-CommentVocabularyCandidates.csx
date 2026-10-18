#!/usr/bin/env dotnet-script
// 前置需求：dotnet tool install -g dotnet-script
#r "nuget: Microsoft.CodeAnalysis.CSharp, 4.11.0"
#nullable enable

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

Console.OutputEncoding = Encoding.UTF8;

if (Args.Count != 1) {
    Console.Error.WriteLine("用法：dotnet script Export-CommentVocabularyCandidates.csx -- <ProjectRoot>");
    Environment.Exit(1);
}

try {
    string projectRoot = Path.GetFullPath(Args[0]);
    if (!Directory.Exists(projectRoot)) {
        throw new DirectoryNotFoundException($"找不到專案目錄：{projectRoot}");
    }

    List<CandidateFact> facts = new();
    List<ParseIssue> parseIssues = new();
    List<string> sourceFiles = EnumerateSourceFiles(projectRoot).ToList();

    List<(string SourcePath, SyntaxTree SyntaxTree, CompilationUnitSyntax SyntaxRoot)> parsedSources = new();
    foreach (string sourcePath in sourceFiles) {
        SyntaxTree syntaxTree = CSharpSyntaxTree.ParseText(
            File.ReadAllText(sourcePath),
            CSharpParseOptions.Default.WithLanguageVersion(LanguageVersion.Latest),
            sourcePath
        );

        parseIssues.AddRange(syntaxTree.GetDiagnostics()
            .Where(diagnostic => diagnostic.Severity == DiagnosticSeverity.Error)
            .Select(diagnostic => new ParseIssue(
                GetRelativePath(projectRoot, sourcePath),
                diagnostic.Location.GetLineSpan().StartLinePosition.Line + 1,
                diagnostic.Id,
                diagnostic.GetMessage(CultureInfo.InvariantCulture)
            ))
        );

        CompilationUnitSyntax syntaxRoot = syntaxTree.GetCompilationUnitRoot();
        parsedSources.Add((sourcePath, syntaxTree, syntaxRoot));
    }

    CSharpCompilation? compilation = TryCreateCandidateCompilation(parsedSources.Select(source => source.SyntaxTree));
    foreach ((string sourcePath, SyntaxTree syntaxTree, CompilationUnitSyntax syntaxRoot) in parsedSources) {
        string sourceFile = GetRelativePath(projectRoot, sourcePath);
        SemanticModel? semanticModel = null;
        try {
            semanticModel = compilation?.GetSemanticModel(syntaxTree);
        } catch {
            semanticModel = null;
        }

        foreach (MemberDeclarationSyntax member in syntaxRoot.DescendantNodes()
                     .OfType<MemberDeclarationSyntax>()
                     .Where(member => member is not BaseTypeDeclarationSyntax
                                      && member is not PropertyDeclarationSyntax
                                      && member is not EnumMemberDeclarationSyntax)) {
            string? documentation = GetDocumentation(member);
            if (string.IsNullOrWhiteSpace(documentation)) {
                continue;
            }

            BaseTypeDeclarationSyntax? owner = member.Ancestors()
                .OfType<BaseTypeDeclarationSyntax>()
                .FirstOrDefault();
            bool? isEntityModelCandidate = owner is TypeDeclarationSyntax ownerType
                ? IsEntityModelCandidate(ownerType)
                : null;

            facts.Add(new CandidateFact(
                "xml-documentation",
                sourceFile,
                GetLine(member),
                owner is null ? "" : GetQualifiedName(owner),
                GetMemberIdentifier(member),
                null,
                documentation,
                Array.Empty<string>(),
                isEntityModelCandidate,
                null,
                null
            ));
        }

        foreach (BaseTypeDeclarationSyntax declaration in syntaxRoot.DescendantNodes()
                     .OfType<BaseTypeDeclarationSyntax>()) {
            string containingType = GetQualifiedName(declaration);

            AddDocumentationFact(facts, declaration, projectRoot, sourcePath, containingType);

            if (declaration is TypeDeclarationSyntax typeDeclaration) {
                bool isEntityModelCandidate = IsEntityModelCandidate(typeDeclaration);
                string[] typeAttributes = GetAttributes(typeDeclaration.AttributeLists, semanticModel);
                if (typeAttributes.Length > 0) {
                    facts.Add(new CandidateFact(
                        "type-attributes",
                        sourceFile,
                        GetLine(typeDeclaration),
                        containingType,
                        typeDeclaration.Identifier.ValueText,
                        null,
                        null,
                        typeAttributes,
                        isEntityModelCandidate,
                        null,
                        null
                    ));
                }

                foreach (PropertyDeclarationSyntax property in typeDeclaration.DescendantNodes()
                             .OfType<PropertyDeclarationSyntax>()
                             .Where(property => property.Ancestors()
                                 .OfType<TypeDeclarationSyntax>()
                                 .FirstOrDefault() == typeDeclaration)) {
                    string propertyType = property.Type.ToString();
                    facts.Add(new CandidateFact(
                        "property",
                        sourceFile,
                        GetLine(property),
                        GetQualifiedName(typeDeclaration),
                        property.Identifier.ValueText,
                        propertyType,
                        GetDocumentation(property),
                        GetAttributes(property.AttributeLists, semanticModel),
                        isEntityModelCandidate,
                        null,
                        null
                    ));
                }
            }

            if (declaration is EnumDeclarationSyntax enumDeclaration) {
                AddEnumFacts(facts, enumDeclaration, projectRoot, sourcePath, containingType, semanticModel);
            }
        }
    }

    CandidateReport report = new(
        "ai-comment-vocabulary-candidates.v1",
        GetRelativePath(projectRoot, projectRoot),
        sourceFiles.Count,
        parseIssues.Count == 0 ? "complete" : "partial",
        facts.OrderBy(fact => fact.SourcePath, StringComparer.OrdinalIgnoreCase)
            .ThenBy(fact => fact.Line)
            .ThenBy(fact => fact.Kind, StringComparer.Ordinal)
            .ThenBy(fact => fact.MemberName, StringComparer.Ordinal)
            .ToArray(),
        parseIssues.ToArray()
    );

    JsonSerializerOptions jsonOptions = new() {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    Console.WriteLine(JsonSerializer.Serialize(report, jsonOptions));
    if (parseIssues.Count > 0) {
        Console.Error.WriteLine($"C# 語法分析有 {parseIssues.Count} 個錯誤；輸出為 partial，不可據此核准語意。");
        Environment.ExitCode = 1;
    }
} catch (Exception exception) {
    Console.Error.WriteLine($"抽取註解語彙候選失敗：{exception.Message}");
    Environment.ExitCode = 1;
}

static CSharpCompilation? TryCreateCandidateCompilation(IEnumerable<SyntaxTree> syntaxTrees) {
    try {
        MetadataReference runtimeReference = MetadataReference.CreateFromFile(typeof(object).Assembly.Location);
        return CSharpCompilation.Create(
            "AiCommentVocabularyCandidates",
            syntaxTrees,
            new[] { runtimeReference },
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary)
        );
    } catch {
        return null;
    }
}

static IEnumerable<string> EnumerateSourceFiles(string projectRoot) {
    Stack<string> pendingDirectories = new();
    List<string> sourceFiles = new();
    pendingDirectories.Push(Path.GetFullPath(projectRoot));

    while (pendingDirectories.Count > 0) {
        string currentDirectory = pendingDirectories.Pop();
        sourceFiles.AddRange(Directory.EnumerateFiles(currentDirectory, "*.cs", SearchOption.TopDirectoryOnly));

        foreach (string childDirectory in Directory.EnumerateDirectories(currentDirectory, "*", SearchOption.TopDirectoryOnly)) {
            if (IsExcludedDirectory(projectRoot, childDirectory)) {
                continue;
            }

            if ((File.GetAttributes(childDirectory) & FileAttributes.ReparsePoint) != 0) {
                continue;
            }

            pendingDirectories.Push(childDirectory);
        }
    }

    return sourceFiles.OrderBy(path => path, StringComparer.OrdinalIgnoreCase);
}

static bool IsExcludedDirectory(string projectRoot, string directoryPath) {
    return GetRelativePath(projectRoot, directoryPath)
        .Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
        .Any(segment => segment.Equals("bin", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals("obj", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals(".git", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals("dist", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals("out", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals("build", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals("target", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals("node_modules", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals("__pycache__", StringComparison.OrdinalIgnoreCase)
                        || segment.Equals(".local", StringComparison.OrdinalIgnoreCase));
}

static void AddDocumentationFact(
    List<CandidateFact> facts,
    BaseTypeDeclarationSyntax declaration,
    string projectRoot,
    string sourcePath,
    string containingType
) {
    string? documentation = GetDocumentation(declaration);
    if (string.IsNullOrWhiteSpace(documentation)) {
        return;
    }

    bool? isEntityModelCandidate = declaration is TypeDeclarationSyntax typeDeclaration
        ? IsEntityModelCandidate(typeDeclaration)
        : null;

    facts.Add(new CandidateFact(
        "xml-documentation",
        GetRelativePath(projectRoot, sourcePath),
        GetLine(declaration),
        containingType,
        GetTypeIdentifier(declaration),
        null,
        documentation,
        Array.Empty<string>(),
        isEntityModelCandidate,
        null,
        null
    ));
}

static void AddEnumFacts(
    List<CandidateFact> facts,
    EnumDeclarationSyntax declaration,
    string projectRoot,
    string sourcePath,
    string containingType,
    SemanticModel? semanticModel
) {
    foreach (EnumMemberDeclarationSyntax member in declaration.Members) {
        string? expression = member.EqualsValue is null
            ? null
            : SanitizeSensitiveLiterals(member.EqualsValue.Value);
        string? numericValue = null;
        try {
            IFieldSymbol? fieldSymbol = semanticModel?.GetDeclaredSymbol(member) as IFieldSymbol;
            if (fieldSymbol?.ConstantValue is object constantValue) {
                numericValue = Convert.ToString(constantValue, CultureInfo.InvariantCulture);
            }
        } catch {
            numericValue = null;
        }

        facts.Add(new CandidateFact(
            "enum-member",
            GetRelativePath(projectRoot, sourcePath),
            GetLine(member),
            containingType,
            member.Identifier.ValueText,
            null,
            GetDocumentation(member),
            GetAttributes(member.AttributeLists, semanticModel),
            null,
            expression,
            numericValue
        ));
    }
}

static bool IsEntityModelCandidate(TypeDeclarationSyntax declaration) {
    string name = declaration.Identifier.ValueText;
    if (name.EndsWith("Entity", StringComparison.OrdinalIgnoreCase)
        || name.EndsWith("Model", StringComparison.OrdinalIgnoreCase)) {
        return true;
    }

    return declaration.AttributeLists
        .SelectMany(attributeList => attributeList.Attributes)
        .Select(attribute => GetSimpleName(attribute.Name))
        .Select(name => name.EndsWith("Attribute", StringComparison.OrdinalIgnoreCase)
            ? name.Substring(0, name.Length - "Attribute".Length)
            : name)
        .Any(name => name.Equals("Table", StringComparison.OrdinalIgnoreCase)
                     || name.Equals("Owned", StringComparison.OrdinalIgnoreCase));
}

static string GetSimpleName(NameSyntax name) {
    return name switch {
        IdentifierNameSyntax identifier => identifier.Identifier.ValueText,
        GenericNameSyntax generic => generic.Identifier.ValueText,
        QualifiedNameSyntax qualified => GetSimpleName(qualified.Right),
        AliasQualifiedNameSyntax aliasQualified => GetSimpleName(aliasQualified.Name),
        _ => name.ToString()
    };
}

static string GetMemberIdentifier(MemberDeclarationSyntax member) {
    return member switch {
        MethodDeclarationSyntax method => method.Identifier.ValueText,
        ConstructorDeclarationSyntax constructor => constructor.Identifier.ValueText,
        DestructorDeclarationSyntax destructor => destructor.Identifier.ValueText,
        OperatorDeclarationSyntax @operator => @operator.OperatorToken.Text,
        ConversionOperatorDeclarationSyntax conversionOperator => conversionOperator.Type.ToString(),
        FieldDeclarationSyntax field => string.Join(", ", field.Declaration.Variables
            .Select(variable => variable.Identifier.ValueText)),
        EventDeclarationSyntax eventDeclaration => eventDeclaration.Identifier.ValueText,
        EventFieldDeclarationSyntax eventField => string.Join(", ", eventField.Declaration.Variables
            .Select(variable => variable.Identifier.ValueText)),
        _ => member.Kind().ToString()
    };
}

static string[] GetAttributes(SyntaxList<AttributeListSyntax> attributeLists, SemanticModel? semanticModel) {
    string[] allowedNames = {
        "Table", "Column", "Key", "Required", "StringLength", "MaxLength", "MinLength",
        "Display", "DisplayName", "Description", "Comment", "Index", "ForeignKey",
        "NotMapped", "DatabaseGenerated", "Owned"
    };

    return attributeLists.SelectMany(attributeList => attributeList.Attributes)
        .Select(attribute => {
            string attributeName = GetSimpleName(attribute.Name);
            if (attributeName.EndsWith("Attribute", StringComparison.OrdinalIgnoreCase)) {
                attributeName = attributeName.Substring(0, attributeName.Length - "Attribute".Length);
            }

            string outputName = attribute.Name.WithoutTrivia().ToString();
            if (!allowedNames.Contains(attributeName, StringComparer.OrdinalIgnoreCase)
                || attribute.ArgumentList is null) {
                return outputName;
            }

            string[] arguments = attribute.ArgumentList.Arguments
                .Select(argument => FormatAttributeArgument(argument, semanticModel))
                .ToArray();
            return $"{outputName}({string.Join(", ", arguments)})";
        })
        .ToArray();
}

static string FormatAttributeArgument(AttributeArgumentSyntax argument, SemanticModel? semanticModel) {
    string prefix = argument.NameEquals is not null
        ? $"{argument.NameEquals.Name.Identifier.ValueText} = "
        : argument.NameColon is not null
            ? $"{argument.NameColon.Name.Identifier.ValueText}: "
            : "";
    ExpressionSyntax expression = argument.Expression;

    if (expression.IsKind(SyntaxKind.StringLiteralExpression)) {
        string literalValue = ((LiteralExpressionSyntax)expression).Token.ValueText;
        string literal = ContainsSensitiveMarker(literalValue)
            ? "\"***\""
            : expression.WithoutTrivia().ToString();
        return prefix + literal;
    }

    if (expression.IsKind(SyntaxKind.CharacterLiteralExpression)
        || expression.IsKind(SyntaxKind.NumericLiteralExpression)
        || expression.IsKind(SyntaxKind.TrueLiteralExpression)
        || expression.IsKind(SyntaxKind.FalseLiteralExpression)
        || expression.IsKind(SyntaxKind.NullLiteralExpression)) {
        return prefix + expression.WithoutTrivia().ToString();
    }

    if (expression is TypeOfExpressionSyntax typeOfExpression
        && IsSimpleTypeName(typeOfExpression.Type)) {
        return prefix + expression.WithoutTrivia().ToString();
    }

    if (expression is InvocationExpressionSyntax invocation
        && invocation.Expression is IdentifierNameSyntax invocationName
        && invocationName.Identifier.ValueText.Equals("nameof", StringComparison.Ordinal)
        && invocation.ArgumentList.Arguments.Count == 1
        && invocation.ArgumentList.Arguments[0].Expression is SimpleNameSyntax) {
        return prefix + expression.WithoutTrivia().ToString();
    }

    if (expression is MemberAccessExpressionSyntax
        && semanticModel?.GetSymbolInfo(expression).Symbol is IFieldSymbol enumMember
        && enumMember.ContainingType.TypeKind == TypeKind.Enum) {
        return prefix + expression.WithoutTrivia().ToString();
    }

    return prefix + "***";
}

static bool IsSimpleTypeName(TypeSyntax type) {
    return type is IdentifierNameSyntax or GenericNameSyntax or PredefinedTypeSyntax;
}

static string? GetDocumentation(SyntaxNode node) {
    string[] documentation = node.GetLeadingTrivia()
        .Where(trivia => trivia.GetStructure() is DocumentationCommentTriviaSyntax)
        .Select(trivia => trivia.ToFullString())
        .SelectMany(text => text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        .Select(NormalizeDocumentationLine)
        .Where(line => !string.IsNullOrWhiteSpace(line))
        .ToArray();

    if (documentation.Length == 0) {
        return null;
    }

    string text = string.Join(" ", documentation);
    return ContainsSensitiveMarker(text) ? "***" : text;
}

static string SanitizeSensitiveLiterals(SyntaxNode node) {
    string text = node.ToString();
    List<(int Start, int Length, string Replacement)> replacementSpans = new();
    List<InterpolatedStringExpressionSyntax> allSensitiveInterpolatedStrings = node.DescendantNodesAndSelf()
        .OfType<InterpolatedStringExpressionSyntax>()
        .Where(interpolatedString => interpolatedString.DescendantTokens()
            .Any(token => token.IsKind(SyntaxKind.InterpolatedStringTextToken)
                          && ContainsSensitiveMarker(token.ValueText)))
        .ToList();
    HashSet<InterpolatedStringExpressionSyntax> sensitiveInterpolatedStringSet = new(allSensitiveInterpolatedStrings);
    List<InterpolatedStringExpressionSyntax> sensitiveInterpolatedStrings = allSensitiveInterpolatedStrings
        .Where(interpolatedString => !interpolatedString.Ancestors()
            .OfType<InterpolatedStringExpressionSyntax>()
            .Any(sensitiveInterpolatedStringSet.Contains))
        .ToList();

    foreach (InterpolatedStringExpressionSyntax interpolatedString in sensitiveInterpolatedStrings) {
        replacementSpans.Add((interpolatedString.SpanStart, interpolatedString.Span.Length, "\"***\""));
    }

    foreach (SyntaxToken token in node.DescendantTokens()) {
        bool isCoveredBySensitiveInterpolation = sensitiveInterpolatedStrings
            .Any(interpolatedString => interpolatedString.Span.Contains(token.Span));
        if (!isCoveredBySensitiveInterpolation
            && token.Value is string literalValue
            && ContainsSensitiveMarker(literalValue)) {
            replacementSpans.Add((token.SpanStart, token.Span.Length, "\"***\""));
        }
    }

    foreach ((int start, int length, string replacement) in replacementSpans
                 .GroupBy(span => (span.Start, span.Length))
                 .Select(group => group.First())
                 .OrderByDescending(span => span.Start)) {
        int relativeStart = start - node.SpanStart;
        text = text.Remove(relativeStart, length).Insert(relativeStart, replacement);
    }

    return text;
}

static bool ContainsSensitiveMarker(string value) {
    return Regex.IsMatch(
        value,
        @"password|pwd|secret|token|api[-_ ]?key|connection ?string|server=|data source=|user id=|uid=",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant
    );
}

static string NormalizeDocumentationLine(string line) {
    string normalized = line.Trim();
    if (normalized.StartsWith("///", StringComparison.Ordinal)) {
        normalized = normalized.Substring(3).TrimStart();
    } else if (normalized.StartsWith("/**", StringComparison.Ordinal)) {
        normalized = normalized.Substring(3).TrimStart();
    } else if (normalized.StartsWith("*", StringComparison.Ordinal)) {
        normalized = normalized.Substring(1).TrimStart();
    }

    if (normalized.EndsWith("*/", StringComparison.Ordinal)) {
        normalized = normalized.Substring(0, normalized.Length - 2).TrimEnd();
    }

    return normalized;
}

static int GetLine(SyntaxNode node) {
    return node.GetLocation().GetLineSpan().StartLinePosition.Line + 1;
}

static string GetQualifiedName(BaseTypeDeclarationSyntax declaration) {
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
            .Select(namespaceDeclaration => namespaceDeclaration.Name.ToString())
    );

    if (!string.IsNullOrWhiteSpace(namespaceName)) {
        names.Insert(0, namespaceName);
    }

    return string.Join(".", names);
}

static string GetTypeIdentifier(BaseTypeDeclarationSyntax declaration) {
    return declaration switch {
        EnumDeclarationSyntax enumDeclaration => enumDeclaration.Identifier.ValueText,
        _ => ((TypeDeclarationSyntax)declaration).Identifier.ValueText
    };
}

static string GetRelativePath(string projectRoot, string sourcePath) {
    return Path.GetRelativePath(projectRoot, sourcePath).Replace(Path.DirectorySeparatorChar, '/');
}

internal sealed record CandidateReport(
    string Schema,
    string ProjectRoot,
    int SourceFilesScanned,
    string Status,
    CandidateFact[] Facts,
    ParseIssue[] ParseIssues
);

internal sealed record CandidateFact(
    string Kind,
    string SourcePath,
    int Line,
    string ContainingType,
    string? MemberName,
    string? TypeName,
    string? Documentation,
    string[] Attributes,
    bool? IsEntityModelCandidate,
    string? ValueExpression,
    string? NumericValueCandidate
);

internal sealed record ParseIssue(
    string SourcePath,
    int Line,
    string DiagnosticId,
    string Message
);
