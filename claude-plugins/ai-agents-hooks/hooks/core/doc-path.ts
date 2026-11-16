// 本機路徑偵測。規則與 hooks/lib/doc-path-check.ps1 相同，兩份實作由 scripts/tests/Test-DocLocalPathCheck.ps1 以同一組輸入比對。
import type { HookIo } from './io'
import { extensionOf, field, isBlank, sameText } from './io'

// 路徑 token 的終止字元：空白、反引號、單雙引號與全形標點（，。；：、（）「」）。
// 空白以明確列舉寫出（.NET 的 \s：U+0009 至 U+000D、U+0085 與 Unicode Z 類），與 doc-path-check.ps1 的列舉字面相同。
const WHITE_SPACE = String.raw`\t\n\v\f\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000`
const TERMINATORS = WHITE_SPACE + '`\'"，。；：、（）「」'
// 起點：字母加冒號，後接一個以上的分隔符與至少一個路徑片段字元。字母前不得是英數字（排除 https://）。
const TOKEN_PATTERN = new RegExp(`(?<![A-Za-z0-9])[A-Za-z]:[\\\\/]+[^\\\\/${TERMINATORS}][^${TERMINATORS}]*`, 'gu')
// 豁免：磁碟機、分隔符、可選的 Users 片段，其後直接接佔位符。
const PLACEHOLDER_PATTERN = /^[A-Za-z]:[\\/]+(?:Users[\\/]+)?(?:<[^<>]+>|\{[^{}]+\}|%[^%]+%|\$)/iu
const TRAILING_PUNCTUATION = /[.,;:!?)\]}]+$/u
const DRIVE_ROOT_ONLY = /^[A-Za-z]:[\\/]*$/u

/** 回傳文字中含本機磁碟機絕對路徑的違規 token，無違規時為空陣列。 */
export function findLocalPathViolations(text: string): string[] {
  const violations: string[] = []
  if (text === '') return violations
  for (const match of text.matchAll(TOKEN_PATTERN)) {
    const token = match[0]
    if (PLACEHOLDER_PATTERN.test(token)) continue
    // 句尾的 ASCII 標點不屬於路徑；修剪後只剩磁碟機根目錄的不回報。
    const trimmed = token.replace(TRAILING_PUNCTUATION, '')
    if (trimmed.length > 0 && !DRIVE_ROOT_ONLY.test(trimmed)) violations.push(trimmed)
  }
  return violations
}

/** 路徑任一片段為 .local，或檔名符合 *.local.md 時回傳 true。不分大小寫，接受 \ 與 /。 */
export function isLocalPathExcludedFile(path: string): boolean {
  if (path === '') return false
  const segments = path.split(/[\\/]/u).filter(segment => segment !== '')
  if (segments.some(segment => segment.toLowerCase() === '.local')) return true
  const last = segments[segments.length - 1]
  return last !== undefined && last.toLowerCase().endsWith('.local.md')
}

function parentDirectory(path: string): string {
  const index = Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'))
  if (index < 0) return ''
  const parent = path.slice(0, index)
  return /^[A-Za-z]:$/u.test(parent) ? parent + '\\' : parent
}

/**
 * PostToolUse 提醒：Write 或 Edit 寫入進版控的 .md，且本次寫入的文字含磁碟機絕對路徑時回傳提醒文字。
 * 只提醒不阻擋，任何無法判定的情況回傳 undefined。
 */
export async function docPathReminder(io: HookIo, input: unknown): Promise<string | undefined> {
  try {
    const tool = field(input, 'tool_name')
    const isWrite = sameText(tool, 'Write')
    if (!isWrite && !sameText(tool, 'Edit')) return undefined
    const toolInput = field(input, 'tool_input')
    const filePath = field(toolInput, 'file_path')
    if (typeof filePath !== 'string' || isBlank(filePath)) return undefined
    if (extensionOf(filePath).toLowerCase() !== '.md') return undefined
    if (isLocalPathExcludedFile(filePath)) return undefined
    const text = field(toolInput, isWrite ? 'content' : 'new_string')
    if (typeof text !== 'string' || text.length === 0) return undefined

    const found: string[] = []
    text.split(/\r?\n/u).forEach((line, index) => {
      for (const token of findLocalPathViolations(line)) found.push(`line ${index + 1}: ${token}`)
    })
    if (found.length === 0) return undefined

    // 只在偵測到違規後才呼叫 git。結束碼 1 才是受控；0（被忽略）、128（非 repo）與找不到 git 皆略過。
    const directory = parentDirectory(filePath)
    if (directory === '' || !(await io.isDirectory(directory))) return undefined
    const exitCode = await io.run(['git', '-C', directory, 'check-ignore', '-q', '--', filePath])
    if (exitCode !== 1) return undefined

    return `doc-placement: ${filePath} 本次寫入的內容含本機磁碟機絕對路徑（行號相對於本次寫入的文字）：` +
      found.join('；') +
      '。進版控的文件不應含本機路徑。請改用佔位符（如 <sourceRoot>、C:\\<使用者>\\...）或相對路徑；必須記錄實際路徑時寫入 AGENTS.local.md、CONTEXT.local.md 或 .local 目錄。依 doc-placement skill 判定讀者與落點。'
  } catch {
    return undefined
  }
}
