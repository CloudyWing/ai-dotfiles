#!/usr/bin/env dotnet-script
#r "nuget: CloudyWing.SpreadsheetExporter, 3.0.0"
#r "nuget: CloudyWing.SpreadsheetExporter.Renderer.ClosedXML, 3.0.0"

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using CloudyWing.SpreadsheetExporter;
using CloudyWing.SpreadsheetExporter.Renderer.ClosedXML;

// 確保 Windows 環境下中文訊息不會亂碼
Console.OutputEncoding = System.Text.Encoding.UTF8;

if (Args.Count < 2) {
    Console.Error.WriteLine("Usage: dotnet script export-excel.csx <json-or-file-or-dash> <output-path>");
    Console.Error.WriteLine("  <json-or-file-or-dash> : JSON string, .json file path, or '-' to read from stdin.");
    Environment.Exit(1);
}

string jsonArg = Args[0];
string outputPath = Args[1];
string json = "";
bool isTempFile = false;

try {
    if (jsonArg == "-") {
        // 支援 Pipe 串接資料流
        using StreamReader reader = new(Console.OpenStandardInput());
        json = reader.ReadToEnd();
    } else if (jsonArg.EndsWith(".json", StringComparison.OrdinalIgnoreCase)) {
        if (!File.Exists(jsonArg)) {
            throw new FileNotFoundException($"找不到指定的 JSON 檔案：{jsonArg}");
        }
        json = File.ReadAllText(jsonArg);
        
        // 識別是否為臨時檔案，以便後續清理
        if (jsonArg.Contains(Path.GetTempPath()) || jsonArg.Contains("tmp")) {
            isTempFile = true;
        }
    } else {
        json = jsonArg;
    }

    if (string.IsNullOrWhiteSpace(json)) {
        throw new ArgumentException("輸入的 JSON 內容不可為空。");
    }

    string outputDir = Path.GetDirectoryName(outputPath);
    if (!string.IsNullOrEmpty(outputDir) && !Directory.Exists(outputDir)) {
        Directory.CreateDirectory(outputDir);
    }

    SpreadsheetManager.SetRenderer(() => new ExcelRenderer());
    SpreadsheetDocument doc = SpreadsheetDocument.FromJson(json);
    doc.ExportFile(outputPath);

    Console.WriteLine($"✅ Excel 檔案已成功匯出至：{outputPath}");

    try {
        PrintPreview(json);
    } catch {
        // 預覽僅供參考，不應中斷主匯出流程
    }

    if (isTempFile && File.Exists(jsonArg)) {
        try {
            File.Delete(jsonArg);
        } catch {
            // 避免因檔案鎖定導致清理失敗時拋出例外
        }
    }

} catch (Exception ex) {
    Console.Error.WriteLine("❌ 發生錯誤：");
    Console.Error.WriteLine(ex.Message);
    Environment.Exit(1);
}

void PrintPreview(string jsonContent) {
    using JsonDocument document = JsonDocument.Parse(jsonContent);
    JsonElement firstSheet = document.RootElement.EnumerateArray().FirstOrDefault();
    if (firstSheet.ValueKind == JsonValueKind.Undefined)
    {
        return;
    }

    JsonElement templates = firstSheet.GetProperty("Templates");
    JsonElement firstRecordSet = templates.EnumerateArray()
        .FirstOrDefault(t => t.GetProperty("Type").GetString() == "RecordSet");

    if (firstRecordSet.ValueKind == JsonValueKind.Undefined)
    {
        return;
    }

    List<JsonElement> columns = firstRecordSet.GetProperty("Columns").EnumerateArray().ToList();
    List<JsonElement> records = firstRecordSet.GetProperty("Records").EnumerateArray().Take(5).ToList();

    if (!columns.Any() || !records.Any())
    {
        return;
    }

    Console.WriteLine("\n📊 匯出資料預覽 (前 5 筆)：");

    string header = "| " + string.Join(" | ", columns.Select(c => c.GetProperty("HeaderText").GetString())) + " |";
    string separator = "| " + string.Join(" | ", columns.Select(_ => "---")) + " |";
    Console.WriteLine(header);
    Console.WriteLine(separator);

    foreach (JsonElement record in records)
    {
        IEnumerable<string> rowValues = columns.Select(c =>
        {
            string key = c.GetProperty("FieldKey").GetString();
            if (record.TryGetProperty(key, out JsonElement val))
            {
                return val.ToString();
            }
            return "";
        });
        Console.WriteLine("| " + string.Join(" | ", rowValues) + " |");
    }

    if (firstRecordSet.GetProperty("Records").GetArrayLength() > 5)
    {
        Console.WriteLine($"... 還有 {firstRecordSet.GetProperty("Records").GetArrayLength() - 5} 筆資料");
    }
    Console.WriteLine();
}
