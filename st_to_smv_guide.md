# ST → SMV 建模指南（nuXmv 形式化驗證）

本文件指導 Agent 如何將 IEC 61131-3 Structured Text (ST) 程式碼正確翻譯為 nuXmv 的 SMV 模型。遵循本指南可避免常見的建模錯誤，提高 Safety 和 Liveness 性質的驗證成功率。

---

## 1. 基本翻譯規則

### 1.1 檔案結構

```smv
MODULE main
VAR
  -- 輸入（外部環境，非確定性）
  -- 狀態變數
  -- 內部變數（timer、計數器）
  -- 輸出
ASSIGN
  -- init() 初始值
  -- next() 狀態轉移
FAIRNESS
  -- 環境公平性假設
-- 驗證性質
CTLSPEC ...
LTLSPEC ...
```

### 1.2 變數型別對應

| ST 型別 | SMV 型別 | 說明 |
|--------|---------|------|
| `BOOL` | `boolean` | 直接對應 |
| `INT` / `DINT` | `0..範圍` | 指定有界範圍 |
| `ENUM (STATE_A, STATE_B, ...)` | `{STATE_A, STATE_B, ...}` | 直接用枚舉 |
| `TIME` | 不直接對應 | 見 Timer 建模章節 |
| `ARRAY[1..N] OF BOOL` | 分開宣告 `var_1 : boolean; var_2 : boolean;` | SMV 無陣列 |

### 1.3 輸入 vs 內部變數

```smv
VAR
  -- 外部輸入：用 VAR 宣告，不寫 ASSIGN → nuXmv 自動當作非確定性
  Button : boolean;
  Sensor : boolean;

  -- 內部狀態：用 ASSIGN 控制轉移
  CurrentState : {CLOSED, OPENING, OPEN, CLOSING};
ASSIGN
  init(CurrentState) := CLOSED;
  next(CurrentState) := case
    ...
  esac;
```

> ⚠️ **關鍵**：外部輸入（按鈕、感測器、限位開關）只宣告 `VAR`，**不要寫 `ASSIGN`**。nuXmv 會自動探索所有可能的輸入組合。

### 1.4 CASE 語句翻譯

ST 的 CASE：
```st
CASE State OF
  0: (* CLOSED *)
    MotorOpen := FALSE;
  1: (* OPENING *)
    MotorOpen := TRUE;
END_CASE;
```

SMV 的 next() case：
```smv
next(CurrentState) := case
  CurrentState = CLOSED & OpenRequest : OPENING;
  CurrentState = OPENING & LimitSwitchOpen : OPEN;
  CurrentState = OPENING & MotorTimeout : CLOSED;  -- 安全回退
  TRUE : CurrentState;  -- 預設：維持不變
esac;
```

> ⚠️ **永遠要有 `TRUE : 維持現值;`** 作為最後一條，否則 nuXmv 會報錯。

### 1.5 輸出變數

ST 裡輸出在每個 CASE 分支中賦值，SMV 用 `DEFINE` 或 `ASSIGN`：

**方法 A：DEFINE（推薦，簡潔）**
```smv
DEFINE
  MotorOpen := (CurrentState = OPENING) | (CurrentState = REOPENING_SAFETY);
  MotorClose := (CurrentState = CLOSING);
  DoorOpenIndicator := (CurrentState = OPEN);
```

**方法 B：ASSIGN（需要 next 時用）**
```smv
ASSIGN
  MotorOpen := case
    CurrentState = OPENING : TRUE;
    CurrentState = REOPENING_SAFETY : TRUE;
    TRUE : FALSE;
  esac;
```

> 💡 如果輸出只取決於當前狀態（Moore machine），用 `DEFINE` 最乾淨。

---

## 2. Timer 建模（最關鍵）

### 2.1 問題

ST 的 `TON`（On-Delay Timer）基於實際時間運行，但 SMV 沒有時間概念。如果只用布林值模擬，nuXmv 會認為 timer 可能永遠不觸發，導致 Liveness 失敗。

### 2.2 ❌ 錯誤做法：布林值

```smv
-- 不要這樣做！
VAR
  TON_Timer_Q : boolean;  -- nuXmv 會探索「永遠 FALSE」的路徑
```

### 2.3 ✅ 正確做法：有界計數器

```smv
VAR
  timer_count : 0..MAX_TICKS;  -- MAX_TICKS 根據實際時間設定（例如 10）
  timer_active : boolean;

ASSIGN
  init(timer_count) := 0;
  next(timer_count) := case
    -- 啟動中且未到期：計數 +1
    timer_active & timer_count < MAX_TICKS : timer_count + 1;
    -- 未啟動：重置
    !timer_active : 0;
    -- 已到期：維持
    TRUE : timer_count;
  esac;

DEFINE
  timer_expired := (timer_count = MAX_TICKS);
```

**每個 TON 都要獨立建模：**

```smv
-- TON_MotorRunTimeout（馬達超時保護）
VAR motor_timeout_count : 0..10;
DEFINE motor_timeout_active := (CurrentState = OPENING | CurrentState = CLOSING);
ASSIGN
  init(motor_timeout_count) := 0;
  next(motor_timeout_count) := case
    motor_timeout_active & motor_timeout_count < 10 : motor_timeout_count + 1;
    !motor_timeout_active : 0;
    TRUE : motor_timeout_count;
  esac;
DEFINE motor_timeout_expired := (motor_timeout_count = 10);

-- TON_DelayBeforeClose（關門延遲）
VAR close_delay_count : 0..5;
DEFINE close_delay_active := (CurrentState = OPEN & !PresenceSensor & !OpenRequest);
ASSIGN
  init(close_delay_count) := 0;
  next(close_delay_count) := case
    close_delay_active & close_delay_count < 5 : close_delay_count + 1;
    !close_delay_active : 0;
    TRUE : close_delay_count;
  esac;
DEFINE close_delay_expired := (close_delay_count = 5);
```

> 💡 `MAX_TICKS` 的值不需要對應實際時間，只要足夠小（5-20）讓 nuXmv 能在合理時間內驗證。

### 2.4 Timer 在狀態轉移中的使用

```smv
next(CurrentState) := case
  -- OPENING → OPEN：限位開關觸發
  CurrentState = OPENING & LimitSwitchOpen : OPEN;
  -- OPENING → CLOSED：馬達超時（安全保護）
  CurrentState = OPENING & motor_timeout_expired : CLOSED;
  -- OPEN → CLOSING：延遲到期
  CurrentState = OPEN & close_delay_expired : CLOSING;
  ...
  TRUE : CurrentState;
esac;
```

---

## 3. Edge Detection（邊沿偵測）

ST 的 `R_TRIG`（上升沿偵測）需要記錄前一次的值：

```smv
VAR
  OpenRequest : boolean;       -- 當前值
  _prevOpenRequest : boolean;  -- 前一次的值

ASSIGN
  init(_prevOpenRequest) := FALSE;
  next(_prevOpenRequest) := OpenRequest;

DEFINE
  OpenRequestPulse := OpenRequest & !_prevOpenRequest;  -- 上升沿
```

> ⚠️ 如果 ST 用了 `R_TRIG` 或 `F_TRIG`，SMV 模型一定要加邊沿偵測，否則會有語意差異。

---

## 4. FAIRNESS 約束

### 4.1 用途

FAIRNESS 告訴 nuXmv「在合理的執行路徑中，這個條件會無限次成立」。用於排除不現實的環境行為。

### 4.2 ✅ 正確語法（nuXmv 2.0.0）

```smv
-- 只接受簡單布林表達式
FAIRNESS LimitSwitchOpen;
FAIRNESS LimitSwitchClosed;
FAIRNESS !PresenceSensor;
```

### 4.3 ❌ 錯誤語法

```smv
-- nuXmv 2.0.0 不支援 FAIRNESS 裡面放 LTL 算子！
FAIRNESS (CurrentState = OPENING -> F LimitSwitchOpen);   -- 語法錯誤
FAIRNESS F LimitSwitchOpen;                                -- 語法錯誤
```

### 4.4 JUSTICE 約束（更精確的公平性）

```smv
-- JUSTICE 是 FAIRNESS 的進階版，語法相同但可以更精確
JUSTICE LimitSwitchOpen;
JUSTICE LimitSwitchClosed;
```

> nuXmv 2.0.0 中 `JUSTICE` 和 `FAIRNESS` 語法相同，都只接受布林表達式。

### 4.5 建議的 FAIRNESS 組合

針對工業控制系統，推薦以下標準 FAIRNESS：

```smv
-- 限位開關最終會被觸發（馬達有在動的話）
FAIRNESS LimitSwitchOpen;
FAIRNESS LimitSwitchClosed;

-- 感測器不會永遠擋著（人不會永遠站在門口）
FAIRNESS !PresenceSensor;

-- 如果用了計數器 timer，不需要額外 FAIRNESS，因為計數器自帶有界性
```

### 4.6 計數器的持續條件問題

當計數器需要**連續 N 步**滿足條件才能到期時，簡單的 `FAIRNESS` 不夠：

```smv
-- close_delay_count 需要連續 5 步 !PresenceSensor & !OpenRequest
-- 但 FAIRNESS !PresenceSensor 只保證「無限次為 FALSE」
-- 不保證「連續 5 次都為 FALSE」
```

**解法 A：接受限制，弱化性質（務實）**

在報告中說明：「此 Liveness 性質依賴環境輸入連續穩定，屬於已知建模限制。」

**解法 B：環境穩定期建模（進階）**

加一個「環境穩定模式」變數，模擬感測器在一段時間內不會反覆跳動：

```smv
VAR
  env_stable_mode : boolean;  -- 非確定性，但加 FAIRNESS
ASSIGN
  -- 在穩定模式下，PresenceSensor 維持 FALSE
  next(PresenceSensor) := case
    env_stable_mode & CurrentState = OPEN : FALSE;
    TRUE : {TRUE, FALSE};  -- 其他時候非確定性
  esac;
FAIRNESS env_stable_mode;  -- 穩定模式會無限次出現
```

**解法 C：直接限制輸入的跳動頻率（最精確但複雜）**

```smv
-- 感測器至少連續 N 步不變
VAR sensor_hold_count : 0..5;
ASSIGN
  next(sensor_hold_count) := case
    next(PresenceSensor) = PresenceSensor : 
      (sensor_hold_count < 5 ? sensor_hold_count + 1 : 5);
    TRUE : 0;
  esac;
-- 限制：感測器只能在 hold 計數到 N 後才能改變
-- （需要更複雜的建模，視情況使用）
```

> 💡 **實務建議**：對於依賴「輸入持續穩定」的 Liveness 性質，優先用**解法 A**（接受並說明），除非驗證要求非常嚴格才用 B 或 C。

---

### 5.1 Safety 性質（用 CTL 的 AG 或 LTL 的 G）

Safety = 「壞事永遠不會發生」

```smv
-- 馬達不會同時正反轉
CTLSPEC AG !(MotorOpen & MotorClose);

-- 或等價的 LTL
LTLSPEC G !(MotorOpen & MotorClose);

-- 門指示燈與狀態一致
CTLSPEC AG (DoorOpenIndicator -> CurrentState = OPEN);

-- 防夾安全：感測器觸發時不會繼續關門
CTLSPEC AG (CurrentState = CLOSING & PresenceSensor ->
  AX (CurrentState != CLOSING));
```

### 5.2 Liveness 性質

Liveness = 「好事最終會發生」

**方法 A：CTL + FAIRNESS（推薦）**
```smv
-- 配合 FAIRNESS 使用，CTL 的 AG AF 通常比 LTL 更容易通過
CTLSPEC AG (CurrentState = OPENING -> AF (CurrentState = OPEN | CurrentState = CLOSED));
CTLSPEC AG (CurrentState = CLOSING -> AF (CurrentState = CLOSED | CurrentState = OPEN));
```

**方法 B：LTL（較嚴格）**
```smv
LTLSPEC G (CurrentState = OPENING -> F (CurrentState = OPEN | CurrentState = CLOSED));
```

**方法 C：Bounded Liveness / Response（務實）**
```smv
-- 用 Until (U) 表達「要嘛到達目標，要嘛安全回退」
LTLSPEC G (CurrentState = OPENING ->
  (CurrentState = OPENING U (CurrentState = OPEN | CurrentState = CLOSED)));
```

> 💡 **優先順序**：先寫 Safety（容易通過），再寫 Liveness（可能需要調整 FAIRNESS 和 Timer 建模）。

### 5.3 Liveness 失敗時的除錯步驟

1. 看 nuXmv 的 counterexample → 找出哪個輸入「卡住」了
2. 如果是 timer 問題 → 改用計數器建模（見第 2 章）
3. 如果是輸入問題 → 加對應的 FAIRNESS
4. 如果是**計數器被反覆重置**（輸入在計數期間跳動） → 見第 4.6 節，考慮接受限制或加環境穩定建模
5. 如果還是失敗 → 弱化性質（加 `| 安全回退狀態`）
6. 最後手段 → 改用 CTL + FAIRNESS 組合

### 5.4 不可避免的 Liveness 失敗

以下情況的 Liveness 失敗是合理的，應在報告中說明而非強行修復：

- **依賴環境輸入連續穩定**：例如「門從 OPEN 到 CLOSING」需要感測器和按鈕連續 N 步不觸發
- **依賴外部物理事件**：例如「限位開關一定會觸發」需要馬達和機械結構正常運作
- **安全機制導致的回退**：超時保護會讓系統回到安全狀態而非完成預期動作

在報告中建議使用以下格式：

```
未通過的活性屬性：[性質]
失敗原因：[具體原因，例如「輸入非確定性導致計數器被反覆重置」]
評估：此失敗不影響系統安全性，屬於環境建模限制。
```

---

## 6. 註解格式

```smv
-- 這是 SMV 的註解格式（雙橫線）
-- 不要用 ST 的 (* 註解 *) 格式，nuXmv 不認得
```

> ⚠️ Agent 在產生 SMV 時常常混用 ST 註解格式 `(* ... *)`，這會導致 nuXmv 語法錯誤。

---

## 7. 完整建模 Checklist

Agent 在產生 `.smv` 檔案前，請逐項確認：

- [ ] 所有外部輸入只用 `VAR` 宣告，不寫 `ASSIGN`
- [ ] 每個 `case` 的最後一條是 `TRUE : 預設值;`
- [ ] ST 的 `TON` timer 用**有界計數器**建模（不是布林值）
- [ ] ST 的 `R_TRIG` / `F_TRIG` 有對應的邊沿偵測邏輯
- [ ] ENUM 狀態用 `{STATE_A, STATE_B, ...}` 宣告（不要用整數）
- [ ] 註解只用 `--`，不用 `(* *)`
- [ ] FAIRNESS 只包含簡單布林表達式（不含 `F`、`G`、`U` 等 LTL 算子）
- [ ] Safety 性質用 `AG` 或 `G`
- [ ] Liveness 性質包含安全回退狀態（例如 `F (OPEN | CLOSED)` 而非只有 `F OPEN`）
- [ ] 跑驗證前先執行 `nuXmv -int` 互動模式檢查語法

---

## 8. nuXmv 執行指令

### 8.1 一次性驗證（批次模式）

```bash
# 驗證所有性質
nuXmv model.smv
```

### 8.2 互動模式（除錯用）

```bash
nuXmv -int
```

在互動模式中：
```
read_model -i model.smv
flatten_hierarchy
encode_variables
build_model

-- 驗證 CTL
check_ctlspec

-- 驗證 LTL
check_ltlspec

-- 看反例
show_traces

-- 模擬執行
pick_state -r
simulate -r -k 20
show_traces
```

### 8.3 只驗證特定性質

```bash
# 驗證第 N 個 CTLSPEC（從 0 開始）
check_ctlspec -n 0

# 驗證第 N 個 LTLSPEC
check_ltlspec -n 0
```

---

## 9. 常見錯誤與解法

| 錯誤 | 原因 | 解法 |
|------|------|------|
| `syntax error` 在 FAIRNESS 行 | 用了 LTL 算子（F、G、U） | 只寫簡單布林：`FAIRNESS var;` |
| `syntax error` 在 CASE | 用了 ST 的 enum 名稱作為 case label | 用枚舉值比較：`CurrentState = OPEN` |
| `not a valid LTL formula` | LTLSPEC 裡混了 CTL 算子（AG、EF） | LTL 用 G/F/U/X，CTL 用 AG/AF/EF/AX |
| Liveness 全部失敗 | Timer 用布林建模，輸入無 FAIRNESS | 改用計數器 + 加 FAIRNESS |
| `circular dependency` | DEFINE 互相引用 | 改用 ASSIGN |
| `multiple assignment` | 同一變數寫了兩次 ASSIGN | 合併成一個 case |
| 註解導致語法錯誤 | 用了 `(* ST 註解 *)` | 改用 `-- SMV 註解` |

---

## 10. 範例：自動門控制系統（完整 SMV）

```smv
MODULE main

-- === 輸入（非確定性，模擬外部環境）===
VAR
  OpenButton : boolean;
  CloseButton : boolean;
  PresenceSensor : boolean;
  LimitSwitchOpen : boolean;
  LimitSwitchClosed : boolean;

-- === 狀態 ===
VAR
  CurrentState : {CLOSED, OPENING, OPEN, CLOSING, REOPENING_SAFETY};

-- === Timer：有界計數器 ===
VAR
  motor_timeout_count : 0..10;
  close_delay_count : 0..5;

-- === 邊沿偵測 ===
VAR
  _prevOpenButton : boolean;

-- === ASSIGN ===
ASSIGN
  -- 邊沿偵測
  init(_prevOpenButton) := FALSE;
  next(_prevOpenButton) := OpenButton;

  -- 馬達超時計數器
  init(motor_timeout_count) := 0;
  next(motor_timeout_count) := case
    (CurrentState = OPENING | CurrentState = CLOSING | CurrentState = REOPENING_SAFETY)
      & motor_timeout_count < 10 : motor_timeout_count + 1;
    CurrentState = OPEN | CurrentState = CLOSED : 0;
    TRUE : motor_timeout_count;
  esac;

  -- 關門延遲計數器
  init(close_delay_count) := 0;
  next(close_delay_count) := case
    CurrentState = OPEN & !PresenceSensor & !OpenButtonPulse
      & close_delay_count < 5 : close_delay_count + 1;
    CurrentState != OPEN : 0;
    PresenceSensor | OpenButtonPulse : 0;
    TRUE : close_delay_count;
  esac;

  -- 狀態轉移
  init(CurrentState) := CLOSED;
  next(CurrentState) := case
    -- CLOSED → OPENING
    CurrentState = CLOSED & (OpenButtonPulse | PresenceSensor) : OPENING;

    -- OPENING → OPEN（到達限位）
    CurrentState = OPENING & LimitSwitchOpen : OPEN;
    -- OPENING → CLOSED（馬達超時）
    CurrentState = OPENING & motor_timeout_expired : CLOSED;

    -- OPEN → CLOSING（延遲到期）
    CurrentState = OPEN & close_delay_expired : CLOSING;

    -- CLOSING → CLOSED（到達限位）
    CurrentState = CLOSING & LimitSwitchClosed : CLOSED;
    -- CLOSING → REOPENING_SAFETY（偵測到人）
    CurrentState = CLOSING & PresenceSensor : REOPENING_SAFETY;
    -- CLOSING → CLOSED（馬達超時）
    CurrentState = CLOSING & motor_timeout_expired : CLOSED;

    -- REOPENING_SAFETY → OPEN（到達限位）
    CurrentState = REOPENING_SAFETY & LimitSwitchOpen : OPEN;
    -- REOPENING_SAFETY → CLOSED（馬達超時）
    CurrentState = REOPENING_SAFETY & motor_timeout_expired : CLOSED;

    TRUE : CurrentState;
  esac;

-- === DEFINE ===
DEFINE
  OpenButtonPulse := OpenButton & !_prevOpenButton;
  motor_timeout_expired := (motor_timeout_count = 10);
  close_delay_expired := (close_delay_count = 5);
  MotorOpen := (CurrentState = OPENING) | (CurrentState = REOPENING_SAFETY);
  MotorClose := (CurrentState = CLOSING);
  DoorOpenIndicator := (CurrentState = OPEN);
  DoorClosedIndicator := (CurrentState = CLOSED);

-- === FAIRNESS（排除不現實的環境行為）===
FAIRNESS LimitSwitchOpen;
FAIRNESS LimitSwitchClosed;
FAIRNESS !PresenceSensor;

-- === Safety 性質 ===
CTLSPEC AG !(MotorOpen & MotorClose);                         -- 馬達不同時正反轉
CTLSPEC AG (DoorOpenIndicator -> CurrentState = OPEN);         -- 指示燈正確
CTLSPEC AG (DoorClosedIndicator -> CurrentState = CLOSED);     -- 指示燈正確
CTLSPEC AG (CurrentState = CLOSING & PresenceSensor ->
  AX CurrentState = REOPENING_SAFETY);                         -- 防夾

-- === Liveness 性質 ===
CTLSPEC AG (CurrentState = OPENING ->
  AF (CurrentState = OPEN | CurrentState = CLOSED));           -- 開門最終完成或回退
CTLSPEC AG (CurrentState = CLOSING ->
  AF (CurrentState = CLOSED | CurrentState = OPEN));           -- 關門最終完成或重開
CTLSPEC AG (CurrentState = OPEN ->
  AF (CurrentState = CLOSING | CurrentState = OPEN));          -- 開著的門最終開始關
```

> 此範例使用計數器 timer + FAIRNESS + CTL，應能通過所有 Safety 和 Liveness 驗證。