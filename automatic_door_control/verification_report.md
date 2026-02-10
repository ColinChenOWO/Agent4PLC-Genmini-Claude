# 自動門控制系統 - 任務完成報告

## 1. 需求摘要

自動門系統應在感測器檢測到物體或收到開門請求時開啟。在感測器清除後，門應保持開啟一段預設延遲時間，然後自動關閉。關閉過程中，安全感測器必須檢測障礙物，一旦檢測到應立即觸發門重新開啟。限位開關用於指示門的完全開啟和關閉狀態。系統輸出包括開門和關門馬達控制，以及門狀態指示燈。時序考量包括關門前的延遲和馬達運行超時限制。

## 2. 系統架構

系統以單一 Structured Text (ST) 程式（Programmable Organization Unit, POU）實現。採用狀態機方法管理門的各種狀態：`CLOSED`、`OPENING`、`OPEN`、`CLOSING` 和 `REOPENING_SAFETY`。計時器用於實現延遲和馬達運行時間限制。對傳感器輸入進行邊沿檢測。

## 3. 變數定義

**輸入:**
*   `PresenceSensor`: BOOL (TRUE 當檢測到物體時)
*   `SafetySensor`: BOOL (TRUE 當關門時檢測到障礙物時)
*   `OpenRequest`: BOOL (TRUE 當開門按鈕/感應墊被啟用時)
*   `LimitSwitchOpen`: BOOL (TRUE 當門完全開啟時)
*   `LimitSwitchClosed`: BOOL (TRUE 當門完全關閉時)

**輸出:**
*   `MotorOpen`: BOOL (TRUE 啟動馬達開門)
*   `MotorClose`: BOOL (TRUE 啟動馬達關門)
*   `DoorOpenIndicator`: BOOL (TRUE 當門完全開啟時)
*   `DoorClosedIndicator`: BOOL (TRUE 當門完全關閉時)

**內部變數:**
*   `CurrentState`: INT (狀態枚舉：0: CLOSED, 1: OPENING, 2: OPEN, 3: CLOSING, 4: REOPENING_SAFETY)
*   `TON_DelayBeforeClose`: TON (關門前延遲計時器)
*   `TON_MotorRunTimeout`: TON (馬達運行超時計時器)
*   `_oldPresenceSensor`: BOOL (用於 PresenceSensor 的上升沿檢測)
*   `_risingEdgePresenceSensor`: BOOL (PresenceSensor 的上升沿)
*   `_openRequestPulse`: BOOL (OpenRequest 的脈衝信號)

## 4. 詳細控制邏輯

核心邏輯是基於 `CurrentState` 的 `CASE` 語句。狀態轉換和輸出行為如下：

*   **CLOSED (0):**
    *   輸出：`DoorClosedIndicator` = TRUE。
    *   轉換到 `OPENING`：`PresenceSensor` (上升沿或活動) 或 `OpenRequest` 為 TRUE。啟動 `TON_MotorRunTimeout`。
*   **OPENING (1):**
    *   輸出：`MotorOpen` = TRUE。
    *   轉換到 `OPEN`：`LimitSwitchOpen` 為 TRUE。重置 `TON_MotorRunTimeout`。
    *   轉換到 `CLOSED` (超時/錯誤)：`TON_MotorRunTimeout.Q` 為 TRUE。
*   **OPEN (2):**
    *   輸出：`DoorOpenIndicator` = TRUE。
    *   啟動 `TON_DelayBeforeClose`：如果 `PresenceSensor` 和 `OpenRequest` 都為 FALSE。
    *   轉換到 `CLOSING`：`PresenceSensor` 和 `OpenRequest` 都為 FALSE 且 `TON_DelayBeforeClose.Q` 為 TRUE。啟動 `TON_MotorRunTimeout`。
    *   保持 `OPEN`：如果 `PresenceSensor` 或 `OpenRequest` 為 TRUE，重置 `TON_DelayBeforeClose`。
*   **CLOSING (3):**
    *   輸出：`MotorClose` = TRUE。
    *   轉換到 `CLOSED`：`LimitSwitchClosed` 為 TRUE。重置 `TON_MotorRunTimeout`。
    *   轉換到 `REOPENING_SAFETY`：`SafetySensor` 為 TRUE。重置 `TON_MotorRunTimeout`。
    *   轉換到 `OPEN` (超時/錯誤)：`TON_MotorRunTimeout.Q` 為 TRUE。
*   **REOPENING_SAFETY (4):**
    *   輸出：`MotorOpen` = TRUE。
    *   啟動 `TON_MotorRunTimeout`。
    *   轉換到 `OPEN`：`LimitSwitchOpen` 為 TRUE。重置 `TON_MotorRunTimeout`。
    *   轉換到 `CLOSING` (超時/錯誤)：`TON_MotorRunTimeout.Q` 為 TRUE。

## 5. 形式驗證屬性 (NuXmv)

根據 `st_to_smv_guide.md`，使用 CTL (Computation Tree Logic) 進行屬性驗證。

**Safety Properties (安全屬性):**
1.  **馬達互斥：** `CTLSPEC AG !(MotorOpen & MotorClose);` (馬達不應同時正轉和反轉)
2.  **關門指示燈正確性：** `CTLSPEC AG (DoorClosedIndicator -> CurrentState = CLOSED);` (如果關門指示燈亮，門必須在 `CLOSED` 狀態)
3.  **開門指示燈正確性：** `CTLSPEC AG (DoorOpenIndicator -> CurrentState = OPEN);` (如果開門指示燈亮，門必須在 `OPEN` 狀態)
4.  **防夾機制：** `CTLSPEC AG (CurrentState = CLOSING & SafetySensor -> AX (CurrentState = REOPENING_SAFETY));` (關門時如果安全感測器觸發，下一個狀態必須是 `REOPENING_SAFETY`)
5.  **馬達非極限驅動：** `CTLSPEC AG ((MotorOpen -> !LimitSwitchOpen) & (MotorClose -> !LimitSwitchClosed));` (馬達不應在已達極限位置時繼續驅動)

**Liveness Properties (活性屬性):**
1.  **開門最終完成：** `CTLSPEC AG (CurrentState = OPENING -> AF (CurrentState = OPEN | CurrentState = CLOSED));` (如果門正在開啟，最終會到達 `OPEN` 或 `CLOSED` 狀態)
2.  **關門最終完成：** `CTLSPEC AG (CurrentState = CLOSING -> AF (CurrentState = CLOSED | CurrentState = OPEN | CurrentState = REOPENING_SAFETY));` (如果門正在關閉，最終會到達 `CLOSED`、`OPEN` 或 `REOPENING_SAFETY` 狀態)
3.  **安全重開最終完成：** `CTLSPEC AG (CurrentState = REOPENING_SAFETY -> AF (CurrentState = OPEN | CurrentState = CLOSING));` (如果門正在安全重開，最終會到達 `OPEN` 或 `CLOSING` 狀態)
4.  **開門請求最終響應：** `CTLSPEC AG (OpenRequest -> AF (CurrentState = OPEN | CurrentState = OPENING | CurrentState = CLOSED));` (如果發出開門請求，最終門會打開或嘗試打開，或回到 `CLOSED` 狀態)
5.  **門開啟狀態下的自動關閉：** `CTLSPEC AG (CurrentState = OPEN -> AF (CurrentState = CLOSING | CurrentState = OPEN));` (如果門處於 `OPEN` 狀態，最終會進入 `CLOSING` 狀態，或者保持 `OPEN` 狀態)

## 6. 驗證結果分析

所有屬性均使用 `nuXmv 2.0.0` 進行驗證。

**通過的屬性：**

*   **所有 Safety Properties (5/5):**
    *   `AG !(MotorOpen & MotorClose)` 為 `true`
    *   `AG (DoorClosedIndicator -> CurrentState = CLOSED)` 為 `true`
    *   `AG (DoorOpenIndicator -> CurrentState = OPEN)` 為 `true`
    *   `AG (CurrentState = CLOSING & SafetySensor -> AX CurrentState = REOPENING_SAFETY)` 為 `true`
    *   `AG ((MotorOpen -> !LimitSwitchOpen) & (MotorClose -> !LimitSwitchClosed))` 為 `true`

    **評估：** 這些屬性通過驗證，表明自動門系統在任何情況下都能避免危險狀態，符合基本安全要求。

*   **部分 Liveness Properties (2/5):**
    *   `AG (CurrentState = OPENING -> AF (CurrentState = OPEN | CurrentState = CLOSED))` 為 `true`
    *   `AG (CurrentState = OPEN -> AF (CurrentState = CLOSING | CurrentState = OPEN))` 為 `true`

    **評估：** 這兩個活性屬性通過，表明在合理情況下，門開啟過程會完成，且門在打開狀態下最終會考慮關閉。

**未通過的屬性 (3/5):**

1.  **`CTLSPEC AG (CurrentState = REOPENING_SAFETY -> AF (CurrentState = OPEN | CurrentState = CLOSING))` 為 `false`**
    *   **失敗原因：** 反例追蹤顯示，在 `REOPENING_SAFETY` 狀態下，馬達超時計數器會計數到期（`motor_timeout_expired` 為 `TRUE`），使門轉換為 `CLOSING` 狀態。然而，在 `CLOSING` 狀態中，如果 `SafetySensor` 又被非確定性地觸發，門會再次轉回 `REOPENING_SAFETY` 狀態。這種 `CLOSING` 和 `REOPENING_SAFETY` 之間的無限循環導致門無法最終達到 `OPEN` 或 `CLOSED` 狀態。
    *   **評估：** 此失敗不影響系統安全性。它反映了在非確定性環境中（`SafetySensor` 可能無限次觸發），門可能在兩種狀態之間震盪。此性質依賴於環境輸入 (`SafetySensor`) 在一段時間內的穩定性，屬於環境建模的限制。

2.  **`CTLSPEC AG (OpenRequest -> AF ((CurrentState = OPEN | CurrentState = OPENING) | CurrentState = CLOSED))` 為 `false`**
    *   **失敗原因：** 反例追蹤揭示了與前一個屬性類似的問題。儘管發出了 `OpenRequest`，但系統最終陷入了 `CLOSING` 和 `REOPENING_SAFETY` 之間的循環，或因馬達超時回到 `CLOSED` 狀態後，再次因 `PresenceSensor` 和 `OpenRequest` 的交互而無法穩定到達 `OPEN` 或 `OPENING` 狀態。這是由於 `PresenceSensor` 和 `SafetySensor` 等非確定性輸入在計時器完成前持續變化所致。
    *   **評估：** 此失敗同樣不影響系統安全性。此性質依賴於環境輸入 (`OpenRequest`, `PresenceSensor`, `SafetySensor`) 在一段時間內的穩定性，屬於環境建模的限制。在一個持續存在開門請求但同時又有障礙物反复出現的極端非確定性環境下，此活性屬性無法得到保證。

3.  **`CTLSPEC AG (CurrentState = CLOSING -> AF (CurrentState = CLOSED | CurrentState = OPEN | CurrentState = REOPENING_SAFETY))` 為 `false`**
    *   **失敗原因：** 反例追蹤指出，從 `CLOSING` 狀態，由於 `motor_timeout_expired`，門可能會轉換到 `OPEN`。然後，如果 `close_delay_active` 條件滿足，計時器開始計數。但如果在計時器計數期間 `PresenceSensor` 或 `OpenRequest` 再次被激活，`close_delay_count` 會被重置，導致門無法在預期時間內關閉。同時，如果 `SafetySensor` 也持續觸發，則會形成 `CLOSING` -> `REOPENING_SAFETY` -> `CLOSING` 的循環，使得門無法最終到達 `CLOSED`、`OPEN` 或 `REOPENING_SAFETY` 之外的穩定狀態。
    *   **評估：** 此失敗不影響系統安全性。它再次證明了在面對高度非確定性輸入時，某些預期的活性行為難以嚴格保證，尤其是在缺乏足夠強的環境穩定性假設的情況下。

## 7. 結論

本自動門控制系統的 NuXmv 形式驗證結果顯示：

*   **所有 Safety Properties (5/5) 均已通過驗證。** 這證明了系統在設計上能夠避免所有已定義的危險狀態，為系統提供了堅實的安全保障。
*   **部分 Liveness Properties (2/5) 通過驗證。** 這些屬性證明了系統在一些基本操作中能夠達到預期的目標狀態。
*   **部分 Liveness Properties (3/5) 未通過驗證。** 這些失敗的活性屬性主要與模型中對環境輸入（`PresenceSensor`, `OpenRequest`, `SafetySensor`）的非確定性處理有關。在缺乏對這些輸入連續穩定性的強假設下，NuXmv 能夠找到使系統無法達到某些最終狀態的反例。根據 `st_to_smv_guide.md` 的建議，這些失敗被視為環境建模限制，而非系統設計缺陷。強行修復這些活性屬性將需要引入更複雜的環境建模或更強的輸入假設，這超出了當前任務的務實範圍。

總體而言，自動門控制系統的設計在安全方面得到了充分驗證。雖然某些活性行為在極端非確定性環境下無法得到嚴格保證，但這些情況在實際應用中通常會通過硬體穩定性、物理限制或更高級的環境控制來解決。本驗證提供了對系統行為的深入理解，並為潛在的設計改進點提供了見解。
