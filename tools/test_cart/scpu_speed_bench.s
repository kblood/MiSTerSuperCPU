; ==========================================================================
; scpu_speed_bench.s — SuperCPU Speed Benchmark for MiSTer
; ==========================================================================
; Assembler: ca65 --cpu 65816
; Linker:    ld65 -C c64-816.cfg
;
; Counts iterations of a tight loop between two raster positions.
; Runs the benchmark at 1MHz and then at turbo speed, displays both counts.
; Also tests $D072/$D073 system 1MHz.
;
; Benchmark method:
;   1. Wait for raster line START_RASTER
;   2. Count iterations of a tight loop until raster line END_RASTER
;   3. Display the iteration count
;
; The loop body is calibrated so that each iteration takes a known
; number of cycles on a stock 6502, making speed calculation possible.
; ==========================================================================

.p816
.smart

; ---- Load address segment (PRG header) ----
.segment "LOADADDR"
        .word   $0801           ; C64 PRG load address

; ---- Constants ----
SCREEN          = $0400
COLRAM          = $D800
ROW             = 40
VIC_BGCOL       = $D021
VIC_BRDCOL      = $D020
VIC_RASTER      = $D012         ; Current raster line (low 8 bits)
VIC_CTRL1       = $D011         ; Bit 7 = raster bit 8

; SuperCPU registers
SCPU_07A        = $D07A         ; Software 1MHz enable
SCPU_07B        = $D07B         ; Software turbo enable
SCPU_072        = $D072         ; System 1MHz enable
SCPU_073        = $D073         ; System 1MHz disable
SCPU_07E        = $D07E         ; Register enable
SCPU_0B8        = $D0B8         ; Speed status

; Benchmark parameters
; Use raster lines in the visible area to avoid VBlank complications
START_RASTER    = 60            ; Start counting here
END_RASTER      = 200           ; Stop counting here
; That's 140 raster lines = 140 * 63 = 8820 cycles at 1MHz (NTSC)
; At 4x turbo = ~35280 effective cycles

; Zero page
ZP_COUNT_LO     = $02
ZP_COUNT_MI     = $03
ZP_COUNT_HI     = $04
ZP_TMP          = $05
ZP_LAST_RASTER  = $06
ZP_BENCH_PHASE  = $07           ; 0=1MHz, 1=turbo, 2=sys1MHz, 3=sys-turbo
ZP_RESULTS      = $10           ; 4 x 3 bytes = 12 bytes for 4 results
; $10-$12 = 1MHz count
; $13-$15 = turbo count
; $16-$18 = sys1MHz count
; $19-$1B = sys-turbo count
ZP_PTR_LO       = $20
ZP_PTR_HI       = $21
ZP_DIGIT_BUF    = $22           ; 5 bytes for decimal digits ($22-$26)


; ======================================================================
; BASIC SYS stub
; ======================================================================
.segment "EXEHDR"
        .word   @end
        .word   10
        .byte   $9E
        .byte   "2061"
        .byte   0
@end:   .word   0


; ======================================================================
; CODE
; ======================================================================
.segment "CODE"

start:
        sei
        cld

        ; Enable SuperCPU registers
        sta     SCPU_07E

        ; Set screen colors
        lda     #0
        sta     VIC_BGCOL
        lda     #6
        sta     VIC_BRDCOL

        ; Clear screen
        ldx     #0
@clr:   lda     #32             ; space
        sta     SCREEN, x
        sta     SCREEN + $100, x
        sta     SCREEN + $200, x
        sta     SCREEN + $300, x
        lda     #1              ; white
        sta     COLRAM, x
        sta     COLRAM + $100, x
        sta     COLRAM + $200, x
        sta     COLRAM + $300, x
        inx
        bne     @clr

        ; Title
        ldx     #0
@title: lda     title_str, x
        beq     @tdone
        sta     SCREEN + 6, x
        lda     #7              ; yellow
        sta     COLRAM + 6, x
        inx
        bne     @title
@tdone:

        ; Subtitle
        ldx     #0
@sub:   lda     subtitle_str, x
        beq     @sdone
        sta     SCREEN + ROW + 2, x
        lda     #14             ; light blue
        sta     COLRAM + ROW + 2, x
        inx
        bne     @sub
@sdone:

        ; ---- Run 4 benchmark phases ----

        ; Phase 0: 1MHz mode
        lda     #0
        sta     ZP_BENCH_PHASE
        sta     SCPU_07A        ; Force 1MHz
        sta     SCPU_072        ; Sys 1MHz ON (belt and suspenders)
        jsr     run_benchmark
        ; Store result
        lda     ZP_COUNT_LO
        sta     ZP_RESULTS + 0
        lda     ZP_COUNT_MI
        sta     ZP_RESULTS + 1
        lda     ZP_COUNT_HI
        sta     ZP_RESULTS + 2

        ; Phase 1: Turbo mode
        lda     #1
        sta     ZP_BENCH_PHASE
        sta     SCPU_07B        ; Turbo enable
        sta     SCPU_073        ; Sys 1MHz OFF
        jsr     run_benchmark
        lda     ZP_COUNT_LO
        sta     ZP_RESULTS + 3
        lda     ZP_COUNT_MI
        sta     ZP_RESULTS + 4
        lda     ZP_COUNT_HI
        sta     ZP_RESULTS + 5

        ; Phase 2: System 1MHz (sw turbo + sys 1MHz)
        lda     #2
        sta     ZP_BENCH_PHASE
        sta     SCPU_07B        ; SW turbo on
        sta     SCPU_072        ; Sys 1MHz ON (overrides turbo)
        jsr     run_benchmark
        lda     ZP_COUNT_LO
        sta     ZP_RESULTS + 6
        lda     ZP_COUNT_MI
        sta     ZP_RESULTS + 7
        lda     ZP_COUNT_HI
        sta     ZP_RESULTS + 8

        ; Phase 3: System turbo (everything fast)
        lda     #3
        sta     ZP_BENCH_PHASE
        sta     SCPU_07B        ; SW turbo on
        sta     SCPU_073        ; Sys 1MHz OFF
        jsr     run_benchmark
        lda     ZP_COUNT_LO
        sta     ZP_RESULTS + 9
        lda     ZP_COUNT_MI
        sta     ZP_RESULTS + 10
        lda     ZP_COUNT_HI
        sta     ZP_RESULTS + 11

        ; ---- Display results ----

        ; Row 3: "1MHZ SW ($D07A):"
        ldx     #0
@l0:    lda     label_1mhz_str, x
        beq     @l0d
        sta     SCREEN + 3 * ROW + 1, x
        inx
        bne     @l0
@l0d:
        lda     ZP_RESULTS + 2
        sta     ZP_COUNT_HI
        lda     ZP_RESULTS + 1
        sta     ZP_COUNT_MI
        lda     ZP_RESULTS + 0
        sta     ZP_COUNT_LO
        lda     #<(SCREEN + 3 * ROW + 22)
        sta     ZP_PTR_LO
        lda     #>(SCREEN + 3 * ROW + 22)
        sta     ZP_PTR_HI
        jsr     display_hex_count

        ; Row 5: "TURBO ($D07B):"
        ldx     #0
@l1:    lda     label_turbo_str, x
        beq     @l1d
        sta     SCREEN + 5 * ROW + 1, x
        inx
        bne     @l1
@l1d:
        lda     ZP_RESULTS + 5
        sta     ZP_COUNT_HI
        lda     ZP_RESULTS + 4
        sta     ZP_COUNT_MI
        lda     ZP_RESULTS + 3
        sta     ZP_COUNT_LO
        lda     #<(SCREEN + 5 * ROW + 22)
        sta     ZP_PTR_LO
        lda     #>(SCREEN + 5 * ROW + 22)
        sta     ZP_PTR_HI
        jsr     display_hex_count

        ; Row 7: "SYS 1MHZ ($D072):"
        ldx     #0
@l2:    lda     label_sys1m_str, x
        beq     @l2d
        sta     SCREEN + 7 * ROW + 1, x
        inx
        bne     @l2
@l2d:
        lda     ZP_RESULTS + 8
        sta     ZP_COUNT_HI
        lda     ZP_RESULTS + 7
        sta     ZP_COUNT_MI
        lda     ZP_RESULTS + 6
        sta     ZP_COUNT_LO
        lda     #<(SCREEN + 7 * ROW + 22)
        sta     ZP_PTR_LO
        lda     #>(SCREEN + 7 * ROW + 22)
        sta     ZP_PTR_HI
        jsr     display_hex_count

        ; Row 9: "SYS TURBO ($D073):"
        ldx     #0
@l3:    lda     label_syst_str, x
        beq     @l3d
        sta     SCREEN + 9 * ROW + 1, x
        inx
        bne     @l3
@l3d:
        lda     ZP_RESULTS + 11
        sta     ZP_COUNT_HI
        lda     ZP_RESULTS + 10
        sta     ZP_COUNT_MI
        lda     ZP_RESULTS + 9
        sta     ZP_COUNT_LO
        lda     #<(SCREEN + 9 * ROW + 22)
        sta     ZP_PTR_LO
        lda     #>(SCREEN + 9 * ROW + 22)
        sta     ZP_PTR_HI
        jsr     display_hex_count

        ; ---- Calculate and display speed ratio ----
        ; Row 11: "SPEED RATIO:"
        ldx     #0
@lr:    lda     label_ratio_str, x
        beq     @lrd
        sta     SCREEN + 11 * ROW + 1, x
        inx
        bne     @lr
@lrd:

        ; Simple ratio: turbo_count / 1mhz_count
        ; Since counts can be large, we do a simple integer division
        ; using the middle byte as primary (gives ~256x range)
        ; For display, show turbo/1mhz as "NNx"
        ;
        ; Quick method: if 1MHz count mid byte is nonzero,
        ; divide turbo_mid by 1mhz_mid
        lda     ZP_RESULTS + 1  ; 1MHz mid byte
        beq     @ratio_hi       ; If zero, try high bytes
        sta     ZP_TMP
        lda     ZP_RESULTS + 4  ; Turbo mid byte
        jsr     divide_a_by_tmp
        jmp     @show_ratio

@ratio_hi:
        ; Use low bytes if mid is zero
        lda     ZP_RESULTS + 0  ; 1MHz low byte
        beq     @no_ratio       ; Can't divide by zero
        sta     ZP_TMP
        lda     ZP_RESULTS + 3  ; Turbo low byte
        jsr     divide_a_by_tmp
        jmp     @show_ratio

@no_ratio:
        lda     #63             ; '?' screen code = 63
        sta     SCREEN + 11 * ROW + 22
        jmp     @after_ratio

@show_ratio:
        ; A = integer ratio
        clc
        adc     #48             ; Convert to screen code digit
        cmp     #58             ; > '9'?
        bcc     @single
        ; Double digit — just show hex
        sec
        sbc     #48             ; Back to number
        jsr     write_hex_a_at_ratio
        jmp     @show_x

@single:
        sta     SCREEN + 11 * ROW + 22
@show_x:
        lda     #24             ; 'X' screen code
        sta     SCREEN + 11 * ROW + 24

@after_ratio:

        ; ---- Speed status register display ----
        ; Row 13: "$D0B8 STATUS:"
        ldx     #0
@ls:    lda     label_status_str, x
        beq     @lsd
        sta     SCREEN + 13 * ROW + 1, x
        inx
        bne     @ls
@lsd:
        lda     SCPU_0B8
        ; Show as hex
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        tax
        lda     hex_chars, x
        sta     SCREEN + 13 * ROW + 22
        pla
        and     #$0F
        tax
        lda     hex_chars, x
        sta     SCREEN + 13 * ROW + 23

        ; ---- Row 15-17: Explanation ----
        ldx     #0
@e1:    lda     explain1_str, x
        beq     @e1d
        sta     SCREEN + 15 * ROW + 1, x
        lda     #14             ; light blue
        sta     COLRAM + 15 * ROW + 1, x
        inx
        bne     @e1
@e1d:
        ldx     #0
@e2:    lda     explain2_str, x
        beq     @e2d
        sta     SCREEN + 16 * ROW + 1, x
        lda     #14
        sta     COLRAM + 16 * ROW + 1, x
        inx
        bne     @e2
@e2d:
        ldx     #0
@e3:    lda     explain3_str, x
        beq     @e3d
        sta     SCREEN + 17 * ROW + 1, x
        lda     #14
        sta     COLRAM + 17 * ROW + 1, x
        inx
        bne     @e3
@e3d:

        ; Color the hex values light green
        ldx     #0
@chex:  cpx     #6
        beq     @chexd
        lda     #13             ; light green
        sta     COLRAM + 3 * ROW + 22, x
        sta     COLRAM + 5 * ROW + 22, x
        sta     COLRAM + 7 * ROW + 22, x
        sta     COLRAM + 9 * ROW + 22, x
        inx
        bne     @chex
@chexd:

        ; Ensure turbo is on
        sta     SCPU_07B
        sta     SCPU_073

        ; Enable interrupts and halt
        cli
@halt:  jmp     @halt


; ======================================================================
; run_benchmark — Count loop iterations between raster lines
; ======================================================================
; Output: ZP_COUNT_LO/MI/HI = 24-bit iteration count
run_benchmark:
        ; Clear counter
        lda     #0
        sta     ZP_COUNT_LO
        sta     ZP_COUNT_MI
        sta     ZP_COUNT_HI

        ; Wait for raster line to be BELOW start (sync point)
@wait_above:
        lda     VIC_RASTER
        cmp     #START_RASTER + 10
        bcc     @wait_above     ; Wait until we're past start

        ; Now wait for START_RASTER (next frame)
@wait_start:
        lda     VIC_RASTER
        cmp     #START_RASTER
        bne     @wait_start

        ; Count loop: increment counter until we reach END_RASTER
@loop:
        ; Increment 24-bit counter
        inc     ZP_COUNT_LO
        bne     @no_carry1
        inc     ZP_COUNT_MI
        bne     @no_carry1
        inc     ZP_COUNT_HI
@no_carry1:

        ; Check raster
        lda     VIC_RASTER
        cmp     #END_RASTER
        bcc     @loop           ; Continue if raster < END_RASTER

        rts


; ======================================================================
; display_hex_count — Show 3-byte hex value at screen pointer
; ======================================================================
; Input: ZP_COUNT_HI/MI/LO, ZP_PTR_LO/HI = screen address
display_hex_count:
        ; Dollar sign prefix
        ldy     #0
        lda     #36             ; '$'
        sta     (ZP_PTR_LO), y
        iny

        ; High byte
        lda     ZP_COUNT_HI
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        tax
        lda     hex_chars, x
        sta     (ZP_PTR_LO), y
        iny
        lda     ZP_COUNT_HI
        and     #$0F
        tax
        lda     hex_chars, x
        sta     (ZP_PTR_LO), y
        iny

        ; Mid byte
        lda     ZP_COUNT_MI
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        tax
        lda     hex_chars, x
        sta     (ZP_PTR_LO), y
        iny
        lda     ZP_COUNT_MI
        and     #$0F
        tax
        lda     hex_chars, x
        sta     (ZP_PTR_LO), y
        iny

        ; Low byte
        lda     ZP_COUNT_LO
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        tax
        lda     hex_chars, x
        sta     (ZP_PTR_LO), y
        iny
        lda     ZP_COUNT_LO
        and     #$0F
        tax
        lda     hex_chars, x
        sta     (ZP_PTR_LO), y

        rts


; ======================================================================
; divide_a_by_tmp — Simple 8-bit A / ZP_TMP
; ======================================================================
; Input: A = dividend, ZP_TMP = divisor
; Output: A = quotient
divide_a_by_tmp:
        ldx     #0
@dloop: cmp     ZP_TMP
        bcc     @ddone
        sec
        sbc     ZP_TMP
        inx
        bne     @dloop          ; Prevent infinite loop
@ddone: txa
        rts


; ======================================================================
; write_hex_a_at_ratio — Write A as hex at ratio position
; ======================================================================
write_hex_a_at_ratio:
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        tax
        lda     hex_chars, x
        sta     SCREEN + 11 * ROW + 22
        pla
        and     #$0F
        tax
        lda     hex_chars, x
        sta     SCREEN + 11 * ROW + 23
        rts


; ======================================================================
; Data
; ======================================================================
.segment "RODATA"

hex_chars:
        ; Screen codes for 0-9, A-F
        .byte   48, 49, 50, 51, 52, 53, 54, 55         ; 0-7
        .byte   56, 57, 1, 2, 3, 4, 5, 6               ; 8-9, A-F

title_str:
        ; "SUPERCPU SPEED BENCHMARK"
        .byte   19, 21, 16, 5, 18, 3, 16, 21           ; SUPERCPU
        .byte   32                                       ; space
        .byte   19, 16, 5, 5, 4                         ; SPEED
        .byte   32                                       ; space
        .byte   2, 5, 14, 3, 8, 13, 1, 18, 11          ; BENCHMARK
        .byte   0

subtitle_str:
        ; "LOOP ITERATIONS RASTER 60-200"
        .byte   12, 15, 15, 16                          ; LOOP
        .byte   32
        .byte   9, 20, 5, 18, 1, 20, 9, 15, 14, 19    ; ITERATIONS
        .byte   32
        .byte   18, 1, 19, 20, 5, 18                   ; RASTER
        .byte   32
        .byte   54, 48, 45, 50, 48, 48                 ; 60-200
        .byte   0

label_1mhz_str:
        ; "1MHZ SW  ($D07A):"
        .byte   49, 13, 8, 26                           ; 1MHZ
        .byte   32, 19, 23                              ; SW
        .byte   32, 32                                  ; spaces
        .byte   40, 36, 4, 48, 55, 1, 41               ; ($D07A)
        .byte   58                                       ; :
        .byte   0

label_turbo_str:
        ; "TURBO    ($D07B):"
        .byte   20, 21, 18, 2, 15                       ; TURBO
        .byte   32, 32, 32, 32                          ; spaces
        .byte   40, 36, 4, 48, 55, 2, 41               ; ($D07B)
        .byte   58                                       ; :
        .byte   0

label_sys1m_str:
        ; "SYS 1MHZ ($D072):"
        .byte   19, 25, 19                              ; SYS
        .byte   32, 49, 13, 8, 26                       ; 1MHZ
        .byte   32                                       ;
        .byte   40, 36, 4, 48, 55, 50, 41               ; ($D072)
        .byte   58                                       ; :
        .byte   0

label_syst_str:
        ; "SYS TURBO($D073):"
        .byte   19, 25, 19                              ; SYS
        .byte   32                                       ;
        .byte   20, 21, 18, 2, 15                       ; TURBO
        .byte   40, 36, 4, 48, 55, 51, 41               ; ($D073)
        .byte   58                                       ; :
        .byte   0

label_ratio_str:
        ; "SPEED RATIO:"
        .byte   19, 16, 5, 5, 4                         ; SPEED
        .byte   32                                       ;
        .byte   18, 1, 20, 9, 15                        ; RATIO
        .byte   58                                       ; :
        .byte   0

label_status_str:
        ; "$D0B8 STATUS:"
        .byte   36, 4, 48, 2, 56                        ; $D0B8
        .byte   32                                       ;
        .byte   19, 20, 1, 20, 21, 19                  ; STATUS
        .byte   58                                       ; :
        .byte   0

explain1_str:
        ; "HIGHER COUNT = FASTER CPU"
        .byte   8, 9, 7, 8, 5, 18                      ; HIGHER
        .byte   32
        .byte   3, 15, 21, 14, 20                      ; COUNT
        .byte   32, 61, 32                              ; =
        .byte   6, 1, 19, 20, 5, 18                    ; FASTER
        .byte   32
        .byte   3, 16, 21                              ; CPU
        .byte   0

explain2_str:
        ; "1MHZ AND TURBO SHOULD DIFFER"
        .byte   49, 13, 8, 26                           ; 1MHZ
        .byte   32
        .byte   1, 14, 4                               ; AND
        .byte   32
        .byte   20, 21, 18, 2, 15                      ; TURBO
        .byte   32
        .byte   19, 8, 15, 21, 12, 4                   ; SHOULD
        .byte   32
        .byte   4, 9, 6, 6, 5, 18                      ; DIFFER
        .byte   0

explain3_str:
        ; "TURBO/1MHZ = SPEEDUP FACTOR"
        .byte   20, 21, 18, 2, 15                      ; TURBO
        .byte   47                                       ; /
        .byte   49, 13, 8, 26                           ; 1MHZ
        .byte   32, 61, 32                              ; =
        .byte   19, 16, 5, 5, 4, 21, 16                ; SPEEDUP
        .byte   32
        .byte   6, 1, 3, 20, 15, 18                    ; FACTOR
        .byte   0
