---
name: messaging
description: '訊息佇列開發規範：RabbitMQ 與 MQTT 的命名慣例、冪等消費、重試與 DLQ 策略、MQTT 遺囑與持久 Session、Mosquitto 容器設定、訊息版本演進。當撰寫或修改訊息發佈與消費邏輯時自動套用。'
audience: agent
policy.allow_implicit_invocation: true
---

# 訊息佇列開發規範

消費者的宿主模式（BackgroundService、Scoped 服務存取）參閱 `csharp-background-service` skill，本文件不重複。

## 命名慣例（Crucial）

### RabbitMQ

| 物件 | 格式 | 範例 |
| --- | --- | --- |
| Exchange | `<domain>.<用途>`，小寫點分隔 | `order.events` |
| Queue | `<消費服務>.<事件>`，小寫點分隔 | `notification.order-created` |
| Routing Key | `<entity>.<動詞過去式>` | `order.created`、`order.cancelled` |
| Dead Letter Queue | 原 Queue 名稱加 `.dlq` 後綴 | `notification.order-created.dlq` |

- Exchange 型別預設使用 `topic`，僅在明確一對一場景使用 `direct`。
- 禁止使用預設 Exchange（空字串）發佈業務訊息。

### MQTT

- Topic 格式：`<系統>/<裝置類型>/<裝置ID>/<訊息類型>`，全小寫，**不以 `/` 開頭**，不在發佈端使用萬用字元。
- 萬用字元僅限訂閱端：`+` 用於單層（如 `plant/sensor/+/telemetry`），`#` 僅允許出現在結尾。
- Retained message 僅用於「最新狀態」語意的 topic（如裝置上線狀態），事件流 topic 禁用 retain。

## 消費端規範（Crucial）

- **冪等消費**：所有消費者必須可安全重複處理同一訊息。每則訊息帶唯一 `MessageId`，消費端以處理紀錄（DB 或快取）去重；無法去重時，處理邏輯本身必須設計為冪等（如 upsert）。
- **手動 Ack**：RabbitMQ 消費者關閉 auto-ack，業務處理成功後才 `BasicAck`；處理失敗依重試策略決定 `BasicNack`。
- **重試與 DLQ**：失敗訊息採有限次數重試（預設 3 次，含退避間隔），超過即送入 DLQ 並記錄告警。**禁止** `requeue: true` 的無限重回佇列（毒訊息會卡死佇列）。
- DLQ 訊息的重放屬人工決策，不寫自動重放邏輯（除非設計文件明確要求）。

## 發佈端規範

- RabbitMQ 業務訊息啟用 Publisher Confirms，未確認的發佈視為失敗處理。
- 訊息本體使用 JSON（camelCase），必要的中繼資訊（`MessageId`、`CorrelationId`、發佈時間、Schema 版本）放 header / user property，不混入業務 payload。
- MQTT QoS 選用：遙測數據用 QoS 0 或 1；控制指令用 QoS 1 並在應用層冪等；QoS 2 僅在無法冪等且不可重複的場景使用（成本高，需說明理由）。

## MQTT 連線與 Session

以下 MQTTnet 行為以 MQTTnet 5.0.1 為準。

- **遺囑訊息（Last Will）**：只在異常斷線（網路中斷、程式崩潰、未呼叫 `DisconnectAsync()` 就結束）時由 Broker 發佈。以預設原因正常呼叫 `DisconnectAsync()` 不會發送遺囑訊息，離線偵測不能依賴正常斷線路徑。MQTT 5.0 斷線時指定 Reason Code `0x04`（MQTTnet 的 `MqttClientDisconnectOptionsReason.DisconnectWithWillMessage`）則會發送；設定 Will Delay Interval 時，Broker 延後發送，期間內重新連線就不發送。
- **保留訊息（Retained Message）**：Broker 每個 topic 只保留最後一則，新訂閱者訂閱時立即收到；MQTT 5.0 可用訂閱選項 Retain Handling 控制是否接收。不適用於歷史紀錄或需要完整資料序列的場景。
- **持久 Session**：要在斷線期間保留訂閱與訊息，必須使用固定的 ClientId，訂閱使用 QoS 1 或 2。離線期間保留的訊息以 QoS 1 與 QoS 2 為準；QoS 0 是否保留由 Broker 決定，Mosquitto 的 `queue_qos0_messages` 預設為 `false`，不保留。
  - MQTT 3.1.1 以 `Clean Session = false` 保留 Session。
  - MQTT 5.0 拆成 Clean Start 與 Session Expiry Interval。Session Expiry Interval 預設為 `0`，斷線即刪除 Session；要保留 Session 必須設定 `WithSessionExpiryInterval()` 為大於 `0` 的秒數，`uint.MaxValue` 為永不過期。只設 `WithCleanStart(false)` 無法保留 Session。
  - MQTTnet 的 `WithCleanSession()` 與 `WithCleanStart()` 設定的是同一個值。

```csharp
MqttClientOptions options = new MqttClientOptionsBuilder()
    .WithTcpServer(brokerAddress, brokerPort)
    .WithClientId("client-001")
    .WithCleanStart(false)
    .WithSessionExpiryInterval(600)
    .Build();
```

## Mosquitto（Docker）

- `eclipse-mosquitto:2` 的 Mosquitto 以 `mosquitto` 使用者（UID 1883）執行。容器以 root 啟動時，entrypoint 會先將 `/mosquitto` 的擁有者改為 `mosquitto` 再降權；以非 root 使用者（Compose 的 `user:`）啟動、唯讀掛載或主機檔案系統不允許 chown 時不會自動修正，掛載的 config、data、log 目錄要預先將擁有者改為 `1883:1883`，否則 Mosquitto 無法讀寫。
- 設定 `allow_anonymous false` 並以 `password_file` 管理帳號，帳號以 `mosquitto_passwd` 產生。
- 設定 `persistence true` 與 `persistence_location`，Retain 訊息與 QoS 1、2 的 Session 才會保存到磁碟。
- 正式環境使用 TLS（8883），`log_type` 設為 `error warning notice`，避免記錄 debug 訊息。

## 訊息版本演進

- 訊息結構變更以**向下相容的增量欄位**為原則：只加可選欄位，不改名、不刪欄位、不改型別。
- 破壞性變更必須開新版本（header 帶 `schema-version`，或 topic / routing key 帶版本段），新舊版本並行至所有消費者升級完成。
- 消費者反序列化採寬鬆模式（忽略未知欄位），禁止因多出欄位而失敗。

## 禁止模式

- 禁止在 HTTP 請求處理管線中同步等待「訊息被消費完成」；發佈即返回，結果以查詢或回呼通知。
- 禁止把訊息佇列當資料庫用（以佇列長期保存業務狀態）。
- 禁止多個服務共用同一個 Queue 消費不同用途（一個 Queue 一個消費用途；廣播場景用 Exchange 綁多個 Queue）。
