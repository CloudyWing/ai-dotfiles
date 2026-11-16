// 每個事件寫一筆 turn 紀錄；同一 turn、同一 agent 內相同失敗第 2 次出現時回傳提醒文字。
import type { HookIo } from './io'
import { WHITE_SPACE_CLASS, field, isBlank, isRecord, joinPath, sameText, splitLines, trimText } from './io'

// .NET 的 \w、\d、\s 以 Unicode 類別判定，JavaScript 的 \b、\d 只認 ASCII、\s 的集合也不同，這裡以 Unicode 屬性寫出等價的樣式。
const WORD = '[\\p{L}\\p{Mn}\\p{Nd}\\p{Pc}]'
const BOUNDARY = `(?:(?<=${WORD})(?!${WORD})|(?<!${WORD})(?=${WORD}))`
const DIGIT = '\\p{Nd}'
const SPACE = `[${WHITE_SPACE_CLASS}]`
const NON_SPACE = `[^${WHITE_SPACE_CLASS}]`

// 清單只收錄確認不改變狀態的命令。
const READ_COMMANDS = ['ls', 'dir', 'cat', 'type', 'head', 'tail', 'rg', 'grep', 'find', 'wc', 'stat', 'get-content', 'get-childitem', 'get-item', 'select-string', 'test-path', 'get-command', 'measure-object', 'resolve-path', 'split-path', 'join-path']
const BRANCH_FLAGS = ['-a', '--all', '-r', '--remotes', '-v', '-vv', '--verbose', '-l', '--list', '--show-current', '--no-color', '--color', '--column', '--no-column']
const BRANCH_VALUE_FLAGS = ['--list', '-l', '--contains', '--no-contains', '--merged', '--no-merged', '--points-at', '--sort', '--format']
const BRANCH_INLINE_VALUE = /^(--contains|--no-contains|--merged|--no-merged|--points-at|--sort|--format)=/u
const SPACES = new RegExp(`${SPACE}+`, 'gu')
const SPLIT_SPACES = new RegExp(`${SPACE}+`, 'u')
const CHANGE_DIRECTORY_ONLY = new RegExp(`^(?:cd|Set-Location|pushd)${SPACE}+(?:"[^"]+"|'[^']+'|${NON_SPACE}+)${SPACE}*$`, 'iu')
const LEADING_CALL = new RegExp(`^&${SPACE}+`, 'u')
const LEADING_CD = new RegExp(`^cd${SPACE}+${NON_SPACE}+${SPACE}+`, 'iu')
const MUTATING = new RegExp(`>|${BOUNDARY}(?:out-file|set-content|add-content|remove-${NON_SPACE}*|set-${NON_SPACE}*|new-${NON_SPACE}*|move-${NON_SPACE}*|copy-${NON_SPACE}*|rm|mv|cp|mkdir)${BOUNDARY}`, 'iu')
const READ_ONLY_GIT = new RegExp(`^git${SPACE}+(status|log|diff|show|rev-parse|ls-files)(${SPACE}|$)`, 'iu')
const GIT_BRANCH = new RegExp(`^git${SPACE}+branch(${SPACE}|$)`, 'iu')
const GIT_CONFIG_GET = new RegExp(`^git${SPACE}+config${SPACE}+--get(${SPACE}|$)`, 'iu')
const SED_PRINT = new RegExp(`^sed${SPACE}+-n(${SPACE}|$)`, 'iu')
const GUID = new RegExp(`${BOUNDARY}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}${BOUNDARY}`, 'giu')
const TIMESTAMP = new RegExp(`${DIGIT}{4}-${DIGIT}${DIGIT}-${DIGIT}${DIGIT}[T ]${DIGIT}${DIGIT}:${DIGIT}${DIGIT}:${DIGIT}${DIGIT}(?:\\.${DIGIT}+)?(?:Z|[+-]${DIGIT}${DIGIT}:${DIGIT}${DIGIT})?`, 'giu')
const LONG_NUMBER = new RegExp(`${DIGIT}{4,}`, 'gu')
const BEARER = new RegExp(`Bearer${SPACE}+[^${WHITE_SPACE_CLASS}"']+`, 'giu')
const SECRET_ASSIGNMENT = new RegExp(`(token|password|passwd|secret|api[-_]?key|authorization)${SPACE}*[=:]${SPACE}*${NON_SPACE}+`, 'giu')
const SESSION_NAME = /^[A-Za-z0-9_-]+$/u
const PROMPT_LINE = new RegExp(`"event"${SPACE}*:${SPACE}*"UserPromptSubmit"`, 'iu')
const COUNT_KEYS = ['read', 'search', 'readonly_cmd', 'other', 'failure', 'evidence'] as const

// 本實例的紀錄檔寫到超過 ROTATE_BYTES 就改寫下一段，舊段保留不動，每次整段寫回的大小因此有上限。
// 讀取上限為引擎 $.fs.read 的 4 MiB；其他實例的檔超過上限或連續讀取失敗時不納入計數，本筆標記 read_failed。
const ROTATE_BYTES = 1024 * 1024
const READ_LIMIT_BYTES = 4 * 1024 * 1024
// 寫不進去的列最多累積到這個大小，超過時放棄該段尚未落檔的列並換段。
const MAX_PENDING_BYTES = 4 * 1024 * 1024

type CountKey = typeof COUNT_KEYS[number]
type Counts = Record<CountKey, number>
type Fingerprint = { agent: string; hash: string; text: string; repeat: number }

// git branch 只有查詢型旗標時才視為唯讀；出現分支名稱或其他選項即屬寫入。
function isReadOnlyGitBranch(part: string): boolean {
  const unquoted = part.replace(/"([^"]*)"|'([^']*)'/gu, (_match, double: string | undefined, single: string | undefined) => ((double ?? '') + (single ?? '')).replace(SPACES, ''))
  const tokens = unquoted.split(SPLIT_SPACES).slice(2).filter(token => token !== '')
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index] ?? ''
    if (BRANCH_INLINE_VALUE.test(token)) continue
    if (BRANCH_FLAGS.includes(token)) {
      const following = tokens[index + 1]
      if (BRANCH_VALUE_FLAGS.includes(token) && following !== undefined && !following.startsWith('-')) index++
      continue
    }
    if (BRANCH_VALUE_FLAGS.includes(token)) { if (index + 1 < tokens.length) index++; continue }
    return false
  }
  return true
}

export function isReadOnlyCommand(command: string): boolean {
  if (isBlank(command)) return false
  for (const raw of command.split(/&&|\|\||[;|\r\n]/u)) {
    let part = trimText(raw).replace(LEADING_CALL, '')
    if (isBlank(part)) continue
    if (CHANGE_DIRECTORY_ONLY.test(part)) continue
    part = part.replace(LEADING_CD, '')
    if (MUTATING.test(part)) return false
    if (READ_COMMANDS.includes((part.split(SPLIT_SPACES)[0] ?? '').toLowerCase())) continue
    if (READ_ONLY_GIT.test(part)) continue
    if (GIT_BRANCH.test(part) && isReadOnlyGitBranch(part)) continue
    if (GIT_CONFIG_GET.test(part) || SED_PRINT.test(part)) continue
    return false
  }
  return true
}

export function normalizeFingerprintPart(value: string): string {
  let text = trimText(value).replace(SPACES, ' ').replace(/\\/gu, '/')
  text = text.replace(GUID, '<guid>')
  text = text.replace(TIMESTAMP, '<ts>').replace(LONG_NUMBER, '#')
  text = text.replace(BEARER, '<redacted>').replace(SECRET_ASSIGNMENT, '<redacted>')
  return text.length > 200 ? text.slice(0, 200) : text
}

async function shortHash(text: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)))
  return Array.from(digest, byte => byte.toString(16).padStart(2, '0')).join('').slice(0, 12)
}

function classify(tool: string, toolInput: unknown): CountKey {
  const name = tool.toLowerCase()
  if (name === 'read') return 'read'
  if (name === 'grep' || name === 'glob') return 'search'
  if (name === 'bash' || name === 'powershell') {
    const command = field(toolInput, 'command')
    return isReadOnlyCommand(typeof command === 'string' ? command : '') ? 'readonly_cmd' : 'other'
  }
  return 'other'
}

function failureSubject(tool: string, toolInput: unknown): string {
  const name = tool.toLowerCase()
  const key = name === 'bash' || name === 'powershell' ? 'command'
    : name === 'read' || name === 'edit' || name === 'write' ? 'file_path'
    : name === 'grep' || name === 'glob' ? 'pattern'
    : undefined
  const subject = key === undefined ? '' : field(toolInput, key)
  return typeof subject === 'string' ? subject : ''
}

// 主 Session 的事件沒有 agent_id，一律以空字串代表；subagent 內觸發時使用其 agent_id。
function agentName(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function timestamp(): string {
  return new Date().toISOString()
}

function parseJson(line: string): unknown {
  try { return JSON.parse(line) } catch { return undefined }
}

function byteLength(text: string): number {
  return new TextEncoder().encode(text).length
}

async function readWithRetry(io: HookIo, path: string): Promise<string | undefined> {
  for (let attempt = 0; attempt < 3; attempt++) {
    try { return await io.readText(path) } catch { /* 重試 */ }
  }
  return undefined
}

// 本模組實例的識別。每個實例只寫名稱含此識別的檔案，不同實例（不同行程，或同一行程重新載入後）不會寫同一個檔。
const INSTANCE = crypto.randomUUID().replace(/-/gu, '').slice(0, 12)

function ownPartName(base: string, part: number): string {
  return part === 0 ? `${base}.${INSTANCE}.jsonl` : `${base}.${INSTANCE}.${part}.jsonl`
}

// 本實例檔名中的段號；不是本實例的檔回傳 undefined。
function ownPartOf(base: string, name: string): number | undefined {
  if (name === ownPartName(base, 0)) return 0
  const prefix = `${base}.${INSTANCE}.`
  if (!name.startsWith(prefix) || !name.endsWith('.jsonl')) return undefined
  const part = name.slice(prefix.length, -'.jsonl'.length)
  return /^[0-9]+$/u.test(part) ? Number(part) : undefined
}

/**
 * 本實例專用的 JSON Lines 紀錄檔：<base>.<實例>.jsonl，超過 ROTATE_BYTES 後依序改寫 <base>.<實例>.1.jsonl…。
 * $.fs 沒有追加寫入，記憶體保留目前段的全文，追加時整段寫回；檔案只有本實例會寫，因此不需要讀回。
 * 寫入失敗的列留在記憶體的全文中，下一次寫入成功時一併落檔；有未落檔的列時不輪替，以免換段後遺漏。
 */
class OwnLog {
  private readonly directory: string
  private readonly base: string
  /** 本狀態開始寫的段號；比它小的本實例檔屬於先前釋放的狀態，視同其他檔讀取。 */
  readonly firstPart: number
  private part: number
  private text = ''
  private bytes = 0
  private isDirty = false

  constructor(directory: string, base: string, firstPart = 0) {
    this.directory = directory
    this.base = base
    this.firstPart = firstPart
    this.part = firstPart
  }

  get hasPending(): boolean {
    return this.isDirty
  }

  private path(): string {
    return joinPath(this.directory, ownPartName(this.base, this.part))
  }

  async append(io: HookIo, line: string): Promise<void> {
    const lineBytes = byteLength(line) + 1
    // 待寫的列累積到 MAX_PENDING_BYTES 仍寫不進去時才放棄並換段，記憶體用量因此有上限。
    if (this.bytes > 0 && this.bytes + lineBytes > ROTATE_BYTES && (!this.isDirty || this.bytes > MAX_PENDING_BYTES)) { this.part++; this.text = ''; this.bytes = 0 }
    this.text += line + '\n'
    this.bytes += lineBytes
    this.isDirty = true
    await this.flush(io)
  }

  /** 把記憶體中的全文寫回目前段。失敗時保留待寫狀態並拋出例外。 */
  async flush(io: HookIo): Promise<void> {
    if (!this.isDirty) return
    await io.writeText(this.path(), this.text)
    this.isDirty = false
  }
}

// 錯誤紀錄：每個資料目錄一份本實例專用的 errors.<實例>.jsonl，依序寫入。
const errorLogs = new Map<string, { log: OwnLog; queue: Promise<void> }>()

async function appendError(io: HookIo, directory: string, record: Record<string, unknown>): Promise<void> {
  let entry = errorLogs.get(directory)
  if (entry === undefined) {
    entry = { log: new OwnLog(directory, 'errors'), queue: Promise.resolve() }
    errorLogs.set(directory, entry)
  }
  const log = entry.log
  const run = entry.queue.then(async () => {
    try { await log.append(io, JSON.stringify(record)) } catch { /* 寫不進去的錯誤紀錄留在待寫內容，下一筆成功時一併落檔 */ }
  })
  entry.queue = run
  await run
}

type Entry = { ts: string; isPrompt: boolean; line: string }
// 計數只需要 turn 數與目前 turn 的列：每個檔只保留 UserPromptSubmit 的筆數與最後一個 UserPromptSubmit 起的列。
// 檔內最後一個 UserPromptSubmit 之前的列，時間都早於全域最後一個 UserPromptSubmit，不會屬於目前 turn。
type Tail = { promptCount: number; entries: Entry[] }
type ForeignFile = { size: number; tail: Tail }
type SessionState = { own: OwnLog; ownTail: Tail; foreign: Map<string, ForeignFile>; merged: Entry[] | undefined }
type SessionView = { promptCount: number; currentLines: string[]; readFailed: boolean }

function toEntry(line: string): Entry {
  const row = parseJson(line)
  const ts = field(row, 'ts')
  return { ts: typeof ts === 'string' ? ts : '', isPrompt: PROMPT_LINE.test(line) && sameText(field(row, 'event'), 'UserPromptSubmit'), line }
}

function addToTail(tail: Tail, entry: Entry): void {
  if (entry.isPrompt) { tail.promptCount++; tail.entries = [] }
  tail.entries.push(entry)
}

function tailOf(text: string): Tail {
  const tail: Tail = { promptCount: 0, entries: [] }
  for (const line of splitLines(text)) addToTail(tail, toEntry(line))
  return tail
}

function sessionFilePattern(session: string): RegExp {
  // <session>.jsonl（命令型 hook 時期的檔）與 <session>.<實例>.jsonl、<session>.<實例>.<段>.jsonl。session 名稱只含 [A-Za-z0-9_-]。
  return new RegExp(`^${session}(\\.[A-Za-z0-9]+(\\.[0-9]+)?)?\\.jsonl$`, 'u')
}

// 同一個模組實例內的 session 狀態。本實例寫的紀錄留在記憶體；其他實例與命令型 hook 時期的檔依大小變化重新讀取。
// 一個行程通常只服務一個 session（含子代理）；保留上限 MAX_SESSIONS 個，超過時釋放最久未使用且沒有事件進行中的 session，
// session 結束時也釋放。釋放前先寫回待寫的列；再次收到該 session 的事件時從磁碟重新讀取，本實例改寫新的段號。
const MAX_SESSIONS = 16
const sessions = new Map<string, SessionState>()

function sessionKey(directory: string, session: string): string {
  return directory + '\t' + session
}

async function releaseState(io: HookIo, key: string): Promise<void> {
  const state = sessions.get(key)
  if (state === undefined) return
  try { await state.own.flush(io) } catch { /* 寫不進去時放棄待寫的列 */ }
  sessions.delete(key)
}

async function evictIdleSessions(io: HookIo, keep: string): Promise<void> {
  for (const key of [...sessions.keys()]) {
    if (sessions.size < MAX_SESSIONS) return
    const session = key.slice(key.indexOf('\t') + 1)
    if (key === keep || queues.has(session)) continue
    await releaseState(io, key)
  }
}

async function sessionView(io: HookIo, directory: string, session: string): Promise<{ state: SessionState; view: SessionView }> {
  const key = sessionKey(directory, session)
  let entries: { name: string; size: number }[] = []
  try { entries = await io.list(directory) } catch { entries = [] }
  const pattern = sessionFilePattern(session)
  let state = sessions.get(key)
  if (state === undefined) {
    await evictIdleSessions(io, key)
    // 本實例先前釋放過這個 session 時，已寫的段視同其他檔讀取，新的紀錄從下一個段號開始寫，不覆寫已落檔的內容。
    const usedParts = entries.map(entry => ownPartOf(session, entry.name)).filter((part): part is number => part !== undefined)
    const firstPart = usedParts.length === 0 ? 0 : Math.max(...usedParts) + 1
    state = { own: new OwnLog(directory, session, firstPart), ownTail: { promptCount: 0, entries: [] }, foreign: new Map(), merged: undefined }
  } else {
    sessions.delete(key)
  }
  // 以插入順序記錄最近使用的 session。
  sessions.set(key, state)
  const firstPart = state.own.firstPart
  const names = entries
    .filter(entry => pattern.test(entry.name) && (ownPartOf(session, entry.name) ?? -1) < firstPart)
    .sort((left, right) => left.name.length - right.name.length || (left.name < right.name ? -1 : left.name > right.name ? 1 : 0))
  let readFailed = false
  let isChanged = names.length !== state.foreign.size
  const next = new Map<string, ForeignFile>()
  for (const entry of names) {
    const cached = state.foreign.get(entry.name)
    if (cached !== undefined && cached.size === entry.size) { next.set(entry.name, cached); continue }
    isChanged = true
    // 超過讀取上限或連續讀取失敗的檔不納入計數，本筆紀錄標記 read_failed；檔案本身不改動，下一個事件再試。
    const text = entry.size > READ_LIMIT_BYTES ? undefined : await readWithRetry(io, joinPath(directory, entry.name))
    if (text === undefined) { readFailed = true; continue }
    next.set(entry.name, { size: entry.size, tail: tailOf(text) })
  }
  if (readFailed || isChanged) {
    state.foreign = next
    state.merged = undefined
  }
  if (state.merged === undefined) {
    // 依紀錄時間合併各檔；沒有 ts 的列排在最前，同時間的列保留檔內順序。
    const all: Entry[] = []
    for (const file of state.foreign.values()) all.push(...file.tail.entries)
    all.push(...state.ownTail.entries)
    state.merged = all.sort((left, right) => (left.ts < right.ts ? -1 : left.ts > right.ts ? 1 : 0))
  }
  let promptCount = state.ownTail.promptCount
  for (const file of state.foreign.values()) promptCount += file.tail.promptCount
  let lastPrompt = -1
  state.merged.forEach((entry, index) => { if (entry.isPrompt) lastPrompt = index })
  const currentLines = (lastPrompt < 0 ? state.merged : state.merged.slice(lastPrompt)).map(entry => entry.line)
  return { state, view: { promptCount, currentLines, readFailed } }
}

function addOwnEntry(state: SessionState, line: string): void {
  const entry = toEntry(line)
  addToTail(state.ownTail, entry)
  if (state.merged === undefined) return
  // 新的 UserPromptSubmit 之後，目前 turn 只剩這一列；其餘的列不再需要保留。
  if (entry.isPrompt) state.merged = [entry]
  else state.merged.push(entry)
}

/** session 結束時釋放該 session 在本實例的狀態（等該 session 進行中的事件處理完）。 */
export async function releaseTurnGuardSession(io: HookIo, dataRoot: string | undefined, session: string): Promise<void> {
  if (dataRoot === undefined || isBlank(dataRoot)) return
  const key = sessionKey(joinPath(dataRoot, 'turn-guard'), session)
  const pending = queues.get(session)
  if (pending !== undefined) { try { await pending } catch { /* 已在佇列中處理 */ } }
  await releaseState(io, key)
}

async function record(io: HookIo, directory: string, session: string, input: Record<string, unknown>, startedAt: number): Promise<string | undefined> {
  const event = field(input, 'hook_event_name')
  const { state, view } = await sessionView(io, directory, session)
  if (view.readFailed) {
    await appendError(io, directory, { ts: timestamp(), session_id: session, event: event ?? null, type: 'read_failed', message: 'session read failed after three attempts' })
  }

  const isPrompt = sameText(event, 'UserPromptSubmit')
  const turn = isPrompt ? view.promptCount + 1 : view.promptCount
  const counts: Counts = { read: 0, search: 0, readonly_cmd: 0, other: 0, failure: 0, evidence: 0 }
  const fingerprints = new Map<string, Fingerprint>()
  if (!isPrompt) {
    for (const line of view.currentLines) {
      const row = parseJson(line)
      if (row === undefined) continue
      const rowClass = field(row, 'class')
      const countKey = typeof rowClass === 'string' ? COUNT_KEYS.find(key => key === rowClass.toLowerCase()) : undefined
      if (countKey !== undefined) counts[countKey]++
      if (sameText(field(row, 'event'), 'PostToolUseFailure')) {
        counts.failure++
        const fingerprint = field(row, 'fingerprint')
        if (isRecord(fingerprint)) {
          // 指紋次數以 agent_id 加 hash 分開計算，同一 turn 內不同 agent 的失敗互不累計。
          const agent = agentName(field(row, 'agent_id'))
          const hash = String(fingerprint['hash'] ?? '')
          const key = (agent + '\t' + hash).toLowerCase()
          fingerprints.set(key, { agent, hash, text: String(fingerprint['text'] ?? ''), repeat: (fingerprints.get(key)?.repeat ?? 0) + 1 })
        }
      }
    }
  }

  const row: Record<string, unknown> = { v: 1, ts: timestamp(), session_id: session, event: event ?? null, turn, cwd: field(input, 'cwd') ?? null, agent_id: field(input, 'agent_id') ?? null }
  if (view.readFailed) row['read_failed'] = true
  let reminder: string | undefined
  if (isPrompt) {
    const prompt = field(input, 'prompt')
    row['prompt_chars'] = (prompt === undefined || prompt === null ? '' : String(prompt)).length
  }
  const isFailure = sameText(event, 'PostToolUseFailure')
  if (isFailure || sameText(event, 'PostToolUse')) {
    const toolName = field(input, 'tool_name')
    const tool = toolName === undefined || toolName === null ? '' : String(toolName)
    const toolInput = field(input, 'tool_input')
    const rowClass = classify(tool, toolInput)
    counts[rowClass]++
    row['tool'] = tool
    row['class'] = rowClass
    if (isFailure) {
      counts.failure++
      const errorText = field(input, 'error')
      const errorLine = (typeof errorText === 'string' ? errorText : '').split(/[\r\n]+/u).find(line => !isBlank(line)) ?? ''
      const text = tool + '|' + normalizeFingerprintPart(failureSubject(tool, toolInput)) + '|' + normalizeFingerprintPart(errorLine)
      const hash = await shortHash(text)
      const agent = agentName(field(input, 'agent_id'))
      const key = (agent + '\t' + hash).toLowerCase()
      const repeat = (fingerprints.get(key)?.repeat ?? 0) + 1
      fingerprints.set(key, { agent, hash, text, repeat })
      row['fingerprint'] = { hash, text, repeat }
      // 同一失敗在同一 turn、同一 agent 內累計第 2 次時提醒一次，第 3 次以後不再提醒。
      if (repeat === 2) {
        row['reminded'] = true
        reminder = '同一失敗已在本 turn 重複 ' + repeat + ' 次：' + text + '。下一次嘗試前先說明為什麼這次會成功；說不出來就停下並回報。'
      }
      const interrupt = field(input, 'is_interrupt')
      row['is_interrupt'] = typeof interrupt === 'boolean' ? interrupt : null
    }
  }
  counts.evidence = counts.read + counts.search + counts.readonly_cmd
  row['counts'] = counts
  // Stop 只在主 Session 觸發，摘要只列主 Session 的指紋。
  if (sameText(event, 'Stop')) {
    row['fingerprints'] = [...fingerprints.values()].filter(item => item.agent === '').map(item => ({ hash: item.hash, text: item.text, repeat: item.repeat }))
    row['turn_end'] = true
  }
  row['hook_ms'] = Date.now() - startedAt
  const line = JSON.stringify(row)
  let writeError: unknown
  try { await state.own.append(io, line) } catch (error) { writeError = error }
  // 計數以記憶體為準：寫入失敗時本筆仍計入並照常回傳提醒，保護不因資料目錄無法寫入而停止；失敗另記 hook_error。
  addOwnEntry(state, line)
  if (writeError !== undefined) {
    const message = writeError instanceof Error ? writeError.message : String(writeError)
    await appendError(io, directory, { ts: timestamp(), event: event ?? null, type: 'hook_error', message: message.length > 200 ? message.slice(0, 200) : message })
  }
  return reminder
}

// 同一 session 的事件依序處理：讀取既有紀錄、重算與寫回不得交錯。
const queues = new Map<string, Promise<unknown>>()

/**
 * 處理一個 turn-guard 事件。input 為 classic hook 的輸入（命令型 hook 的 stdin 內容），無法解析時傳入 undefined。
 * dataRoot 為外掛資料目錄，未取得時不寫任何檔案。回傳值為要注入給模型的提醒文字。
 */
export async function handleTurnGuardEvent(io: HookIo, dataRoot: string | undefined, input: unknown): Promise<string | undefined> {
  if (dataRoot === undefined || isBlank(dataRoot)) return undefined
  const startedAt = Date.now()
  const directory = joinPath(dataRoot, 'turn-guard')
  const session = field(input, 'session_id')
  if (!isRecord(input) || typeof session !== 'string' || !SESSION_NAME.test(session)) {
    await appendError(io, directory, { ts: timestamp(), event: null, type: 'stdin_invalid', message: 'stdin_invalid' })
    return undefined
  }
  const previous = queues.get(session) ?? Promise.resolve()
  // 前一個事件失敗不影響後續事件：失敗在 catch 中轉成 hook_error 紀錄，佇列繼續。
  const current = previous.then(() => record(io, directory, session, input, startedAt)).catch(async (error: unknown) => {
    const message = error instanceof Error ? error.message : String(error)
    await appendError(io, directory, { ts: timestamp(), event: field(input, 'hook_event_name') ?? null, type: 'hook_error', message: message.length > 200 ? message.slice(0, 200) : message })
    return undefined
  })
  queues.set(session, current)
  try {
    return await current
  } finally {
    if (queues.get(session) === current) queues.delete(session)
  }
}
