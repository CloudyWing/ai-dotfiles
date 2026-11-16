// Write 或 Edit 之後的 Markdown 排版與 BOM 檢查。輸出不送給模型，只經由 io.log 留下診斷文字。
import type { HookIo } from './io'
import { WHITE_SPACE_CLASS, extensionOf, field, sameText, splitLines, trimText } from './io'

const DASH_PATTERN = '——'
const FULL_WIDTH_COLON = '：'
const CJK_COLON_CJK = /[一-鿿]：[一-鿿]/u
const COLON_LEAD_WHITELIST = ['如下', '例', '例如', '注意', '說明', '步驟', '格式', '適用情境', '限制', '用途', '條件', '定義', '原則']
const ALWAYS_BOM = ['.ps1', '.csv']
const NEVER_BOM = ['.md', '.json', '.xml', '.yaml', '.yml', '.sh', '.txt']
const PREFIX = '[post-edit-write hook]'
const FENCE = new RegExp(`^[${WHITE_SPACE_CLASS}]*\`\`\``, 'u')
const SENTENCE_END = new RegExp(`[。」][${WHITE_SPACE_CLASS}]*$`, 'u')

function hasBom(bytes: Uint8Array): boolean {
  return bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF
}

function markdownMessages(path: string, lines: readonly string[]): string[] {
  const dashHits: string[] = []
  const colonHits: string[] = []
  let isInFence = false
  lines.forEach((line, index) => {
    // 圍欄程式碼區塊內整段跳過。
    if (FENCE.test(line)) { isInFence = !isInFence; return }
    if (isInFence) return
    // 移除行內 code span，避免程式碼內符號誤判。
    const scan = line.replace(/`[^`]*`/gu, '')
    if (scan.includes(DASH_PATTERN)) dashHits.push(`  line ${index + 1}: ${trimText(line)}`)
    // 散文式冒號候選：CJK：CJK，冒號後為完整句（以。」結尾），且引言非標籤白名單。
    if (CJK_COLON_CJK.test(scan)) {
      const colonIndex = scan.indexOf(FULL_WIDTH_COLON)
      const lead = trimText(scan.slice(0, colonIndex))
      const tail = trimText(scan.slice(colonIndex + 1))
      const isLabel = COLON_LEAD_WHITELIST.some(word => lead.endsWith(word))
      if (!isLabel && tail !== '' && SENTENCE_END.test(tail)) colonHits.push(`  line ${index + 1}: ${trimText(line)}`)
    }
  })
  const messages: string[] = []
  if (dashHits.length > 0) {
    messages.push(`${PREFIX} WARNING: ${path} contains forbidden full-width dash (two consecutive U+2014). Replace with comma/semicolon or split into separate sentences:`, ...dashHits)
  }
  if (colonHits.length > 0) {
    messages.push(`${PREFIX} REVIEW: ${path} has candidate prose-colon lines (mid-sentence CJK colon with a full-sentence tail). Confirm each is not a narrative 'X:Y' continuation; legit lead-ins (e.g. '...如下:') and label fields are acceptable:`, ...colonHits)
  }
  return messages
}

/** 回傳本次寫入應輸出的診斷行，並逐行交給 io.log。無法判定時回傳空陣列。 */
export async function postEditWriteMessages(io: HookIo, input: unknown): Promise<string[]> {
  const messages: string[] = []
  const emit = (lines: readonly string[]): void => { for (const line of lines) { messages.push(line); io.log(line) } }
  try {
    const tool = field(input, 'tool_name')
    if (!sameText(tool, 'Write') && !sameText(tool, 'Edit')) return messages
    const path = field(field(input, 'tool_input'), 'file_path')
    if (typeof path !== 'string' || path === '') return messages
    const extension = extensionOf(path).toLowerCase()

    let bytes: Uint8Array | undefined
    try { bytes = await io.readBytes(path) } catch { bytes = undefined }

    if (extension === '.md') {
      emit([`${PREFIX} ${path} was written. Please run check-markdown skill to verify Markdown formatting.`])
      if (bytes !== undefined) emit(markdownMessages(path, splitLines(new TextDecoder('utf-8').decode(bytes))))
    }
    if (bytes === undefined) return messages

    if (ALWAYS_BOM.includes(extension)) {
      if (!hasBom(bytes)) emit([`${PREFIX} WARNING: ${path} is missing UTF-8 BOM. '${extension}' files require BOM. Please rewrite with BOM or run /fix-file-encoding.`])
    } else if (NEVER_BOM.includes(extension)) {
      if (hasBom(bytes)) emit([`${PREFIX} WARNING: ${path} has unexpected UTF-8 BOM. '${extension}' files should not have BOM. Please rewrite without BOM or run /fix-file-encoding.`])
    }
  } catch {
    // 檢查失敗不影響工具結果。
  }
  return messages
}
