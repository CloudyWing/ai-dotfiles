// hook 核心邏輯對外的 I/O 介面。register.ts 以引擎的 $ 實作，tests/run-hook.ts 以 node 實作。
export interface HookIo {
  /** 讀取檔案位元組。檔案不存在或無法讀取時 reject。 */
  readBytes(path: string): Promise<Uint8Array>
  isDirectory(path: string): Promise<boolean>
  /** 執行外部命令並回傳結束碼。無法啟動時 reject。 */
  run(argv: readonly string[]): Promise<number>
  /** 輸出不送給模型的診斷文字。引擎的 $.ui.log 同步回傳 void。 */
  log(text: string): void
}

// 空白字元一律採 .NET 的定義（Char.IsWhiteSpace 與 .NET regex 的 \s，兩者相同）：
// U+0009 至 U+000D、U+0085 與 Unicode 的 Z 類（Zs、Zl、Zp）。JavaScript 的 \s 另含 U+FEFF、不含 U+0085，
// 因此移植自 PowerShell 的樣式不直接用 \s。doc-path 的終止字元另以明確列舉寫出，與 doc-path-check.ps1 字面相同。
export const WHITE_SPACE_CLASS = '\\t\\n\\v\\f\\r\\u0085\\p{Z}'
const WHITE_SPACE_CHAR = new RegExp(`^[${WHITE_SPACE_CLASS}]$`, 'u')
const LEADING_WHITE_SPACE = new RegExp(`^[${WHITE_SPACE_CLASS}]+`, 'u')
const TRAILING_WHITE_SPACE = new RegExp(`[${WHITE_SPACE_CLASS}]+$`, 'u')

export function isWhiteSpace(char: string): boolean {
  return WHITE_SPACE_CHAR.test(char)
}

/** 對應 .NET 的 String.Trim()。 */
export function trimText(value: string): string {
  return value.replace(LEADING_WHITE_SPACE, '').replace(TRAILING_WHITE_SPACE, '')
}

/** 對應 .NET 的 String.IsNullOrWhiteSpace。 */
export function isBlank(value: string): boolean {
  return trimText(value) === ''
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

export function field(value: unknown, name: string): unknown {
  return isRecord(value) ? value[name] : undefined
}

/** 以不分大小寫比較兩個字串，對應 PowerShell 的 -eq。 */
export function sameText(left: unknown, right: string): boolean {
  return typeof left === 'string' && left.toLowerCase() === right.toLowerCase()
}

/** 對應 [IO.Path]::GetExtension：最後一個分隔符之後的檔名中，最後一個句點起的部分。 */
export function extensionOf(path: string): string {
  const name = path.slice(Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'), path.lastIndexOf(':')) + 1)
  const index = name.lastIndexOf('.')
  if (index < 0 || index === name.length - 1) return ''
  return name.slice(index)
}

/** 對應 ReadAllLines 與 StreamReader.ReadLine：以 CRLF、LF 或 CR 斷行，結尾的換行不產生空行。 */
export function splitLines(text: string): string[] {
  if (text === '') return []
  const lines = text.split(/\r\n|\n|\r/u)
  if (lines[lines.length - 1] === '') lines.pop()
  return lines
}
