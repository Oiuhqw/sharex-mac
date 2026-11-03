---- MODULE Capture_TTrace_1793679148 ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, Capture

_expression ==
    LET Capture_TEExpression == INSTANCE Capture_TEExpression
    IN Capture_TEExpression!expression
----

_trace ==
    LET Capture_TETrace == INSTANCE Capture_TETrace
    IN Capture_TETrace!trace
----

_inv ==
    ~(
        TLCGet("level") = Len(_TETrace)
        /\
        phase = ("none")
        /\
        captures = ()
        /\
        busy = (FALSE)
        /\
        overlays = (0)
        /\
        prev = ("none")
        /\
        legal = (TRUE)
        /\
        outer = ("none")
        /\
        focus = ("sharex")
        /\
        delivered = (0)
        /\
        inner = ("none")
    )
----

_init ==
    /\ focus = _TETrace[1].focus
    /\ legal = _TETrace[1].legal
    /\ inner = _TETrace[1].inner
    /\ busy = _TETrace[1].busy
    /\ overlays = _TETrace[1].overlays
    /\ outer = _TETrace[1].outer
    /\ phase = _TETrace[1].phase
    /\ prev = _TETrace[1].prev
    /\ delivered = _TETrace[1].delivered
    /\ captures = _TETrace[1].captures
----

_next ==
    /\ \E i,j \in DOMAIN _TETrace:
        /\ \/ /\ j = i + 1
              /\ i = TLCGet("level")
        /\ focus  = _TETrace[i].focus
        /\ focus' = _TETrace[j].focus
        /\ legal  = _TETrace[i].legal
        /\ legal' = _TETrace[j].legal
        /\ inner  = _TETrace[i].inner
        /\ inner' = _TETrace[j].inner
        /\ busy  = _TETrace[i].busy
        /\ busy' = _TETrace[j].busy
        /\ overlays  = _TETrace[i].overlays
        /\ overlays' = _TETrace[j].overlays
        /\ outer  = _TETrace[i].outer
        /\ outer' = _TETrace[j].outer
        /\ phase  = _TETrace[i].phase
        /\ phase' = _TETrace[j].phase
        /\ prev  = _TETrace[i].prev
        /\ prev' = _TETrace[j].prev
        /\ delivered  = _TETrace[i].delivered
        /\ delivered' = _TETrace[j].delivered
        /\ captures  = _TETrace[i].captures
        /\ captures' = _TETrace[j].captures

\* Uncomment the ASSUME below to write the states of the error trace
\* to the given file in Json format. Note that you can pass any tuple
\* to `JsonSerialize`. For example, a sub-sequence of _TETrace.
    \* ASSUME
    \*     LET J == INSTANCE Json
    \*         IN J!JsonSerialize("Capture_TTrace_1793679148.json", _TETrace)

=============================================================================

 Note that you can extract this module `Capture_TEExpression`
  to a dedicated file to reuse `expression` (the module in the 
  dedicated `Capture_TEExpression.tla` file takes precedence 
  over the module `Capture_TEExpression` below).

---- MODULE Capture_TEExpression ----
EXTENDS Sequences, TLCExt, Toolbox, Naturals, TLC, Capture

expression == 
    [
        \* To hide variables of the `Capture` spec from the error trace,
        \* remove the variables below.  The trace will be written in the order
        \* of the fields of this record.
        focus |-> focus
        ,legal |-> legal
        ,inner |-> inner
        ,busy |-> busy
        ,overlays |-> overlays
        ,outer |-> outer
        ,phase |-> phase
        ,prev |-> prev
        ,delivered |-> delivered
        ,captures |-> captures
        
        \* Put additional constant-, state-, and action-level expressions here:
        \* ,_stateNumber |-> _TEPosition
        \* ,_focusUnchanged |-> focus = focus'
        
        \* Format the `focus` variable as Json value.
        \* ,_focusJson |->
        \*     LET J == INSTANCE Json
        \*     IN J!ToJson(focus)
        
        \* Lastly, you may build expressions over arbitrary sets of states by
        \* leveraging the _TETrace operator.  For example, this is how to
        \* count the number of times a spec variable changed up to the current
        \* state in the trace.
        \* ,_focusModCount |->
        \*     LET F[s \in DOMAIN _TETrace] ==
        \*         IF s = 1 THEN 0
        \*         ELSE IF _TETrace[s].focus # _TETrace[s-1].focus
        \*             THEN 1 + F[s-1] ELSE F[s-1]
        \*     IN F[_TEPosition - 1]
    ]

=============================================================================



Parsing and semantic processing can take forever if the trace below is long.
 In this case, it is advised to uncomment the module below to deserialize the
 trace from a generated binary file.

\*
\*---- MODULE Capture_TETrace ----
\*EXTENDS IOUtils, TLC, Capture
\*
\*trace == IODeserialize("Capture_TTrace_1793679148.bin", TRUE)
\*
\*=============================================================================
\*

---- MODULE Capture_TETrace ----
EXTENDS TLC, Capture

trace == 
    <<
    ([phase |-> "none",captures |-> 0,busy |-> FALSE,overlays |-> 0,prev |-> "none",legal |-> TRUE,outer |-> "none",focus |-> "other",delivered |-> 0,inner |-> "none"]),
    ([phase |-> "none",captures |-> 1,busy |-> TRUE,overlays |-> 0,prev |-> "none",legal |-> TRUE,outer |-> "window",focus |-> "other",delivered |-> 0,inner |-> "none"]),
    ([phase |-> "none",captures |-> ,busy |-> FALSE,overlays |-> 0,prev |-> "none",legal |-> TRUE,outer |-> "none",focus |-> "sharex",delivered |-> 0,inner |-> "none"])
    >>
----


=============================================================================

---- CONFIG Capture_TTrace_1793679148 ----
CONSTANTS
    OpenEditor = FALSE
    FixAlertFocus = FALSE
    MaxCaptures = 4

INVARIANT
    _inv

CHECK_DEADLOCK
    \* CHECK_DEADLOCK off because of PROPERTY or INVARIANT above.
    FALSE

INIT
    _init

NEXT
    _next

CONSTANT
    _TETrace <- _trace

ALIAS
    _expression
=============================================================================
\* Generated on Tue Nov 03 12:12:29 SGT 2026