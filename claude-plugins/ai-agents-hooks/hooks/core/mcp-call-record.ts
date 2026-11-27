// Playwright MCP 與 FlaUI.Mcp 的工具呼叫紀錄：判定是否記錄，並組出每次呼叫一個檔案的內容。
// scripts\Write-ClaudeRunRecord.ps1 在測試取證結束時讀這些檔案，彙整成與 Codex 執行紀錄同欄位的 mcp_tool_calls。
// 只記錄呼叫的歸屬與結果狀態，不讀取也不記錄工具的輸入、輸出與錯誤文字（browser_type 與 browser_fill_form 的輸入可能含測試帳密）。
import type { HookIo } from './io'
import { field, isRecord } from './io'

/** 受控的 MCP 伺服器名稱（使用者層登記的名稱，工具名稱為 mcp__<伺服器>__<工具>）。 */
export const WATCHED_MCP_SERVERS: readonly string[] = ['playwright', 'flaui-mcp']

/** 呼叫紀錄的根目錄在 LOCALAPPDATA 之下的區段。 */
export const MCP_CALL_ROOT_SEGMENTS: readonly string[] = ['ai-agents', 'mcp-calls']

/** 主執行緒（事件沒有 agent_id）的呼叫紀錄所在的目錄名稱。 */
export const MAIN_THREAD_DIRECTORY = '_main'

export const MCP_CALL_SCHEMA = 'ai-agents.mcp-call.v1'

export type McpCallKind = 'completed' | 'failed'

export interface McpCallRecordFile {
  /** 相對於根目錄的路徑，格式為 <agent_id 或 _main>\<tool_use_id>.json。 */
  fileName: string
  /** 檔案內容（JSON）。 */
  text: string
}

const SAFE_IDENTIFIER = /^[A-Za-z0-9_-]{1,128}$/u
const REGEX_SPECIAL = /[.*+?^$()|[\]{}\\]/gu
const WATCHED_SERVER_ALTERNATIVES = WATCHED_MCP_SERVERS.map(name => name.replace(REGEX_SPECIAL, '\\$&')).join('|')
const WATCHED_TOOL = new RegExp(`^mcp__(?:${WATCHED_SERVER_ALTERNATIVES})__`, 'u')
const SERVER_OF_TOOL = /^mcp__(.+?)__/u

/** 符合受控伺服器的工具名稱樣式，供 hook 註冊時作為 matcher。 */
export const WATCHED_MCP_TOOL_PATTERN: RegExp = WATCHED_TOOL

function text(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined
}

function serverOf(input: unknown, toolName: string): string | undefined {
  const provenance = field(input, 'mcp_server')
  const named = isRecord(provenance) ? text(provenance['name']) : undefined
  if (named !== undefined) return named
  return SERVER_OF_TOOL.exec(toolName)?.[1]
}

/**
 * 組出一次受控 MCP 工具呼叫的紀錄。不是受控伺服器的工具、缺少 tool_use_id，或 agent_id、tool_use_id 含不安全字元（避免路徑注入）時回傳 undefined。
 * agent_id 缺少代表主執行緒，紀錄放在 _main 目錄。
 */
export function buildMcpCallRecord(input: unknown, kind: McpCallKind, nowIso: string): McpCallRecordFile | undefined {
  const toolName = text(field(input, 'tool_name'))
  if (toolName === undefined || !WATCHED_TOOL.test(toolName)) return undefined

  const toolUseId = text(field(input, 'tool_use_id'))
  if (toolUseId === undefined || !SAFE_IDENTIFIER.test(toolUseId)) return undefined

  const rawAgentId = field(input, 'agent_id')
  let agentId: string | null = null
  if (rawAgentId !== undefined && rawAgentId !== null) {
    if (typeof rawAgentId !== 'string' || !SAFE_IDENTIFIER.test(rawAgentId)) return undefined
    agentId = rawAgentId
  }

  const server = serverOf(input, toolName)
  if (server === undefined) return undefined

  const duration = field(input, 'duration_ms')
  const record: Record<string, unknown> = {
    schema: MCP_CALL_SCHEMA,
    session_id: text(field(input, 'session_id')) ?? null,
    agent_id: agentId,
    agent_type: text(field(input, 'agent_type')) ?? null,
    tool_use_id: toolUseId,
    tool_name: toolName,
    server,
    status: kind,
    ts_utc: nowIso,
    duration_ms: typeof duration === 'number' && Number.isFinite(duration) ? duration : null
  }
  if (kind === 'failed') record['is_interrupt'] = field(input, 'is_interrupt') === true

  return {
    fileName: `${agentId ?? MAIN_THREAD_DIRECTORY}\\${toolUseId}.json`,
    text: JSON.stringify(record, null, 2) + '\n'
  }
}

/**
 * 把一次受控 MCP 工具呼叫寫成紀錄檔，回傳寫入的完整路徑。
 * LOCALAPPDATA 未設定、事件不屬於受控伺服器或寫入失敗時不寫入並回傳 undefined；寫入失敗不擲出例外，不影響工具結果。
 */
export async function writeMcpCallRecord(io: HookIo, localAppData: string | undefined, input: unknown, kind: McpCallKind, nowIso: string): Promise<string | undefined> {
  if (localAppData === undefined || localAppData === '') return undefined
  const record = buildMcpCallRecord(input, kind, nowIso)
  if (record === undefined) return undefined
  const path = [localAppData, ...MCP_CALL_ROOT_SEGMENTS, record.fileName].join('\\')
  try {
    await io.writeText(path, record.text)
    return path
  } catch {
    // 紀錄只供回收核對，寫入失敗不影響呼叫。
    return undefined
  }
}
