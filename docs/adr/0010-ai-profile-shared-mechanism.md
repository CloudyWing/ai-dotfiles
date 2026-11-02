---
status: accepted
date: 2026-11-02
---

# ADR-0010：AI-PROFILE 鍵由 ai-profile skill 集中管理

## Context

`AGENTS.local.md` 的 `AI-PROFILE` 區塊最初只承載 C# 風格註記，區塊格式、解析、錯誤處置與寫入都寫在 `csharp-style`。後續新增 `project-kind`、`workflow-depth` 與 `git-workflow` 等鍵時，若各 skill 各自定義解析與詢問規則，行為會分歧，使用者也會在同一專案被分次詢問。

## Decision

新增 `ai-profile` skill 作為 `AI-PROFILE` 區塊的唯一入口，收錄區塊格式、解析、錯誤處置、鍵登錄表、一次問完、非互動處置、本機排除與寫入，各鍵取值對行為的影響留在登錄表指定的負責 skill。排除寫入 `instructions.md`（每個 Session 都載入，與多數工作無關）與留在 `csharp-style`（非 .NET 專案也要載入 C# 專屬 skill）。

## Consequences

新增註記鍵時只在 `ai-profile` 登錄表登記一列，由負責 skill 定義取值語意，缺少的鍵在同一輪一次詢問。派工前由 `codex-dispatch` 的 AI-PROFILE 前置檢查補齊鍵，非互動執行端遇到缺少鍵時停止相依工作並回報，不寫入也不猜測。
