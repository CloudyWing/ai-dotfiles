---
name: elasticsearch
description: 'Elasticsearch 開發規範：明確 mapping 與 dynamic 設定、Query DSL 與 Query String 查詢的語意陷阱（term 與分詞、minimum_should_match、日期範圍、exists、wildcard 與 regexp、nested）。當設計 index mapping、撰寫或審查 Elasticsearch 查詢時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# Elasticsearch 開發規範

本規範收錄 mapping 設計與查詢語法中不易察覺的行為差異。查詢語法的完整範例見下列筆記：

- [Elasticsearch Query DSL 查詢語法筆記](https://note.cloudywing.net/Elasticsearch%20Query%20DSL%20%E6%9F%A5%E8%A9%A2%E8%AA%9E%E6%B3%95%E7%AD%86%E8%A8%98)
- [Elasticsearch QueryString 查詢語法筆記](https://note.cloudywing.net/Elasticsearch%20QueryString%20%E6%9F%A5%E8%A9%A2%E8%AA%9E%E6%B3%95%E7%AD%86%E8%A8%98)
- [Elasticsearch 的 Dynamic Field Mapping 注意事項](https://note.cloudywing.net/Elasticsearch%20%E7%9A%84%20Dynamic%20Field%20Mapping%20%E6%B3%A8%E6%84%8F%E4%BA%8B%E9%A0%85)

## Mapping

正式環境的 index 使用明確 mapping（Explicit mapping）定義每個欄位的型別，不依賴動態對應。

- 動態對應把未通過日期或數字檢測的字串同時建成 `text` 與 `.keyword` 子欄位，雙重索引會增加儲存空間。需要同一欄位兼具全文檢索與精確比對時，在 mapping 明確宣告 multi-fields。
- 下列型別不會被動態對應產生，必須在 mapping 預先定義：
  - `geo_point`、`geo_shape`：符合地理結構的 JSON（如 `{"lat": 25.03, "lon": 121.56}`）只會被當成 `object`，無法使用 `geo_distance` 等地理查詢。
  - `nested`：物件陣列只會被建成 `object`，陣列中各物件的欄位被扁平化，無法依同一物件的欄位組合查詢。
  - 自訂 analyzer：動態對應只使用 standard analyzer，中文分詞或同義詞需在 mapping 指定。
- 資料來源有大量不同欄位名稱（使用者自訂欄位、動態 key）時會造成 mapping explosion。一個 index 預設最多 1000 個欄位，超過時拒絕寫入新文件。

### dynamic 參數

| 值 | 遇到新欄位時 |
| --- | --- |
| `true`（預設） | 自動加入 mapping |
| `runtime` | 以 runtime field 加入 mapping，不建索引，查詢時從 `_source` 即時計算；不佔索引空間，查詢較慢 |
| `false` | 忽略，不索引也不可搜尋，但仍保留在 `_source`；可避免 mapping explosion |
| `strict` | 拋出例外並拒絕該文件 |

`dynamic: true` 與 `dynamic: runtime` 的型別對應不同：

| JSON 資料 | `true` | `runtime` |
| --- | --- | --- |
| `null` | 不新增欄位 | 不新增欄位 |
| `true`、`false` | `boolean` | `boolean` |
| `double` | `float` | `double` |
| `long` | `long` | `long` |
| `object` | `object` | 不新增欄位 |
| `array` | 取決於第一個非 `null` 值 | 取決於第一個非 `null` 值 |
| 通過日期檢測的字串 | `date` | `date` |
| 通過數字檢測的字串 | `float` 或 `long` | `double` 或 `long` |
| 其他字串 | `text` 加 `.keyword` 子欄位 | `keyword` |

## Query DSL

需要 nested 查詢、地理查詢（`geo_distance`）、`function_score` 自訂評分，或需要 `filter` 這類不計分子句的 `bool` 組合時使用 Query DSL，Query String 無法表達這些查詢。Query String 的 `AND`、`OR`、`NOT` 只能組合計分的條件。

### term 與全文檢索

- 對 `text` 欄位使用 `term` 時，查詢值不經過分詞，卻要比對索引中已分詞的詞彙。查詢 `"Elasticsearch Guide"` 找不到任何結果，因為索引存的是 `elasticsearch` 與 `guide`。`text` 欄位的全文檢索使用 `match`。
- `fuzzy` 查詢的值不經過分析器，大小寫差異也算進編輯距離。預設 `fuzziness: AUTO` 對 3 到 5 個字元的詞只容許 1 次編輯，`"Wing"` 與索引中轉小寫後的 `wing` 已用掉這 1 次，再有拼字差異就比對不到；查詢值先轉成與索引相同的大小寫。

### minimum_should_match

- 負數表示可遺漏的數量或比例。設為 `-N`（N 等於 token 總數）或 `-100%` 時，仍至少要符合 1 個詞才會回傳，不會回傳全部資料。
- 百分比換算後無條件捨去，例如 5 個詞的 `-25%` 為最多遺漏 1 個。
- 多條件組合 `N1<VALUE1 N2<VALUE2` 以區間解讀。token 數不超過 N1 時套用預設的 100%；大於 N1 且不超過 N2 時套用 VALUE1；大於 N2 時套用 VALUE2。例如 `2<-25% 9<-3` 為「2 個以下全符合、3~9 個最多遺漏 25%、超過 9 個最多遺漏 3 個」。

### match 的其他參數

- `lenient` 預設為 `false`，查詢值與欄位型別不符（例如對 `integer` 欄位查 `"not a number"`）時整個查詢失敗。設為 `true` 時不報錯，但該欄位的條件不會符合任何文件，等同被靜默忽略。
- `zero_terms_query` 只在查詢詞全部被分析器移除（例如全是 stop word）時作用。查詢詞沒被移除、只是索引中找不到時，照常回傳 0 筆。

### multi_match 與 combined_fields

- `cross_fields` 在欄位的 `search_analyzer` 不一致時改依 analyzer 分組，每組各自當成一個合併欄位比對，最後取分數最高的一組。每組只有一個欄位時，所有詞必須出現在同一欄位，行為接近 `best_fields`。
- `combined_fields` 要求所有欄位使用相同的 `search_analyzer`，不一致時查詢失敗；只支援 `text` 欄位，只支援 BM25 相似度。同義詞設定在 `search_analyzer`，所有查詢欄位需使用相同的同義詞設定。
- `combined_fields` 的子句數為「欄位數 × 詞彙數」，受 `indices.query.bool.max_clause_count` 限制。

### range 查詢的日期

- `time_zone` 轉換查詢值，也影響 `now/d` 這類 date math 的捨入，但不改變 `now` 本身，`now` 永遠是目前的 UTC 時間。
- 日期格式不完整時，缺少的元件依下表補齊，年份保留原值。下表適用於 `gt`；`gte` 與 `lt` 的補值行為未見官方說明，依賴前先實測：

  | 元件 | 補值 |
  | --- | --- |
  | 月 | `01` |
  | 日 | `01` |
  | 時 | `23` |
  | 分 | `59` |
  | 秒 | `59` |
  | 奈秒 | `999_999_999` |

- 數值會被解釋為毫秒時間戳記，`"gte": 2020` 是 `1970-01-01T00:00:02.020Z`，`"gte": "2020"` 才是 2020 年。
- 同一個 range 混用數值與日期格式字串（`"gte": 2022, "lte": "2025-01-01"`）會被判定格式錯誤。
- 欄位有自訂 `format` 時，查詢值必須符合該格式。

### exists 查詢

下列 mapping 設定會讓欄位有值的文件被 `exists` 判定為不存在：

- `index: false` 且 `doc_values: false`：欄位既不建索引也沒有 doc values。只設 `index: false` 而保留 doc values 或 norms 時，`exists` 仍可判定欄位存在。
- `ignore_above`：`keyword` 值長度超過上限時不建索引。
- `ignore_malformed: true`：格式錯誤的值被忽略，文件照常寫入。

### wildcard 與 regexp

- `wildcard` 與 `regexp` 要逐一比對索引中的詞彙，效能較差；以 `*` 或 `?` 開頭的模式需要比對的詞彙最多，避免使用。
- Lucene 正規表達式不支援 `^`、`$` 錨點，運算式必須匹配整個詞彙。
- `~`（否定）、`#`（空語言）、`<>`（數值範圍）、`&`（交集）、`@`（任意字串）是 Lucene 的擴充運算子，依 `flags` 啟用，不是通用正規表達式語法。對 `text` 欄位使用 `~` 否定時，比對對象是分詞後的詞彙。

### nested 查詢

物件陣列需要依同一物件內的欄位組合查詢時，欄位宣告為 `nested` 並使用 `nested` 查詢。使用 `object` 型別時欄位被扁平化，會符合「A 物件的姓名加 B 物件的年齡」這類錯誤組合。

## Query String

- `AND`、`OR`、`NOT` 運算子必須全部大寫，小寫會被當成一般詞彙。
- 多個值以空白分隔時：
  - `text` 欄位：`apple banana` 等同 `apple OR banana`。
  - `keyword` 欄位：`apple banana` 被視為一個完整字串而查不到；寫成 `"apple" "banana"` 或 `apple OR banana`。
  - 數值、日期、布林欄位：`123 456` 不會自動拆成多個值而查不到；寫成 `"123" "456"` 或 `123 OR 456`。
- 比較運算子（`>`、`>=`、`<`、`<=`）搭配 `fields` 陣列參數時會產生錯誤；使用 `default_field` 或在查詢字串中指定欄位（`price:>=10`）可正常運作。範圍查詢語法 `[a TO b]` 在各種參數組合下相容性較佳。
- 日期查詢：
  - 含冒號的完整時間格式要用雙引號包住，例如 `timestamp:"2023-01-15T08:30:00Z"`，否則冒號被當成特殊字元而解析錯誤。
  - 日期欄位使用比較運算子（`timestamp:>="..."`）時，查詢會變成在全部欄位搜尋該值；改用範圍語法 `timestamp:[2023-01-15 TO *]`。
  - 欄位有自訂 `format` 而查詢格式不符時，在查詢字串指定欄位會靜默回傳 0 筆，使用 `default_field` 或 `fields` 則回報 `failed to parse date field`。
- `analyze_wildcard` 預設為 `false`。官方文件說明設為 `true` 時只有結尾為 `*` 的詞會完整分析，開頭或中間有 `*` 的只做正規化；對 `keyword` 欄位指定 `standard` analyzer 的實測結果是 `Te*` 不轉小寫、`*Te*` 與 `T*e` 會轉小寫，與文件描述不一致，依賴此行為前先實測。
- `fuzziness` 參數只對查詢字串中帶 `~` 的詞生效，沒有 `~` 的詞一律精確比對。
- 特殊字元 `+ - = && || ! ( ) { } [ ] ^ " ~ * ? : \ /` 作為一般字元使用時以 `\` 跳脫。`<` 與 `>` 無法跳脫，會被當成範圍查詢，要從查詢字串中移除。
