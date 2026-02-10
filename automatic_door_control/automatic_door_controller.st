PROGRAM AutomaticDoorControl
VAR
    (* Inputs *)
    PresenceSensor : BOOL; (* TRUE when presence detected *)
    SafetySensor : BOOL; (* TRUE when obstacle detected during closing *)
    OpenRequest : BOOL; (* TRUE when open button/mat is activated *)
    LimitSwitchOpen : BOOL; (* TRUE when door is fully open *)
    LimitSwitchClosed : BOOL; (* TRUE when door is fully closed *)

    (* Outputs *)
    MotorOpen : BOOL; (* TRUE to activate motor for opening *)
    MotorClose : BOOL; (* TRUE to activate motor for closing *)
    DoorOpenIndicator : BOOL; (* TRUE when door is fully open *)
    DoorClosedIndicator : BOOL; (* TRUE when door is fully closed *)

    (* Internal Variables *)
    CurrentState : INT; (* 0: CLOSED, 1: OPENING, 2: OPEN, 3: CLOSING, 4: REOPENING_SAFETY *)
    TON_DelayBeforeClose : TON; (* Timer for delay before closing *)
    TON_MotorRunTimeout : TON; (* Timer for motor run timeout *)
    _oldPresenceSensor : BOOL; (* For rising edge detection of PresenceSensor *)
    _risingEdgePresenceSensor : BOOL; (* Rising edge of PresenceSensor *)
    _openRequestPulse : BOOL; (* Pulse for OpenRequest *)

    (* Timer preset values *)
    MotorRunTimeLimit_PT : TIME := T#10S; (* 10 seconds timeout for motor run *)
    DelayBeforeClose_PT : TIME := T#5S; (* 5 seconds delay before closing *)
END_VAR

(* State Definitions *)
VAR CONSTANT
    STATE_CLOSED : INT := 0;
    STATE_OPENING : INT := 1;
    STATE_OPEN : INT := 2;
    STATE_CLOSING : INT := 3;
    STATE_REOPENING_SAFETY : INT := 4;
END_VAR

(* Edge detection for PresenceSensor *)
_risingEdgePresenceSensor := PresenceSensor AND NOT _oldPresenceSensor;
_oldPresenceSensor := PresenceSensor;

(* OpenRequest pulse - assuming it's a momentary button. If it's a maintained signal, this logic needs adjustment. *)
_openRequestPulse := OpenRequest;

(* TON Timer Instances *)
TON_DelayBeforeClose(IN := NOT PresenceSensor AND NOT _openRequestPulse AND (CurrentState = STATE_OPEN), PT := DelayBeforeClose_PT);
TON_MotorRunTimeout(IN := (CurrentState = STATE_OPENING OR CurrentState = STATE_CLOSING OR CurrentState = STATE_REOPENING_SAFETY), PT := MotorRunTimeLimit_PT);

(* Reset indicators and motor outputs initially *)
MotorOpen := FALSE;
MotorClose := FALSE;
DoorOpenIndicator := FALSE;
DoorClosedIndicator := FALSE;

(* Main State Machine *)
CASE CurrentState OF
    0: (* STATE_CLOSED *)
        DoorClosedIndicator := TRUE;

        IF (_risingEdgePresenceSensor OR PresenceSensor OR _openRequestPulse) THEN
            CurrentState := STATE_OPENING;
            TON_MotorRunTimeout(IN := TRUE, PT := MotorRunTimeLimit_PT); (* Activate timeout for opening *)
        END_IF;

    1: (* STATE_OPENING *)
        MotorOpen := TRUE;

        IF LimitSwitchOpen THEN
            CurrentState := STATE_OPEN;
            TON_MotorRunTimeout(IN := FALSE); (* Reset timeout *)
        ELSIF TON_MotorRunTimeout.Q THEN (* Motor timeout during opening *)
            (* Handle error, e.g., log, alarm. For simplicity, return to closed state *)
            CurrentState := STATE_CLOSED; (* Or STATE_ERROR if implemented *)
            TON_MotorRunTimeout(IN := FALSE); (* Reset timeout *)
        END_IF;

    2: (* STATE_OPEN *)
        DoorOpenIndicator := TRUE;

        TON_DelayBeforeClose(IN := NOT PresenceSensor AND NOT _openRequestPulse, PT := DelayBeforeClose_PT); (* Start delay timer if no presence/open request *)

        IF (NOT PresenceSensor AND NOT _openRequestPulse AND TON_DelayBeforeClose.Q) THEN
            CurrentState := STATE_CLOSING;
            TON_DelayBeforeClose(IN := FALSE); (* Reset delay timer *)
            TON_MotorRunTimeout(IN := TRUE, PT := MotorRunTimeLimit_PT); (* Activate timeout for closing *)
        ELSIF (PresenceSensor OR _openRequestPulse) THEN
            TON_DelayBeforeClose(IN := FALSE); (* Reset delay timer if presence/open request detected *)
        END_IF;

    3: (* STATE_CLOSING *)
        MotorClose := TRUE;

        IF LimitSwitchClosed THEN
            CurrentState := STATE_CLOSED;
            TON_MotorRunTimeout(IN := FALSE); (* Reset timeout *)
        ELSIF SafetySensor THEN
            CurrentState := STATE_REOPENING_SAFETY;
            TON_MotorRunTimeout(IN := FALSE); (* Reset timeout *)
        ELSIF TON_MotorRunTimeout.Q THEN (* Motor timeout during closing *)
            (* Handle error, e.g., log, alarm. For simplicity, return to open state *)
            CurrentState := STATE_OPEN; (* Or STATE_ERROR if implemented *)
            TON_MotorRunTimeout(IN := FALSE); (* Reset timeout *)
        END_IF;

    4: (* STATE_REOPENING_SAFETY *)
        MotorOpen := TRUE;

        IF LimitSwitchOpen THEN
            CurrentState := STATE_OPEN;
            TON_MotorRunTimeout(IN := FALSE); (* Reset timeout *)
        ELSIF TON_MotorRunTimeout.Q THEN (* Motor timeout during reopening *)
            (* Handle error, e.g., log, alarm. For simplicity, return to closing state *)
            CurrentState := STATE_CLOSING; (* Or STATE_ERROR if implemented *)
            TON_MotorRunTimeout(IN := FALSE); (* Reset timeout *)
        END_IF;
END_CASE;

END_PROGRAM