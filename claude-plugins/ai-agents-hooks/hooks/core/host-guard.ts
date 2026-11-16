// 攔截直接呼叫 powershell.exe（Windows PowerShell 5.1）的 Bash 與 PowerShell 命令。
// 這是策略提醒，不是安全邊界。偵測採最佳努力，無法涵蓋巢狀 shell（cmd /c powershell.exe）、字串組合執行與別名。
// 任何無法判定的情況一律放行。
import { WHITE_SPACE_CLASS, isBlank, isWhiteSpace, sameText, trimText } from './io'

const HEREDOC_START = new RegExp(`(?<!<)<<(?!<)-?[${WHITE_SPACE_CLASS}]*`, 'gu')

export const ALLOWED_SCRIPT_NAME = 'Setup-AIGlobalConfig.ps1'
export const OPT_IN_VARIABLE_NAME = 'AI_AGENTS_ALLOW_POWERSHELL51'
const LAUNCHER_COMMANDS = ['start-process', 'saps', 'start']
const BACKTICK = '`'
const BACKSLASH = '\\'

export const HOST_GUARD_DENY_REASON = '禁止直接呼叫 powershell.exe（Windows PowerShell 5.1）。派工與 Claude 端腳本只支援 PowerShell 7，請改用 pwsh：執行腳本檔寫成 pwsh -NoProfile -File <script.ps1>，執行命令寫成 pwsh -NoProfile -Command <command>。唯一的內建例外是 ' +
  ALLOWED_SCRIPT_NAME + '。其他專案明確要求使用 5.1 時，請在 Claude Code 設定的 env 加入 ' + OPT_IN_VARIABLE_NAME + '=1。'

// 取出區段中最後一個 heredoc 的結束標記（<<EOF、<<-EOF、<<'EOF'、<<"EOF"）。masked 與 real 等長，引號內字元在 masked 中以空白取代，用來排除引號內的 <<。
function heredocDelimiter(real: string, masked: string): string | undefined {
  let delimiter: string | undefined
  for (const match of masked.matchAll(HEREDOC_START)) {
    const rest = real.slice(match.index + match[0].length)
    const found = /^(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))/u.exec(rest)
    if (found === null) continue
    delimiter = found[1] ?? found[2] ?? found[3]
  }
  return delimiter
}

// 以引號感知方式切段。單引號與雙引號內的分隔符不切；雙引號內的跳脫字元（Bash 為反斜線，PowerShell 為反引號）跳脫下一個字元；
// 分隔符為 ; | & 與換行（&& 與 || 會切出空段，無害）。heredoc 本文行直到結束標記為止不視為命令區段。
function splitCommandSegments(command: string, escapeChar: string): string[] {
  const segments: string[] = []
  let builder = ''
  let masked = ''
  let quote = ''
  let pendingDelimiter: string | undefined
  const length = command.length
  let index = 0
  while (index < length) {
    const char = command.charAt(index)
    if (quote !== '') {
      if (quote === '"' && char === escapeChar && index + 1 < length) {
        builder += char + command.charAt(index + 1)
        masked += '  '
        index += 2
        continue
      }
      if (char === quote) { quote = ''; masked += char } else { masked += ' ' }
      builder += char
      index++
      continue
    }
    if (char === '"' || char === '\'') {
      quote = char
      builder += char
      masked += char
      index++
      continue
    }
    if (char === ';' || char === '|' || char === '&' || char === '\n' || char === '\r') {
      const foundDelimiter = heredocDelimiter(builder, masked)
      if (foundDelimiter !== undefined) pendingDelimiter = foundDelimiter
      segments.push(builder)
      builder = ''
      masked = ''
      index++
      if (char === '\n' && pendingDelimiter !== undefined) {
        const bodyDelimiter = pendingDelimiter
        pendingDelimiter = undefined
        while (index < length) {
          let lineEnd = command.indexOf('\n', index)
          if (lineEnd < 0) lineEnd = length
          const bodyLine = trimText(command.slice(index, lineEnd))
          index = Math.min(lineEnd + 1, length)
          if (bodyLine === bodyDelimiter) break
        }
      }
      continue
    }
    builder += char
    masked += char
    index++
  }
  segments.push(builder)
  return segments
}

// 以引號感知方式依空白切 token，token 內容不含外層引號字元。
function splitSegmentTokens(segment: string, escapeChar: string): string[] {
  const tokens: string[] = []
  let builder = ''
  let quote = ''
  let hasToken = false
  let isEscaped = false
  for (let index = 0; index < segment.length; index++) {
    const char = segment.charAt(index)
    if (quote !== '') {
      if (isEscaped) { builder += char; isEscaped = false; continue }
      if (quote === '"' && char === escapeChar) { builder += char; isEscaped = true; continue }
      if (char === quote) { quote = '' } else { builder += char }
      continue
    }
    if (char === '"' || char === '\'') {
      quote = char
      hasToken = true
      continue
    }
    // 與舊版的 [char]::IsWhiteSpace 相同的空白集合。
    if (isWhiteSpace(char)) {
      if (hasToken) { tokens.push(builder); builder = ''; hasToken = false }
      continue
    }
    builder += char
    hasToken = true
  }
  if (hasToken) tokens.push(builder)
  return tokens
}

function tokenFileName(token: string): string {
  const index = Math.max(token.lastIndexOf('\\'), token.lastIndexOf('/'))
  return index >= 0 ? token.slice(index + 1) : token
}

function isWindowsPowerShellName(token: string): boolean {
  const name = tokenFileName(token).toLowerCase()
  return name === 'powershell' || name === 'powershell.exe'
}

export function isPowerShellExeInvocation(command: string, toolName: string): boolean {
  // Bash 以反斜線跳脫雙引號內的字元；PowerShell 以反引號跳脫，反斜線是一般字元（"C:\proj\" 在第二個引號結束）。
  const escapeChar = toolName === 'PowerShell' ? BACKTICK : BACKSLASH
  for (const segment of splitCommandSegments(command, escapeChar)) {
    const tokens = splitSegmentTokens(segment, escapeChar)
    let start = 0
    while (start < tokens.length && /^[A-Za-z_][A-Za-z0-9_]*=/u.test(tokens[start] ?? '')) start++
    const first = tokens[start]
    if (first === undefined) continue
    let isViolation = isWindowsPowerShellName(first)
    if (!isViolation && LAUNCHER_COMMANDS.includes(tokenFileName(first).toLowerCase())) {
      let target: string | undefined
      for (let index = start + 1; index < tokens.length; index++) {
        const token = tokens[index] ?? ''
        if (token.toLowerCase() === '-filepath') {
          target = tokens[index + 1]
          break
        }
        if (token.startsWith('-')) continue
        target = token
        break
      }
      isViolation = target !== undefined && isWindowsPowerShellName(target)
    }
    if (!isViolation) continue
    const isAllowed = tokens.some(token => tokenFileName(token).toLowerCase() === ALLOWED_SCRIPT_NAME.toLowerCase())
    if (!isAllowed) return true
  }
  return false
}

/** 應拒絕時回傳拒絕理由，放行時回傳 undefined。optIn 為環境變數 AI_AGENTS_ALLOW_POWERSHELL51 的值。 */
export function hostGuardDenyReason(optIn: string | undefined, toolName: unknown, command: unknown): string | undefined {
  try {
    if (optIn === '1') return undefined
    if (typeof toolName !== 'string' || (!sameText(toolName, 'Bash') && !sameText(toolName, 'PowerShell'))) return undefined
    if (typeof command !== 'string' || isBlank(command)) return undefined
    return isPowerShellExeInvocation(command, toolName) ? HOST_GUARD_DENY_REASON : undefined
  } catch {
    return undefined
  }
}
