; VICE xscpu64 monitor command file for Asterix PC trace.
;
; Usage:
;   xscpu64 -autostart asterix.prg
;           -moncommands vice_trace_asterix.cmd
;           -monchislines 500000
;           -logfile vice_trace.log
;           -silent
;
; The CPU history ring (chis) records the last N executed instructions
; per the -monchislines flag. Setting a break at $CB00 (Asterix game
; entry) lets us dump the history of the entire decompressor run.
;
; Note: VICE comments use ';' (semicolon), not '#'.

; Break when the CPU reaches Asterix game entry at $CB00.
break $CB00

; Resume execution from BASIC autostart. xscpu64 starts paused at the
; reset vector with autostart pending; `g` lets the autoloader run RUN
; and the program executes until the breakpoint at $CB00.
g

; Once the break hits, dump the last 500K instructions to the log.
chis 500000

; End of trace marker so the parser knows the dump finished cleanly.
print "TRACE_END"

quit
