; ==========================================================================
; scpu_float_test.s — 65816 Float/Math Test for MiSTer SuperCPU
; ==========================================================================
; Assembler: ca65 --cpu 65816
; Linker:    ld65 -C c64-816.cfg
;
; Tests software floating-point-like operations using the 65C816's 16-bit
; native mode capabilities. The 65C816 has no hardware FPU, but its 16-bit
; ALU operations (ADC, SBC, shifts) enable much faster software math than
; the 8-bit 6502.
;
; Tests:
;  1. 16-bit multiply (16x16 -> 32-bit result)
;  2. 16-bit divide   (32 / 16 -> quotient + remainder)
;  3. Fixed-point 8.8 arithmetic
;  4. BASIC FAC ROM float call (emulation mode)
;  5. Speed comparison (1MHz vs turbo, raster-timed multiply loop)
;
; Screen layout:
;  Row 0:  SUPERCPU FLOAT/MATH TEST
;  Row 2:  1 16BIT MULTIPLY     PASS
;  Row 3:  2 16BIT DIVIDE       PASS
;  Row 4:  3 FIXED POINT 8.8    PASS
;  Row 5:  4 BASIC FAC CALL     PASS
;  Row 6:  5 SPEED COMPARISON   4X
;  Row 8:  RESULTS: N/5 PASS
; ==========================================================================

.p816                           ; Enable 65816 instructions
.smart                          ; Smart mode: track A/XY size from REP/SEP

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

; SuperCPU registers
SCPU_07A        = $D07A         ; Software 1MHz enable
SCPU_07B        = $D07B         ; Software turbo enable
SCPU_07E        = $D07E         ; Register enable

; BASIC ROM floating-point routines
; FAC = Floating-point ACcumulator (5 bytes: exponent + 4-byte mantissa + sign)
; ARG = Floating-point ARGument (same format)
BASIC_GIVAYF    = $B391         ; Convert 16-bit signed int (Y=hi,A=lo) to FAC
BASIC_GETADR    = $B7F7         ; Convert FAC to 16-bit unsigned int in $14/$15
BASIC_FMULTT    = $BA28         ; FAC = FAC * ARG (multiply)
BASIC_MOVAF     = $BC0C         ; Copy FAC to ARG
BASIC_MOVFM     = $BBA2         ; Load FAC from memory (pointer in A/Y: lo/hi)

; BASIC zero page locations for FAC
FAC_EXP         = $61           ; FAC exponent
FAC_MANT1       = $62           ; FAC mantissa byte 1 (MSB)
FAC_MANT2       = $63
FAC_MANT3       = $64
FAC_MANT4       = $65           ; FAC mantissa byte 4 (LSB)
FAC_SIGN        = $66           ; FAC sign
BASIC_LINNUM    = $14           ; Result from GETADR (2 bytes, hi/lo)

; Raster timing
START_RASTER    = 60
END_RASTER      = 200

; Screen codes
SC_SPACE        = 32
SC_P            = 16            ; 'P'
SC_A            = 1             ; 'A'
SC_S            = 19            ; 'S'
SC_F            = 6             ; 'F'
SC_I            = 9             ; 'I'
SC_L            = 12            ; 'L'
SC_X            = 24            ; 'X'

; Colors
COL_WHITE       = 1
COL_RED         = 2
COL_GREEN       = 5
COL_YELLOW      = 7
COL_LBLUE       = 14
COL_LGREEN      = 13

; ---- Zero page variables ----
.segment "ZEROPAGE"

; Multiply/divide working storage
zp_multiplier:    .res 2        ; 16-bit multiplier
zp_multiplicand:  .res 2        ; 16-bit multiplicand
zp_result_lo:     .res 2        ; 32-bit result low word
zp_result_hi:     .res 2        ; 32-bit result high word
zp_dividend_lo:   .res 2        ; 32-bit dividend low word
zp_dividend_hi:   .res 2        ; 32-bit dividend high word
zp_divisor:       .res 2        ; 16-bit divisor
zp_quotient:      .res 2        ; 16-bit quotient
zp_remainder:     .res 2        ; 16-bit remainder

; General scratch
zp_tmp:           .res 1
zp_testnum:       .res 1
zp_pass_count:    .res 1
zp_ptr_lo:        .res 1
zp_ptr_hi:        .res 1

; Speed test storage
zp_count_1mhz:    .res 3        ; 24-bit count at 1MHz
zp_count_turbo:   .res 3        ; 24-bit count at turbo
zp_count_lo:      .res 1
zp_count_mi:      .res 1
zp_count_hi:      .res 1

; Fixed-point results
zp_fp_result:     .res 2        ; 8.8 fixed-point result


; ======================================================================
; BASIC SYS stub -- loads at $0801
; ======================================================================
.segment "EXEHDR"
        .word   @end            ; Next BASIC line pointer
        .word   10              ; Line number 10
        .byte   $9E             ; SYS token
        .byte   "2064"          ; SYS address (start of CODE at $0810)
        .byte   0               ; End of BASIC line
@end:   .word   0               ; End of BASIC program


; ======================================================================
; CODE -- main test program
; ======================================================================
.segment "CODE"

; Pad to $0810 (CODE segment starts at $080D after EXEHDR)
        nop
        nop
        nop

start:
        sei
        cld

        ; Initialize
        lda     #0
        sta     zp_pass_count
        sta     zp_testnum

        ; Set screen colors
        lda     #0
        sta     VIC_BGCOL       ; Black background
        lda     #6
        sta     VIC_BRDCOL      ; Blue border

        ; Clear screen
        ldx     #0
@clr:   lda     #SC_SPACE
        sta     SCREEN, x
        sta     SCREEN + $100, x
        sta     SCREEN + $200, x
        sta     SCREEN + $300, x
        lda     #COL_WHITE
        sta     COLRAM, x
        sta     COLRAM + $100, x
        sta     COLRAM + $200, x
        sta     COLRAM + $300, x
        inx
        bne     @clr

        ; Enable SuperCPU registers
        sta     SCPU_07E

        ; Write title (row 0)
        ldx     #0
@title: lda     title_str, x
        beq     @tdone
        sta     SCREEN + 4, x
        lda     #COL_YELLOW
        sta     COLRAM + 4, x
        inx
        bne     @title
@tdone:


; ======================================================================
; TEST 1: 16-bit Multiply (16x16 -> 32-bit result)
; ======================================================================
; $0064 * $0064 = $00002710  (100 * 100 = 10000)
; ======================================================================
        ; Write label
        ldx     #0
@t1l:   lda     t1_str, x
        beq     @t1ld
        sta     SCREEN + 2 * ROW + 1, x
        inx
        bne     @t1l
@t1ld:

        ; Enter native mode, 16-bit
        clc
        xce
        rep     #$30
.a16
.i16
        ; Set up operands
        lda     #$0064          ; multiplier = 100
        sta     zp_multiplier
        lda     #$0064          ; multiplicand = 100
        sta     zp_multiplicand

        ; Clear result
        lda     #0
        sta     zp_result_lo
        sta     zp_result_hi

        ; 16x16->32 shift-and-add multiply
        ; Algorithm: shift multiplier right, if bit set add multiplicand to
        ; high word, then rotate entire 32-bit result right
        ldx     #16             ; 16 bits to process
        lda     #0              ; accumulator = high word working register
@mul_loop:
        lsr     zp_multiplier   ; shift multiplier right, bit into carry
        bcc     @mul_skip
        clc
        adc     zp_multiplicand ; add multiplicand to accumulator
@mul_skip:
        ror     a               ; rotate high word right (carry from add or shift)
        ror     zp_result_lo    ; rotate low word right
        dex
        bne     @mul_loop

        sta     zp_result_hi    ; store final high word

        ; Return to emulation mode
        sep     #$30
.a8
.i8
        sec
        xce

        ; Verify result: $00002710
        ; result_lo should be $2710, result_hi should be $0000
        lda     zp_result_lo
        cmp     #$10            ; low byte of low word
        bne     @t1fail
        lda     zp_result_lo + 1
        cmp     #$27            ; high byte of low word
        bne     @t1fail
        lda     zp_result_hi
        cmp     #$00
        bne     @t1fail
        lda     zp_result_hi + 1
        cmp     #$00
        bne     @t1fail

        ; PASS
        lda     #1
        sta     zp_tmp
        inc     zp_pass_count
        jmp     @t1done
@t1fail:
        lda     #0
        sta     zp_tmp
@t1done:
        lda     #1
        sta     zp_testnum
        jsr     write_pass_fail


; ======================================================================
; TEST 2: 16-bit Divide (32 / 16 -> quotient + remainder)
; ======================================================================
; $00002710 / $0064 = $0064 remainder $0000  (10000 / 100 = 100 R 0)
; ======================================================================
        ldx     #0
@t2l:   lda     t2_str, x
        beq     @t2ld
        sta     SCREEN + 3 * ROW + 1, x
        inx
        bne     @t2l
@t2ld:

        ; Enter native mode
        clc
        xce
        rep     #$30
.a16
.i16
        ; Set up: dividend = $00002710, divisor = $0064
        lda     #$2710
        sta     zp_dividend_lo
        lda     #$0000
        sta     zp_dividend_hi
        lda     #$0064
        sta     zp_divisor
        lda     #$0000
        sta     zp_quotient
        sta     zp_remainder

        ; 32/16 -> 16 division using shift-and-subtract
        ; Shift dividend left into remainder, compare with divisor,
        ; subtract if >= and set quotient bit
        ldx     #32             ; 32 bits to process
@div_loop:
        ; Shift dividend left: remainder:dividend <<= 1
        asl     zp_dividend_lo
        rol     zp_dividend_hi
        rol     zp_remainder

        ; Compare remainder with divisor
        lda     zp_remainder
        sec
        sbc     zp_divisor
        bcc     @div_skip       ; remainder < divisor, skip

        ; remainder >= divisor: store new remainder, set quotient bit
        sta     zp_remainder
        inc     zp_dividend_lo  ; set lowest bit of dividend (becomes quotient)
@div_skip:
        dex
        bne     @div_loop

        ; Quotient is now in dividend_lo, remainder in zp_remainder
        lda     zp_dividend_lo
        sta     zp_quotient

        ; Return to emulation
        sep     #$30
.a8
.i8
        sec
        xce

        ; Verify: quotient = $0064, remainder = $0000
        lda     zp_quotient
        cmp     #$64
        bne     @t2fail
        lda     zp_quotient + 1
        cmp     #$00
        bne     @t2fail
        lda     zp_remainder
        cmp     #$00
        bne     @t2fail
        lda     zp_remainder + 1
        cmp     #$00
        bne     @t2fail

        lda     #1
        sta     zp_tmp
        inc     zp_pass_count
        jmp     @t2done
@t2fail:
        lda     #0
        sta     zp_tmp
@t2done:
        lda     #2
        sta     zp_testnum
        jsr     write_pass_fail


; ======================================================================
; TEST 3: Fixed-point 8.8 arithmetic
; ======================================================================
; 8.8 format: high byte = integer, low byte = fraction (x/256)
; 3.5 = $0380 (3 + 128/256)
; 2.0 = $0200
; 3.5 * 2.0 = 7.0 = $0700
;
; Method: use 16x16->32 multiply, then shift right 8 to realign the
; decimal point. The middle two bytes of the 32-bit result contain
; the 8.8 fixed-point answer.
; ======================================================================
        ldx     #0
@t3l:   lda     t3_str, x
        beq     @t3ld
        sta     SCREEN + 4 * ROW + 1, x
        inx
        bne     @t3l
@t3ld:

        clc
        xce
        rep     #$30
.a16
.i16
        ; Multiply $0380 * $0200 using our multiply algorithm
        lda     #$0380          ; 3.5 in 8.8
        sta     zp_multiplier
        lda     #$0200          ; 2.0 in 8.8
        sta     zp_multiplicand

        lda     #0
        sta     zp_result_lo
        sta     zp_result_hi

        ldx     #16
        lda     #0
@fp_mul_loop:
        lsr     zp_multiplier
        bcc     @fp_mul_skip
        clc
        adc     zp_multiplicand
@fp_mul_skip:
        ror     a
        ror     zp_result_lo
        dex
        bne     @fp_mul_loop

        sta     zp_result_hi

        ; 32-bit result of $0380 * $0200 = $00070000
        ; In 8.8 fixed-point, the result is the middle two bytes: result_hi:lo >> 8
        ; Actually: the full 32-bit product is in result_hi:result_lo
        ; For 8.8 * 8.8: the decimal point is at bit 16, so we need bits 23:8
        ; That's: high byte of result_lo (integer part of fraction contribution)
        ;         + low byte of result_hi (main integer result)
        ; = result_lo+1 : result_hi (low byte)
        ; Let's just extract: fp_result = (result_hi << 8) | (result_lo >> 8)
        ; Which is: fp_result_lo = high byte of result_lo, fp_result_hi = low byte of result_hi

        ; Get high byte of result_lo
        lda     zp_result_lo
        xba                     ; swap bytes: now A_lo = old A_hi
        and     #$00FF          ; mask to get just the high byte of result_lo
        sta     zp_fp_result    ; this becomes the fractional part

        lda     zp_result_hi
        and     #$00FF          ; low byte of result_hi = integer part
        xba                     ; move to high byte position
        ora     zp_fp_result    ; combine with fraction
        sta     zp_fp_result    ; full 8.8 result

        sep     #$30
.a8
.i8
        sec
        xce

        ; Verify: result should be $0700 (7.0)
        lda     zp_fp_result        ; fraction byte (low)
        cmp     #$00
        bne     @t3fail
        lda     zp_fp_result + 1    ; integer byte (high)
        cmp     #$07
        bne     @t3fail

        lda     #1
        sta     zp_tmp
        inc     zp_pass_count
        jmp     @t3done
@t3fail:
        lda     #0
        sta     zp_tmp
@t3done:
        lda     #3
        sta     zp_testnum
        jsr     write_pass_fail


; ======================================================================
; TEST 4: BASIC FAC ROM float call
; ======================================================================
; Tests that our cache/turbo correctly handles BASIC ROM calls.
; We must be in EMULATION mode for BASIC ROM calls (they expect 6502).
;
; Plan:
;   1. Convert integer 50 to FAC  (using GIVAYF: Y=hi, A=lo)
;   2. Copy FAC to ARG            (MOVAF)
;   3. Multiply FAC * ARG         (FMULTT: FAC = FAC * ARG = 50 * 50)
;   4. Convert FAC back to int    (GETADR: result in $14/$15)
;   5. Verify result = 2500
; ======================================================================
        ldx     #0
@t4l:   lda     t4_str, x
        beq     @t4ld
        sta     SCREEN + 5 * ROW + 1, x
        inx
        bne     @t4l
@t4ld:

        ; We are already in emulation mode (8-bit, SEC/XCE above)
        ; BASIC ROM expects emulation mode, IRQs off (SEI already done)

        ; Convert 50 to FAC
        ldy     #$00            ; High byte of 50 = $00
        lda     #$32            ; Low byte of 50 = $32
        jsr     BASIC_GIVAYF    ; FAC = 50.0

        ; Copy FAC to ARG
        jsr     BASIC_MOVAF     ; ARG = FAC = 50.0

        ; Multiply: FAC = FAC * ARG = 50.0 * 50.0 = 2500.0
        jsr     BASIC_FMULTT

        ; Convert FAC to 16-bit unsigned integer
        jsr     BASIC_GETADR    ; Result in BASIC_LINNUM ($14=hi, $15=lo)

        ; Verify: 2500 = $09C4
        ; GETADR stores big-endian: $14=high byte, $15=low byte
        lda     BASIC_LINNUM    ; High byte ($14)
        cmp     #$09
        bne     @t4fail
        lda     BASIC_LINNUM+1  ; Low byte ($15)
        cmp     #$C4
        bne     @t4fail

        lda     #1
        sta     zp_tmp
        inc     zp_pass_count
        jmp     @t4done
@t4fail:
        lda     #0
        sta     zp_tmp
@t4done:
        lda     #4
        sta     zp_testnum
        jsr     write_pass_fail


; ======================================================================
; TEST 5: Speed comparison (1MHz vs turbo multiply loop)
; ======================================================================
; Run a loop of 16-bit multiplies between two raster positions.
; Count iterations at 1MHz, then at turbo speed.
; Display the speedup ratio as "NX".
; ======================================================================
        ldx     #0
@t5l:   lda     t5_str, x
        beq     @t5ld
        sta     SCREEN + 6 * ROW + 1, x
        inx
        bne     @t5l
@t5ld:

        ; ---- Phase 1: 1MHz benchmark ----
        sta     SCPU_07A        ; Force 1MHz

        ; Clear counter
        lda     #0
        sta     zp_count_lo
        sta     zp_count_mi
        sta     zp_count_hi

        ; Wait for raster to pass start (sync)
@s1_above:
        lda     VIC_RASTER
        cmp     #START_RASTER + 10
        bcc     @s1_above

        ; Wait for start raster
@s1_wait:
        lda     VIC_RASTER
        cmp     #START_RASTER
        bne     @s1_wait

        ; Count iterations of a quick 16-bit multiply
@s1_loop:
        ; Do a small multiply in native mode to exercise 16-bit ALU
        clc
        xce                     ; native mode
        rep     #$20
.a16
        lda     #$000A
        sta     zp_multiplier
        lda     #$000A
        ; Quick 4-iteration multiply (just a few shifts for timing)
        asl     a
        asl     a
        asl     a
        sta     zp_result_lo
        sep     #$20
.a8
        sec
        xce                     ; emulation mode

        ; Increment counter
        inc     zp_count_lo
        bne     @s1_norip
        inc     zp_count_mi
        bne     @s1_norip
        inc     zp_count_hi
@s1_norip:
        ; Check raster
        lda     VIC_RASTER
        cmp     #END_RASTER
        bcc     @s1_loop

        ; Store 1MHz result
        lda     zp_count_lo
        sta     zp_count_1mhz
        lda     zp_count_mi
        sta     zp_count_1mhz + 1
        lda     zp_count_hi
        sta     zp_count_1mhz + 2

        ; ---- Phase 2: Turbo benchmark ----
        sta     SCPU_07B        ; Enable turbo

        ; Clear counter
        lda     #0
        sta     zp_count_lo
        sta     zp_count_mi
        sta     zp_count_hi

        ; Sync to raster
@s2_above:
        lda     VIC_RASTER
        cmp     #START_RASTER + 10
        bcc     @s2_above

@s2_wait:
        lda     VIC_RASTER
        cmp     #START_RASTER
        bne     @s2_wait

@s2_loop:
        clc
        xce
        rep     #$20
.a16
        lda     #$000A
        sta     zp_multiplier
        lda     #$000A
        asl     a
        asl     a
        asl     a
        sta     zp_result_lo
        sep     #$20
.a8
        sec
        xce

        inc     zp_count_lo
        bne     @s2_norip
        inc     zp_count_mi
        bne     @s2_norip
        inc     zp_count_hi
@s2_norip:
        lda     VIC_RASTER
        cmp     #END_RASTER
        bcc     @s2_loop

        ; Store turbo result
        lda     zp_count_lo
        sta     zp_count_turbo
        lda     zp_count_mi
        sta     zp_count_turbo + 1
        lda     zp_count_hi
        sta     zp_count_turbo + 2

        ; ---- Calculate speed ratio ----
        ; Simple ratio: turbo_count / 1mhz_count
        ; Use the most significant non-zero byte pair for reasonable precision
        lda     zp_count_1mhz + 1   ; mid byte of 1MHz
        beq     @try_low
        sta     zp_tmp
        lda     zp_count_turbo + 1
        jsr     divide_8bit
        jmp     @show_speed

@try_low:
        lda     zp_count_1mhz       ; low byte of 1MHz
        beq     @no_speed            ; can't divide by zero
        sta     zp_tmp
        lda     zp_count_turbo
        jsr     divide_8bit
        jmp     @show_speed

@no_speed:
        ; Show '?' if we can't compute
        lda     #63             ; '?'
        sta     SCREEN + 6 * ROW + 35
        jmp     @t5done

@show_speed:
        ; A = speed ratio (integer)
        ; Display as "NX" at row 6, col 35
        cmp     #10
        bcs     @two_digit

        ; Single digit
        clc
        adc     #48             ; screen code for digit
        sta     SCREEN + 6 * ROW + 35
        lda     #SC_X
        sta     SCREEN + 6 * ROW + 36
        jmp     @color_speed

@two_digit:
        ; Two digits: tens at col 34, ones at col 35, X at col 36
        ldx     #0
@tens:  cmp     #10
        bcc     @ones_d
        sec
        sbc     #10
        inx
        bne     @tens
@ones_d:
        ; X = tens digit, A = ones digit
        pha
        txa
        clc
        adc     #48
        sta     SCREEN + 6 * ROW + 34
        pla
        clc
        adc     #48
        sta     SCREEN + 6 * ROW + 35
        lda     #SC_X
        sta     SCREEN + 6 * ROW + 36

@color_speed:
        ; Color the speed indicator light green
        lda     #COL_LGREEN
        sta     COLRAM + 6 * ROW + 34
        sta     COLRAM + 6 * ROW + 35
        sta     COLRAM + 6 * ROW + 36

@t5done:


; ======================================================================
; Summary row
; ======================================================================
        ; Write "RESULTS:" label at row 8
        ldx     #0
@suml:  lda     summary_str, x
        beq     @sumld
        sta     SCREEN + 8 * ROW + 1, x
        inx
        bne     @suml
@sumld:

        ; Display pass count
        lda     zp_pass_count
        clc
        adc     #48             ; convert to screen digit
        sta     SCREEN + 8 * ROW + 10

        ; "/5 PASS"
        lda     #47             ; '/'
        sta     SCREEN + 8 * ROW + 11
        lda     #53             ; '5'
        sta     SCREEN + 8 * ROW + 12
        lda     #SC_SPACE
        sta     SCREEN + 8 * ROW + 13
        lda     #SC_P
        sta     SCREEN + 8 * ROW + 14
        lda     #SC_A
        sta     SCREEN + 8 * ROW + 15
        lda     #SC_S
        sta     SCREEN + 8 * ROW + 16
        lda     #SC_S
        sta     SCREEN + 8 * ROW + 17

        ; Color the summary
        lda     zp_pass_count
        cmp     #5              ; all passed?
        bne     @sum_partial
        lda     #COL_GREEN
        jmp     @sum_color
@sum_partial:
        lda     #COL_YELLOW
@sum_color:
        ldx     #0
@sc_loop:
        sta     COLRAM + 8 * ROW + 10, x
        inx
        cpx     #8
        bne     @sc_loop

        ; ---- Color the PASS/FAIL results ----
        ; Tests 1-4 at rows 2-5, test 5 at row 6 (speed, no pass/fail coloring)
        ldx     #0              ; test index (0..3)
@color_loop:
        ; Row = X + 2
        txa
        clc
        adc     #2
        ; Multiply by 40
        tay                     ; save row number
        ; row * 40 = row * 32 + row * 8
        asl     a               ; *2
        asl     a               ; *4
        asl     a               ; *8
        sta     zp_ptr_lo       ; row*8
        tya
        asl     a               ; *2
        asl     a               ; *4
        asl     a               ; *8
        asl     a               ; *16
        asl     a               ; *32
        clc
        adc     zp_ptr_lo       ; *40
        adc     #35             ; + column 35
        tay                     ; Y = screen offset

        ; Check what character is there
        lda     SCREEN, y
        cmp     #SC_P           ; 'P' = PASS
        bne     @cr
        lda     #COL_GREEN
        jmp     @cw
@cr:    lda     #COL_RED
@cw:    sta     COLRAM, y
        iny
        sta     COLRAM, y
        iny
        sta     COLRAM, y
        iny
        sta     COLRAM, y

        inx
        cpx     #4              ; only 4 pass/fail tests
        bne     @color_loop

        ; ---- Display hex values for debug (row 10+) ----
        ; Row 10: "1MHZ: $XXXXXX  TURBO: $XXXXXX"
        ldx     #0
@dbgl:  lda     debug_str, x
        beq     @dbgld
        sta     SCREEN + 10 * ROW + 1, x
        lda     #COL_LBLUE
        sta     COLRAM + 10 * ROW + 1, x
        inx
        bne     @dbgl
@dbgld:

        ; Display 1MHz count as hex at row 10, col 7
        lda     zp_count_1mhz + 2
        jsr     byte_to_hex_pair
        stx     SCREEN + 10 * ROW + 8
        sta     SCREEN + 10 * ROW + 9
        lda     zp_count_1mhz + 1
        jsr     byte_to_hex_pair
        stx     SCREEN + 10 * ROW + 10
        sta     SCREEN + 10 * ROW + 11
        lda     zp_count_1mhz
        jsr     byte_to_hex_pair
        stx     SCREEN + 10 * ROW + 12
        sta     SCREEN + 10 * ROW + 13

        ; Display turbo count at row 10, col 24
        lda     zp_count_turbo + 2
        jsr     byte_to_hex_pair
        stx     SCREEN + 10 * ROW + 24
        sta     SCREEN + 10 * ROW + 25
        lda     zp_count_turbo + 1
        jsr     byte_to_hex_pair
        stx     SCREEN + 10 * ROW + 26
        sta     SCREEN + 10 * ROW + 27
        lda     zp_count_turbo
        jsr     byte_to_hex_pair
        stx     SCREEN + 10 * ROW + 28
        sta     SCREEN + 10 * ROW + 29

        ; Ensure turbo stays on
        sta     SCPU_07B

        ; Infinite loop
@halt:  jmp     @halt


; ======================================================================
; Subroutines
; ======================================================================

; Write PASS or FAIL based on zp_tmp (0=fail, nonzero=pass)
; zp_testnum = test number (1-based), displayed at row (testnum + 1)
write_pass_fail:
        ; Row = testnum + 1
        lda     zp_testnum
        clc
        adc     #1
        ; Row * 40
        tay
        asl     a
        asl     a
        asl     a
        sta     zp_ptr_lo
        tya
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        clc
        adc     zp_ptr_lo
        ; + column 35
        adc     #35
        sta     zp_ptr_lo
        lda     #0
        adc     #>SCREEN
        sta     zp_ptr_hi

        lda     zp_tmp
        beq     @fail

        ; PASS
        ldy     #0
        lda     #SC_P
        sta     (zp_ptr_lo), y
        iny
        lda     #SC_A
        sta     (zp_ptr_lo), y
        iny
        lda     #SC_S
        sta     (zp_ptr_lo), y
        iny
        lda     #SC_S
        sta     (zp_ptr_lo), y
        rts

@fail:
        ldy     #0
        lda     #SC_F
        sta     (zp_ptr_lo), y
        iny
        lda     #SC_A
        sta     (zp_ptr_lo), y
        iny
        lda     #SC_I
        sta     (zp_ptr_lo), y
        iny
        lda     #SC_L
        sta     (zp_ptr_lo), y
        rts


; divide_8bit — Simple 8-bit A / zp_tmp
; Input: A = dividend, zp_tmp = divisor
; Output: A = quotient
divide_8bit:
        ldx     #0
@dloop: cmp     zp_tmp
        bcc     @ddone
        sec
        sbc     zp_tmp
        inx
        cpx     #$FF            ; safety limit
        bne     @dloop
@ddone: txa
        rts


; byte_to_hex_pair — Convert byte in A to two hex screen codes
; Input: A = byte value
; Output: X = high nybble screen code, A = low nybble screen code
byte_to_hex_pair:
        pha
        lsr     a
        lsr     a
        lsr     a
        lsr     a
        tax
        lda     hex_chars, x
        tax                     ; X = high nybble screen code
        pla
        and     #$0F
        tay
        lda     hex_chars, y    ; A = low nybble screen code
        rts


; ======================================================================
; String Data (screen codes, null-terminated)
; ======================================================================
.segment "RODATA"

hex_chars:
        ; Screen codes for 0-9, A-F
        .byte   48, 49, 50, 51, 52, 53, 54, 55     ; 0-7
        .byte   56, 57, 1, 2, 3, 4, 5, 6           ; 8-9, A-F

title_str:
        ; "SUPERCPU FLOAT/MATH TEST"
        ; S=19 U=21 P=16 E=5 R=18 C=3 P=16 U=21
        ; space=32 F=6 L=12 O=15 A=1 T=20 /=47
        ; M=13 A=1 T=20 H=8 space=32 T=20 E=5 S=19 T=20
        .byte   19, 21, 16, 5, 18, 3, 16, 21       ; SUPERCPU
        .byte   32                                   ; space
        .byte   6, 12, 15, 1, 20, 47                ; FLOAT/
        .byte   13, 1, 20, 8                        ; MATH
        .byte   32                                   ; space
        .byte   20, 5, 19, 20                       ; TEST
        .byte   0

t1_str:
        ; "1 16BIT MULTIPLY"
        .byte   49, 32                              ; "1 "
        .byte   49, 54, 2, 9, 20                    ; 16BIT
        .byte   32                                   ; space
        .byte   13, 21, 12, 20, 9, 16, 12, 25      ; MULTIPLY
        .byte   0

t2_str:
        ; "2 16BIT DIVIDE"
        .byte   50, 32                              ; "2 "
        .byte   49, 54, 2, 9, 20                    ; 16BIT
        .byte   32                                   ; space
        .byte   4, 9, 22, 9, 4, 5                   ; DIVIDE
        .byte   0

t3_str:
        ; "3 FIXED POINT 8.8"
        .byte   51, 32                              ; "3 "
        .byte   6, 9, 24, 5, 4                      ; FIXED
        .byte   32                                   ; space
        .byte   16, 15, 9, 14, 20                   ; POINT
        .byte   32                                   ; space
        .byte   56, 46, 56                           ; 8.8
        .byte   0

t4_str:
        ; "4 BASIC FAC CALL"
        .byte   52, 32                              ; "4 "
        .byte   2, 1, 19, 9, 3                      ; BASIC
        .byte   32                                   ; space
        .byte   6, 1, 3                             ; FAC
        .byte   32                                   ; space
        .byte   3, 1, 12, 12                        ; CALL
        .byte   0

t5_str:
        ; "5 SPEED COMPARISON"
        .byte   53, 32                              ; "5 "
        .byte   19, 16, 5, 5, 4                     ; SPEED
        .byte   32                                   ; space
        .byte   3, 15, 13, 16, 1, 18, 9, 19, 15, 14 ; COMPARISON
        .byte   0

summary_str:
        ; "RESULTS:"
        .byte   18, 5, 19, 21, 12, 20, 19, 58, 32  ; RESULTS:_
        .byte   0

debug_str:
        ; "1MHZ: $       TURBO: $"
        ; 1=49 M=13 H=8 Z=26 :=58 space=32 $=36
        ; T=20 U=21 R=18 B=2 O=15
        .byte   49, 13, 8, 26, 58, 32, 36           ; "1MHZ: $"
        .byte   32, 32, 32, 32, 32, 32              ; 6 spaces for hex
        .byte   32, 32                               ; gap
        .byte   20, 21, 18, 2, 15, 58, 32, 36       ; "TURBO: $"
        .byte   0

; Float constant: 2.0 in C64 BASIC FAC format (5 bytes: exp, m1, m2, m3, m4)
; 2.0 = exponent $82 ($80+2), mantissa $00000000 (implicit 1 bit)
float_two:
        .byte   $82, $00, $00, $00, $00
