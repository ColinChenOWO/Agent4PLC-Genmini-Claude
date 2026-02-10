### Demand Summary

The automatic door system should open when a presence sensor detects an object or an open request is made. It should remain open for a set delay after the presence sensor clears, then close automatically. A safety sensor must detect obstacles during closing, triggering an immediate re-opening of the door. Limit switches indicate fully open and closed states. Outputs include motor control for opening and closing, and indicators for the door's state. Timing considerations include a delay before closing and a motor run time limit.

### System Architecture

The system will be implemented as a single Programmable Organization Unit (POU) in Structured Text (ST). It will use a state machine approach to manage the door's various states: `CLOSED`, `OPENING`, `OPEN`, `CLOSING`, and `REOPENING_SAFETY`. Timers will be used for delays and motor run time limits. Edge detection will be used for sensor inputs if required.

### Variable Definitions

**Inputs:**
*   `PresenceSensor`: BOOL (TRUE when presence detected)
*   `SafetySensor`: BOOL (TRUE when obstacle detected during closing)
*   `OpenRequest`: BOOL (TRUE when open button/mat is activated)
*   `LimitSwitchOpen`: BOOL (TRUE when door is fully open)
*   `LimitSwitchClosed`: BOOL (TRUE when door is fully closed)

**Outputs:**
*   `MotorOpen`: BOOL (TRUE to activate motor for opening)
*   `MotorClose`: BOOL (TRUE to activate motor for closing)
*   `DoorOpenIndicator`: BOOL (TRUE when door is fully open)
*   `DoorClosedIndicator`: BOOL (TRUE when door is fully closed)

**Internal Variables:**
*   `CurrentState`: INT (Enum for states: 0: CLOSED, 1: OPENING, 2: OPEN, 3: CLOSING, 4: REOPENING_SAFETY)
*   `TON_DelayBeforeClose`: TON (Timer for delay before closing)
*   `TON_MotorRunTimeout`: TON (Timer for motor run timeout)
*   `_oldPresenceSensor`: BOOL (For rising edge detection of PresenceSensor)
*   `_risingEdgePresenceSensor`: BOOL (Rising edge of PresenceSensor)
*   `_openRequestPulse`: BOOL (Pulse for OpenRequest)

### Detailed Control Logic

The core logic will be a `CASE` statement based on `CurrentState`.

**State Definitions:**

*   **CLOSED (0):**
    *   `MotorOpen` = FALSE, `MotorClose` = FALSE
    *   `DoorOpenIndicator` = FALSE, `DoorClosedIndicator` = TRUE
    *   **Transition to OPENING (1):** If `PresenceSensor` (rising edge or active) or `OpenRequest` is TRUE, set `CurrentState` to OPENING. Start `TON_MotorRunTimeout`.

*   **OPENING (1):**
    *   `MotorOpen` = TRUE, `MotorClose` = FALSE
    *   `DoorOpenIndicator` = FALSE, `DoorClosedIndicator` = FALSE
    *   **Transition to OPEN (2):** If `LimitSwitchOpen` is TRUE, set `CurrentState` to OPEN. Reset `TON_MotorRunTimeout`. Stop `MotorOpen`.
    *   **Transition to CLOSED (0) - Error/Timeout:** If `TON_MotorRunTimeout.Q` is TRUE (motor timeout), set `CurrentState` to CLOSED and signal an error (not explicitly handled in outputs for simplicity, but good practice).

*   **OPEN (2):**
    *   `MotorOpen` = FALSE, `MotorClose` = FALSE
    *   `DoorOpenIndicator` = TRUE, `DoorClosedIndicator` = FALSE
    *   Start `TON_DelayBeforeClose` if `PresenceSensor` is FALSE and `OpenRequest` is FALSE.
    *   **Transition to CLOSING (3):** If `PresenceSensor` is FALSE and `OpenRequest` is FALSE and `TON_DelayBeforeClose.Q` is TRUE, set `CurrentState` to CLOSING. Start `TON_MotorRunTimeout`.
    *   **Stay in OPEN (2):** If `PresenceSensor` or `OpenRequest` is TRUE, reset `TON_DelayBeforeClose`.

*   **CLOSING (3):**
    *   `MotorOpen` = FALSE, `MotorClose` = TRUE
    *   `DoorOpenIndicator` = FALSE, `DoorClosedIndicator` = FALSE
    *   **Transition to CLOSED (0):** If `LimitSwitchClosed` is TRUE, set `CurrentState` to CLOSED. Reset `TON_MotorRunTimeout`. Stop `MotorClose`.
    *   **Transition to REOPENING_SAFETY (4):** If `SafetySensor` is TRUE, set `CurrentState` to REOPENING_SAFETY. Reset `TON_MotorRunTimeout`. Stop `MotorClose`.
    *   **Transition to OPEN (2) - Error/Timeout:** If `TON_MotorRunTimeout.Q` is TRUE (motor timeout), set `CurrentState` to OPEN (assuming it stopped before fully closing) and signal an error. Stop `MotorClose`.

*   **REOPENING_SAFETY (4):**
    *   `MotorOpen` = TRUE, `MotorClose` = FALSE
    *   `DoorOpenIndicator` = FALSE, `DoorClosedIndicator` = FALSE
    *   Start `TON_MotorRunTimeout`.
    *   **Transition to OPEN (2):** If `LimitSwitchOpen` is TRUE, set `CurrentState` to OPEN. Reset `TON_MotorRunTimeout`. Stop `MotorOpen`.
    *   **Transition to CLOSING (3) - Error/Timeout:** If `TON_MotorRunTimeout.Q` is TRUE (motor timeout during reopen), set `CurrentState` to CLOSING and signal an error. Stop `MotorOpen`.

### Formal Verification Properties (LTL - for NuXmv)

**Safety Properties:**

1.  **Mutual Exclusion of Motors:** `G (!(MotorOpen AND MotorClose))` (Motors should never be active simultaneously)
2.  **Door Closed Indicator Implies Door Closed:** `G (DoorClosedIndicator -> LimitSwitchClosed)` (If door closed indicator is on, door must be fully closed)
3.  **Door Open Indicator Implies Door Open:** `G (DoorOpenIndicator -> LimitSwitchOpen)` (If door open indicator is on, door must be fully open)
4.  **No Closing with Obstacle:** `G ((CurrentState = CLOSING AND SafetySensor) -> X (CurrentState = REOPENING_SAFETY))` (If closing and safety sensor active, next state must be reopening)
5.  **Motor Active Implies Not at Limit:** `G ((MotorOpen -> !LimitSwitchOpen) AND (MotorClose -> !LimitSwitchClosed))` (Motor should not be active if at its limit position)

**Liveness Properties:**

1.  **Eventually Open from Opening:** `G (CurrentState = OPENING -> F (CurrentState = OPEN))` (If the door is opening, it will eventually reach the open state)
2.  **Eventually Closed from Closing:** `G (CurrentState = CLOSING -> F (CurrentState = CLOSED))` (If the door is closing, it will eventually reach the closed state)
3.  **Eventually Open from Reopening:** `G (CurrentState = REOPENING_SAFETY -> F (CurrentState = OPEN))` (If the door is reopening due to safety, it will eventually reach the open state)
4.  **Open on Request (Weak Liveness):** `G (OpenRequest -> F (CurrentState = OPEN))` (If an open request is made, the door will eventually open, assuming no persistent blocking conditions)
5.  **Eventually Close from Open (Weak Liveness):** `G ((CurrentState = OPEN AND !PresenceSensor AND !OpenRequest) -> F (CurrentState = CLOSED))` (If the door is open and no presence or open request, it will eventually close, after the delay)
