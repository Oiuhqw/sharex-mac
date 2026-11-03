---------------------------- MODULE Capture ----------------------------
(* Model of App/Sources/CaptureCoordinator.swift + OverlayController.close + report().
   Every MainActor turn between awaits is one atomic action. Variables:
     busy      CaptureCoordinator.busy
     overlays  live OverlayController sessions (windows on screen)
     outer     outer capture Task program counter
     inner     pickedWindow follow-up Task program counter
     phase     what the overlay shows
     focus     frontmost app: "other" (the user's app) or "sharex"
     prev      OverlayController.previousApp captured in show()
     delivered count of clipboard writes; lastDeliverOK: was the last one legal *)
EXTENDS Naturals
CONSTANTS OpenEditor, FixAlertFocus, MaxCaptures

VARIABLES busy, overlays, outer, inner, phase, focus, prev, delivered, legal, captures
vars == <<busy, overlays, outer, inner, phase, focus, prev, delivered, legal, captures>>

Styles == {"region", "fixed", "window", "pickWindow"}

Init == busy = FALSE /\ overlays = 0 /\ outer = "none" /\ inner = "none" /\ phase = "none"
        /\ focus = "other" /\ prev = "none" /\ delivered = 0 /\ legal = TRUE /\ captures = 0

\* deliver(): clipboard write. Legal from the editor, or straight away when the editor is off.
Deliver(fromEditor) == delivered' = delivered + 1 /\ legal' = (legal /\ (fromEditor \/ ~OpenEditor))

\* report(error): a modal alert activates ShareX. With FixAlertFocus the previous app is reactivated after it.
Alert == focus' = IF FixAlertFocus THEN focus ELSE "sharex"

\* present(c): c.show() remembers the front app and activates ShareX.
Present(ph) == overlays' = overlays + 1 /\ phase' = ph
               /\ prev' = (IF focus = "sharex" THEN "none" ELSE focus) /\ focus' = "sharex"

\* close(outcome): windows go, previous app reactivated (else NSApp.hide -> some other app is front).
CloseOverlay == overlays' = overlays - 1 /\ phase' = "none" /\ focus' = "other" /\ prev' = "none"

\* capture(style): guard !busy; busy = true; Task { run }
Capture(s) == /\ captures < MaxCaptures /\ captures' = captures + 1
              /\ IF busy THEN UNCHANGED <<busy, outer>>
                 ELSE busy' = TRUE /\ outer' = s
              /\ UNCHANGED <<overlays, inner, phase, focus, prev, delivered, legal>>

\* Outer task, one turn: permission/countdown/freeze can each end it (Esc, denied, SCK error).
OuterAbort == /\ outer \in Styles
              /\ \/ Alert                           \* denied / capture failed -> alert
                 \/ UNCHANGED focus                 \* Esc during countdown, no window -> beep
              /\ outer' = "none" /\ busy' = (overlays > 0 \/ inner # "none")   \* defer { if overlay == nil { busy = false } }
              /\ UNCHANGED <<overlays, inner, phase, prev, delivered, legal, captures>>

OuterRun == /\ outer \in Styles /\ outer' = "none"
            /\ CASE outer = "fixed" /\ ~OpenEditor ->
                      Deliver(FALSE) /\ busy' = FALSE /\ UNCHANGED <<overlays, phase, focus, prev>>
                 [] outer = "window" /\ ~OpenEditor ->     \* activeWindow, editor off
                      Deliver(FALSE) /\ busy' = FALSE /\ UNCHANGED <<overlays, phase, focus, prev>>
                 [] outer = "window" ->                     \* activeWindow -> canvas editor
                      Present("editing") /\ busy' = TRUE /\ UNCHANGED <<delivered, legal>>
                 [] outer = "pickWindow" ->
                      Present("picking") /\ busy' = TRUE /\ UNCHANGED <<delivered, legal>>
                 [] outer = "fixed" ->
                      Present("editing") /\ busy' = TRUE /\ UNCHANGED <<delivered, legal>>
                 [] OTHER ->                                \* region / freehand / monitor picker
                      Present("selecting") /\ busy' = TRUE /\ UNCHANGED <<delivered, legal>>
            /\ UNCHANGED <<inner, captures>>

\* User in the overlay.
Select   == phase = "selecting" /\ phase' = "editing"
            /\ UNCHANGED <<busy, overlays, outer, inner, focus, prev, delivered, legal, captures>>
Cancel   == overlays > 0 /\ phase \in {"selecting", "editing", "picking"} /\ CloseOverlay /\ busy' = FALSE
            /\ UNCHANGED <<outer, inner, delivered, legal, captures>>
Finish   == phase = "editing" /\ CloseOverlay /\ busy' = FALSE /\ Deliver(TRUE)
            /\ UNCHANGED <<outer, inner, captures>>
\* .pickedWindow: overlay = nil (stay busy), Task { editOrDeliver }
PickWin  == phase = "picking" /\ CloseOverlay /\ inner' = "capturing"
            /\ UNCHANGED <<busy, outer, delivered, legal, captures>>

\* Inner task after the live window capture returns (or throws windowGone).
InnerDone == /\ inner = "capturing" /\ inner' = "none"
             /\ \/ /\ Alert /\ busy' = (overlays > 0) /\ UNCHANGED <<overlays, phase, prev, delivered, legal>>
                \/ /\ OpenEditor /\ Present("editing") /\ busy' = TRUE /\ UNCHANGED <<delivered, legal>>
                \/ /\ ~OpenEditor /\ Deliver(FALSE) /\ busy' = FALSE /\ UNCHANGED <<overlays, phase, focus, prev>>
             /\ UNCHANGED <<outer, captures>>

\* The user clicking back into their app always works; it is what hides the alert-focus bug in daily use.
Next == \/ \E s \in Styles : Capture(s)
        \/ OuterAbort \/ OuterRun \/ Select \/ Cancel \/ Finish \/ PickWin \/ InnerDone
        \/ (captures >= MaxCaptures /\ UNCHANGED vars)

Spec == Init /\ [][Next]_vars /\ WF_vars(OuterRun \/ OuterAbort) /\ WF_vars(InnerDone)
        /\ SF_vars(Finish \/ Cancel) /\ SF_vars(Select \/ PickWin)

\* ---- properties ----
TypeOK == busy \in BOOLEAN /\ overlays \in 0..2 /\ focus \in {"other", "sharex"}
AtMostOneOverlay == overlays <= 1
IdleIsClean == ~busy => (overlays = 0 /\ outer = "none" /\ inner = "none")
ExportOnlyFromEditing == legal
\* When nothing is in progress the user's app is in front (Active Window needs it; keys go to the user's app).
FocusRestoredWhenIdle == (~busy /\ captures > 0) => focus = "other"
NeverStuckBusy == busy ~> ~busy
CancelReturnsIdle == [][Cancel => ~busy']_vars
=============================================================================
