; ==========================================================================
; scpu_native_test.s — 65816 Native Mode Feature Test for MiSTer SuperCPU
; ==========================================================================
; Assembler: ca65 --cpu 65816
; Linker:    ld65 -C c64-816.cfg
;
; Tests 65816-specific features that real SuperCPU software relies on:
;  1. CLC/XCE native mode entry, SEC/XCE return
;  2. REP #$30 for 16-bit A and X/Y
;  3. 16-bit ADC arithmetic
;  4. 16-bit SBC arithmetic
;  5. Direct Page relocation (TCD)
;  6. Stack relocation (TCS/TSC)
;  7. Block move MVN (forward copy)
;  8. Block move MVP (backward copy)
;  9. PEA stack operation
; 10. PEI stack operation
; 11. PER stack operation
; 12. JSL/RTL long subroutine call
; 13. PHB/PLB data bank register
; 14. 16-bit index registers (X/Y)
; 15. Mixed 8/16-bit mode switching
;
; Each test writes screen code P (PASS) or F (FAIL) at column 35 of its row.
; Green = PASS, Red = FAIL.
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

; SuperCPU registers
SCPU_07E        = $D07E         ; Register enable
SCPU_07B        = $D07B         ; Turbo enable

; Screen codes
SC_SPACE        = 32
SC_P            = 16            ; 'P'
SC_A            = 1             ; 'A'
SC_S            = 19            ; 'S'
SC_F            = 6             ; 'F'
SC_I            = 9             ; 'I'
SC_L            = 12            ; 'L'

; Colors
COL_WHITE       = 1
COL_RED         = 2
COL_GREEN       = 5
COL_YELLOW      = 7
COL_LBLUE       = 14

; Zero page scratch (safe locations not used by KERNAL)
ZP_TMP          = $02
ZP_TMP2         = $03
ZP_RESULT_LO    = $04           ; Bitmask of test results (tests 1-8)
ZP_RESULT_HI    = $05           ; Bitmask of test results (tests 9-15)
ZP_TESTNUM      = $06
ZP_STORE16_LO   = $07
ZP_STORE16_HI   = $08
ZP_PTR_LO       = $09
ZP_PTR_HI       = $0A
ZP_DP_TEST      = $0B           ; For direct page relocation test
ZP_DP_TEST2     = $0C

; Relocated direct page area
DP_RELOCATED    = $0300         ; We will relocate DP here
DP_TEST_OFF     = $0B           ; Offset within relocated DP to test

; Block move source/dest
BLKMOV_SRC      = $C000         ; Source for block move tests
BLKMOV_DST      = $C100         ; Destination for block move tests
BLKMOV_LEN      = 16            ; Number of bytes to move


; ======================================================================
; BASIC SYS stub — loads at $0801
; ======================================================================
.segment "EXEHDR"
        .word   @end            ; Next BASIC line pointer
        .word   10              ; Line number 10
        .byte   $9E             ; SYS token
        .byte   "2061"          ; SYS address (start of CODE segment)
        .byte   0               ; End of BASIC line
@end:   .word   0               ; End of BASIC program


; ======================================================================
; CODE — main test program
; ======================================================================
.segment "CODE"

start:
        sei
        cld

        ; Clear result bitmask
        lda     #0
        sta     ZP_RESULT_LO
        sta     ZP_RESULT_HI
        sta     ZP_TESTNUM

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

        ; Write title
        ldx     #0
@title: lda     title_str, x
        beq     @tdone
        sta     SCREEN + 5, x
        lda     #COL_YELLOW
        sta     COLRAM + 5, x
        inx
        bne     @title
@tdone:

; ======================================================================
; TEST 1: CLC/XCE native mode entry and SEC/XCE return
; ======================================================================
        jsr     write_test1_label

        ; Enter native mode
        clc
        xce                     ; C <- old E (should be 1), E <- old C (0 = native)
        ; Save carry (should be 1 = was in emulation)
        php
        ; Return to emulation immediately
        sec
        xce                     ; C <- old E (0 = was native), E <- 1 = emulation

        ; Check: carry after first XCE should have been 1
        ; We saved P on stack — pull it
        pla
        and     #$01            ; Carry bit
        cmp     #$01
        bne     @t1fail

        ; Also verify we're back in emulation (carry from 2nd XCE should be 0)
        ; Carry is currently whatever AND left — need to check 2nd XCE carry
        ; Actually the SEC/XCE already happened; carry = old E = 0 (was native)
        ; Let's re-verify: enter and exit again, check both carries
        clc
        xce                     ; Enter native, C=1
        bcc     @t1fail_native  ; If carry clear, XCE didn't work
        sec
        xce                     ; Return to emulation, C=0
        bcs     @t1fail         ; If carry set, didn't return properly

        lda     #1
        sta     ZP_TMP
        jmp     @t1done

@t1fail_native:
        sec
        xce                     ; Ensure we return to emulation
@t1fail:
        lda     #0
        sta     ZP_TMP
@t1done:
        lda     #1
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 2: REP #$30 for 16-bit A and X/Y
; ======================================================================
        jsr     write_test2_label

        clc
        xce                     ; Enter native mode
        rep     #$30            ; 16-bit A, 16-bit X/Y
.a16
.i16
        lda     #$1234
        sta     ZP_STORE16_LO  ; Stores 2 bytes: $07=$34, $08=$12
        ldx     #$5678
        stx     ZP_PTR_LO      ; Stores 2 bytes: $09=$78, $0A=$56

        sep     #$30            ; 8-bit A, 8-bit X/Y
.a8
.i8
        sec
        xce                     ; Return to emulation

        ; Verify stored values
        lda     ZP_STORE16_LO
        cmp     #$34
        bne     @t2fail
        lda     ZP_STORE16_HI
        cmp     #$12
        bne     @t2fail
        lda     ZP_PTR_LO
        cmp     #$78
        bne     @t2fail
        lda     ZP_PTR_HI
        cmp     #$56
        bne     @t2fail

        lda     #1
        sta     ZP_TMP
        jmp     @t2done
@t2fail:
        lda     #0
        sta     ZP_TMP
@t2done:
        lda     #2
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 3: 16-bit ADC arithmetic
; ======================================================================
        jsr     write_test3_label

        clc
        xce                     ; Native mode
        rep     #$20            ; 16-bit A
.a16
        clc
        lda     #$1111
        adc     #$2222          ; Should be $3333
        sta     ZP_STORE16_LO

        ; Test with carry in
        sec
        lda     #$FFFE
        adc     #$0001          ; $FFFE + $0001 + 1(carry) = $10000, result = $0000, C=1
        sta     ZP_PTR_LO      ; Should be $0000

        sep     #$20
.a8
        sec
        xce                     ; Emulation mode

        ; Check $3333 result
        lda     ZP_STORE16_LO
        cmp     #$33
        bne     @t3fail
        lda     ZP_STORE16_HI
        cmp     #$33
        bne     @t3fail
        ; Check $0000 result
        lda     ZP_PTR_LO
        cmp     #$00
        bne     @t3fail
        lda     ZP_PTR_HI
        cmp     #$00
        bne     @t3fail

        lda     #1
        sta     ZP_TMP
        jmp     @t3done
@t3fail:
        lda     #0
        sta     ZP_TMP
@t3done:
        lda     #3
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 4: 16-bit SBC arithmetic
; ======================================================================
        jsr     write_test4_label

        clc
        xce                     ; Native mode
        rep     #$20            ; 16-bit A
.a16
        sec                     ; Set carry for subtraction (no borrow)
        lda     #$5555
        sbc     #$1111          ; $5555 - $1111 = $4444
        sta     ZP_STORE16_LO

        ; Test underflow
        sec
        lda     #$0002
        sbc     #$0003          ; $0002 - $0003 = $FFFF, C=0 (borrow)
        sta     ZP_PTR_LO      ; Should be $FFFF

        sep     #$20
.a8
        sec
        xce                     ; Emulation mode

        lda     ZP_STORE16_LO
        cmp     #$44
        bne     @t4fail
        lda     ZP_STORE16_HI
        cmp     #$44
        bne     @t4fail
        lda     ZP_PTR_LO
        cmp     #$FF
        bne     @t4fail
        lda     ZP_PTR_HI
        cmp     #$FF
        bne     @t4fail

        lda     #1
        sta     ZP_TMP
        jmp     @t4done
@t4fail:
        lda     #0
        sta     ZP_TMP
@t4done:
        lda     #4
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 5: Direct Page relocation (TCD)
; ======================================================================
        jsr     write_test5_label

        ; Write a known value at DP_RELOCATED + DP_TEST_OFF ($030B)
        lda     #$A5
        sta     DP_RELOCATED + DP_TEST_OFF

        clc
        xce                     ; Native mode
        rep     #$20            ; 16-bit A
.a16
        lda     #DP_RELOCATED   ; Load $0300
        tcd                     ; Direct Page = $0300

        sep     #$20            ; 8-bit A
.a8
        ; Now DP-relative $0B refers to $030B
        lda     $0B             ; Direct page access: reads $030B
        cmp     #$A5
        bne     @t5fail_nat

        ; Write via DP and read back via absolute
        lda     #$5A
        sta     $0B             ; Writes to $030B

        ; Restore DP to $0000
        rep     #$20
.a16
        lda     #$0000
        tcd
        sep     #$20
.a8
        sec
        xce                     ; Emulation mode

        ; Verify via absolute addressing
        lda     DP_RELOCATED + DP_TEST_OFF
        cmp     #$5A
        bne     @t5fail

        lda     #1
        sta     ZP_TMP
        jmp     @t5done

@t5fail_nat:
        ; Restore DP before leaving native mode
        rep     #$20
.a16
        lda     #$0000
        tcd
        sep     #$20
.a8
        sec
        xce
@t5fail:
        lda     #0
        sta     ZP_TMP
@t5done:
        lda     #5
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 6: Stack relocation (TCS/TSC)
; ======================================================================
        jsr     write_test6_label

        clc
        xce                     ; Native mode
        rep     #$20            ; 16-bit A
.a16
        ; Save current SP
        tsc                     ; A = SP
        sta     ZP_STORE16_LO  ; Save original SP

        ; Relocate stack to $0400 area (we'll use $03F0 to be safe)
        lda     #$03F0
        tcs                     ; SP = $03F0

        ; Read back SP
        tsc
        sta     ZP_PTR_LO      ; Should be $03F0

        ; Restore original SP
        lda     ZP_STORE16_LO
        tcs

        sep     #$20
.a8
        sec
        xce                     ; Emulation mode

        ; Verify SP was relocated
        lda     ZP_PTR_LO
        cmp     #$F0
        bne     @t6fail
        lda     ZP_PTR_HI
        cmp     #$03
        bne     @t6fail

        lda     #1
        sta     ZP_TMP
        jmp     @t6done
@t6fail:
        lda     #0
        sta     ZP_TMP
@t6done:
        lda     #6
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 7: Block Move MVN (forward copy, ascending addresses)
; ======================================================================
        jsr     write_test7_label

        ; Fill source with pattern
        ldx     #0
@fill7: txa
        sta     BLKMOV_SRC, x
        lda     #0
        sta     BLKMOV_DST, x  ; Clear destination
        inx
        cpx     #BLKMOV_LEN
        bne     @fill7

        clc
        xce                     ; Native mode
        rep     #$30            ; 16-bit A, X, Y
.a16
.i16
        ; MVN src_bank, dst_bank
        ; X = source address, Y = dest address, A = count-1
        ldx     #BLKMOV_SRC     ; Source
        ldy     #BLKMOV_DST     ; Destination
        lda     #BLKMOV_LEN-1   ; Count - 1
        mvn     0, 0            ; Move from bank 0 to bank 0

        sep     #$30
.a8
.i8
        sec
        xce                     ; Emulation mode

        ; Verify destination matches source pattern
        ldx     #0
@chk7:  lda     BLKMOV_SRC, x
        cmp     BLKMOV_DST, x
        bne     @t7fail
        inx
        cpx     #BLKMOV_LEN
        bne     @chk7

        lda     #1
        sta     ZP_TMP
        jmp     @t7done
@t7fail:
        lda     #0
        sta     ZP_TMP
@t7done:
        lda     #7
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 8: Block Move MVP (backward copy, descending addresses)
; ======================================================================
        jsr     write_test8_label

        ; Fill source with reverse pattern
        ldx     #0
@fill8: txa
        eor     #$FF
        sta     BLKMOV_SRC, x
        lda     #0
        sta     BLKMOV_DST, x  ; Clear destination
        inx
        cpx     #BLKMOV_LEN
        bne     @fill8

        clc
        xce                     ; Native mode
        rep     #$30
.a16
.i16
        ; MVP: X = source end, Y = dest end, A = count-1
        ; Moves from high to low addresses
        ldx     #BLKMOV_SRC + BLKMOV_LEN - 1
        ldy     #BLKMOV_DST + BLKMOV_LEN - 1
        lda     #BLKMOV_LEN-1
        mvp     0, 0

        sep     #$30
.a8
.i8
        sec
        xce

        ; Verify
        ldx     #0
@chk8:  lda     BLKMOV_SRC, x
        cmp     BLKMOV_DST, x
        bne     @t8fail
        inx
        cpx     #BLKMOV_LEN
        bne     @chk8

        lda     #1
        sta     ZP_TMP
        jmp     @t8done
@t8fail:
        lda     #0
        sta     ZP_TMP
@t8done:
        lda     #8
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 9: PEA — Push Effective Absolute address
; ======================================================================
        jsr     write_test9_label

        clc
        xce                     ; Native mode

        ; PEA pushes a 16-bit value onto the stack
        pea     $ABCD           ; Push $ABCD

        ; Pull it back (high byte first since stack is LIFO, big-endian push)
        pla                     ; Low byte ($CD)
        sta     ZP_STORE16_LO
        pla                     ; High byte ($AB)
        sta     ZP_STORE16_HI

        sec
        xce                     ; Emulation mode

        lda     ZP_STORE16_LO
        cmp     #$CD
        bne     @t9fail
        lda     ZP_STORE16_HI
        cmp     #$AB
        bne     @t9fail

        lda     #1
        sta     ZP_TMP
        jmp     @t9done
@t9fail:
        lda     #0
        sta     ZP_TMP
@t9done:
        lda     #9
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 10: PEI — Push Effective Indirect (from direct page)
; ======================================================================
        jsr     write_test10_label

        ; Store known value at ZP
        lda     #$EF
        sta     ZP_STORE16_LO  ; $07 = $EF
        lda     #$BE
        sta     ZP_STORE16_HI  ; $08 = $BE
        ; So the 16-bit value at $07 is $BEEF

        clc
        xce                     ; Native mode

        pei     (ZP_STORE16_LO) ; Push 16-bit value from DP address $07 => pushes $BEEF

        ; Pull back
        pla                     ; Low byte ($EF)
        sta     ZP_PTR_LO
        pla                     ; High byte ($BE)
        sta     ZP_PTR_HI

        sec
        xce                     ; Emulation mode

        lda     ZP_PTR_LO
        cmp     #$EF
        bne     @t10fail
        lda     ZP_PTR_HI
        cmp     #$BE
        bne     @t10fail

        lda     #1
        sta     ZP_TMP
        jmp     @t10done
@t10fail:
        lda     #0
        sta     ZP_TMP
@t10done:
        lda     #10
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 11: PER — Push Effective Relative address
; ======================================================================
        jsr     write_test11_label

        clc
        xce                     ; Native mode

        ; PER pushes an effective address onto the stack (PC-relative)
        ; ca65 syntax: per <label> => pushes the address of the label
        ; The CPU computes: pushed_value = PC_after_PER + signed_offset
@per_target:
        per     @per_target     ; Push address of @per_target onto stack

        ; Pull it back to verify it matches the actual label address
        pla                     ; Low byte
        sta     ZP_STORE16_LO
        pla                     ; High byte
        sta     ZP_STORE16_HI

        sec
        xce                     ; Emulation mode

        ; The pushed value should be a reasonable code address (> $0801, < $D000)
        ; Just check high byte is in a reasonable range
        lda     ZP_STORE16_HI
        cmp     #$08            ; Should be >= $08 (we're in code space)
        bcc     @t11fail
        cmp     #$D0            ; Should be < $D0
        bcs     @t11fail

        lda     #1
        sta     ZP_TMP
        jmp     @t11done
@t11fail:
        lda     #0
        sta     ZP_TMP
@t11done:
        lda     #11
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 12: JSL/RTL — Long subroutine call
; ======================================================================
        jsr     write_test12_label

        lda     #0
        sta     ZP_TMP          ; Clear — subroutine will set to $42

        ; JSL jumps to a 24-bit address and pushes 24-bit return address
        jsl     long_sub        ; Call our long subroutine

        ; After return, ZP_TMP should be $42
        lda     ZP_TMP
        cmp     #$42
        bne     @t12fail

        lda     #1
        sta     ZP_TMP
        jmp     @t12done
@t12fail:
        lda     #0
        sta     ZP_TMP
@t12done:
        lda     #12
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 13: PHB/PLB — Data Bank Register
; ======================================================================
        jsr     write_test13_label

        clc
        xce                     ; Native mode

        ; Push current DBR (should be 0)
        phb
        pla                     ; Get DBR value
        sta     ZP_STORE16_LO  ; Save it (should be 0)

        ; Set DBR to $01
        lda     #$01
        pha
        plb                     ; DBR = $01

        ; Read back DBR
        phb
        pla
        sta     ZP_STORE16_HI  ; Should be $01

        ; Restore DBR to $00
        lda     #$00
        pha
        plb

        sec
        xce                     ; Emulation mode

        lda     ZP_STORE16_LO
        cmp     #$00
        bne     @t13fail
        lda     ZP_STORE16_HI
        cmp     #$01
        bne     @t13fail

        lda     #1
        sta     ZP_TMP
        jmp     @t13done
@t13fail:
        lda     #0
        sta     ZP_TMP
@t13done:
        lda     #13
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 14: 16-bit index registers (X/Y)
; ======================================================================
        jsr     write_test14_label

        clc
        xce                     ; Native mode
        rep     #$30            ; 16-bit A and X/Y
.a16
.i16
        ; Test 16-bit X
        ldx     #$0100          ; Value > 255 to prove 16-bit
        stx     ZP_STORE16_LO  ; Store at $07/$08

        ; Test 16-bit Y
        ldy     #$0200
        sty     ZP_PTR_LO      ; Store at $09/$0A

        ; Arithmetic on 16-bit index
        ldx     #$00FF
        inx                     ; Should wrap to $0100, not $00
        stx     ZP_DP_TEST      ; Store at $0B/$0C

        sep     #$30
.a8
.i8
        sec
        xce                     ; Emulation mode

        ; Verify X was 16-bit ($0100)
        lda     ZP_STORE16_LO
        cmp     #$00
        bne     @t14fail
        lda     ZP_STORE16_HI
        cmp     #$01
        bne     @t14fail

        ; Verify Y was 16-bit ($0200)
        lda     ZP_PTR_LO
        cmp     #$00
        bne     @t14fail
        lda     ZP_PTR_HI
        cmp     #$02
        bne     @t14fail

        ; Verify INX 16-bit ($0100)
        lda     ZP_DP_TEST
        cmp     #$00
        bne     @t14fail
        lda     ZP_DP_TEST2
        cmp     #$01
        bne     @t14fail

        lda     #1
        sta     ZP_TMP
        jmp     @t14done
@t14fail:
        lda     #0
        sta     ZP_TMP
@t14done:
        lda     #14
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; TEST 15: Mixed 8/16-bit mode switching
; ======================================================================
        jsr     write_test15_label

        clc
        xce                     ; Native mode

        ; Start 8-bit
        sep     #$30
.a8
.i8
        lda     #$FF
        ; Switch to 16-bit A only (X/Y stays 8-bit)
        rep     #$20
.a16
        ; A should now be $00FF (high byte zeroed on switch? No — preserved)
        ; Actually: REP only clears bits, doesn't change A value.
        ; A was $FF in 8-bit mode, when we go 16-bit, the full 16-bit A is revealed.
        ; The high byte (B accumulator) is whatever it was before.
        ; Let's set it explicitly first.

        ; Restart: set both bytes explicitly
        sep     #$20
.a8
        lda     #$AA            ; Low byte (C register)
        xba                     ; Exchange B and A: now B=$AA, A=?
        lda     #$55            ; A=$55 (C register)
        ; Now full 16-bit A = $AA55 (B:A)
        rep     #$20
.a16
        ; Full accumulator should be $AA55
        sta     ZP_STORE16_LO  ; $07=$55, $08=$AA

        ; Switch back to 8-bit
        sep     #$20
.a8
        ; A should be $55 (low byte)
        sta     ZP_PTR_LO

        ; XBA to get high byte
        xba
        sta     ZP_PTR_HI      ; Should be $AA

        sec
        xce                     ; Emulation mode

        ; Verify 16-bit store was $AA55
        lda     ZP_STORE16_LO
        cmp     #$55
        bne     @t15fail
        lda     ZP_STORE16_HI
        cmp     #$AA
        bne     @t15fail

        ; Verify 8-bit access was correct
        lda     ZP_PTR_LO
        cmp     #$55
        bne     @t15fail
        lda     ZP_PTR_HI
        cmp     #$AA
        bne     @t15fail

        lda     #1
        sta     ZP_TMP
        jmp     @t15done
@t15fail:
        lda     #0
        sta     ZP_TMP
@t15done:
        lda     #15
        sta     ZP_TESTNUM
        jsr     write_pass_fail

; ======================================================================
; Summary — color PASS/FAIL and loop forever
; ======================================================================

        ; Color pass/fail results
        ldx     #0              ; Test counter (0..14 = rows 2..16)
@color_loop:
        ; Calculate screen position: row = X + 2, col = 35
        txa
        clc
        adc     #2              ; row = test + 2
        ; Multiply by 40: A*40 = A*32 + A*8
        sta     ZP_TMP2         ; Save row
        asl     a               ; *2
        asl     a               ; *4
        asl     a               ; *8
        sta     ZP_PTR_LO      ; row*8
        lda     ZP_TMP2
        asl     a               ; *2
        asl     a               ; *4
        asl     a               ; *8
        asl     a               ; *16
        asl     a               ; *32
        clc
        adc     ZP_PTR_LO      ; *32 + *8 = *40
        ; Add 35 for column
        adc     #35
        sta     ZP_PTR_LO
        lda     #0
        adc     #>COLRAM
        sta     ZP_PTR_HI

        ; Read screen code at same offset in screen RAM
        lda     ZP_PTR_LO
        sec
        sbc     #<COLRAM
        clc
        adc     #<SCREEN
        sta     ZP_STORE16_LO
        lda     ZP_PTR_HI
        sbc     #>COLRAM
        adc     #>SCREEN
        sta     ZP_STORE16_HI

        ; Read the screen character
        ldy     #0
        lda     (ZP_STORE16_LO), y
        cmp     #SC_P           ; 'P' = pass
        bne     @set_red

        ; Green for PASS
        lda     #COL_GREEN
        jmp     @set_color
@set_red:
        lda     #COL_RED
@set_color:
        ; Write 4 bytes of color
        sta     (ZP_PTR_LO), y
        iny
        sta     (ZP_PTR_LO), y
        iny
        sta     (ZP_PTR_LO), y
        iny
        sta     (ZP_PTR_LO), y

        inx
        cpx     #15
        bne     @color_loop

        ; Write summary
        ldx     #0
@sum:   lda     summary_str, x
        beq     @sumdone
        sta     SCREEN + 18 * ROW + 1, x
        inx
        bne     @sum
@sumdone:

        ; Count passes
        lda     #0
        sta     ZP_TMP          ; Pass count
        ldx     #0
@count: txa
        clc
        adc     #2
        ; Calculate row*40+35 offset from SCREEN
        sta     ZP_TMP2
        asl     a
        asl     a
        asl     a
        sta     ZP_PTR_LO
        lda     ZP_TMP2
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        clc
        adc     ZP_PTR_LO
        adc     #35
        tay
        lda     SCREEN, y       ; Read screen code
        cmp     #SC_P
        bne     @notpass
        inc     ZP_TMP
@notpass:
        inx
        cpx     #15
        bne     @count

        ; Display pass count as "NN/15"
        lda     ZP_TMP
        jsr     write_decimal_2digit
        ; A already consumed, result on screen at row 18

        ; Ensure turbo is on
        sta     SCPU_07B

        ; Infinite loop
@halt:  jmp     @halt


; ======================================================================
; Subroutines
; ======================================================================

; Long subroutine called by JSL (test 12)
; Must return with RTL
long_sub:
        lda     #$42
        sta     ZP_TMP
        rtl


; Write PASS or FAIL based on ZP_TMP (0=fail, nonzero=pass)
; ZP_TESTNUM = test number (1-based)
write_pass_fail:
        ; Calculate screen row: testnum + 1 (test 1 = row 2, etc.)
        lda     ZP_TESTNUM
        clc
        adc     #1
        ; Row * 40
        sta     ZP_TMP2
        asl     a
        asl     a
        asl     a
        sta     ZP_PTR_LO
        lda     ZP_TMP2
        asl     a
        asl     a
        asl     a
        asl     a
        asl     a
        clc
        adc     ZP_PTR_LO
        ; Add column 35
        adc     #35
        sta     ZP_PTR_LO
        lda     #0
        adc     #>SCREEN
        sta     ZP_PTR_HI

        lda     ZP_TMP
        beq     @fail

        ; PASS
        ldy     #0
        lda     #SC_P           ; P
        sta     (ZP_PTR_LO), y
        iny
        lda     #SC_A           ; A
        sta     (ZP_PTR_LO), y
        iny
        lda     #SC_S           ; S
        sta     (ZP_PTR_LO), y
        iny
        lda     #SC_S           ; S
        sta     (ZP_PTR_LO), y
        rts

@fail:
        ; FAIL
        ldy     #0
        lda     #SC_F           ; F
        sta     (ZP_PTR_LO), y
        iny
        lda     #SC_A           ; A
        sta     (ZP_PTR_LO), y
        iny
        lda     #SC_I           ; I
        sta     (ZP_PTR_LO), y
        iny
        lda     #SC_L           ; L
        sta     (ZP_PTR_LO), y
        rts


; Write a 2-digit decimal number to screen at row 18, column 10
; Input: A = value (0-99)
write_decimal_2digit:
        ldx     #0              ; Tens digit
@tens:  cmp     #10
        bcc     @ones
        sbc     #10
        inx
        jmp     @tens
@ones:  pha                     ; Save ones
        txa
        clc
        adc     #48             ; '0' screen code
        sta     SCREEN + 18 * ROW + 10
        pla
        clc
        adc     #48             ; '0' screen code
        sta     SCREEN + 18 * ROW + 11
        ; Write "/15"
        lda     #47             ; '/' screen code
        sta     SCREEN + 18 * ROW + 12
        lda     #49             ; '1'
        sta     SCREEN + 18 * ROW + 13
        lda     #53             ; '5'
        sta     SCREEN + 18 * ROW + 14
        rts


; ---- Label-writing subroutines for each test ----
; These write the test description to screen RAM

.macro write_label row, straddr
        ldx     #0
:       lda     straddr, x
        beq     :+
        sta     SCREEN + row * ROW + 1, x
        inx
        bne     :-
:
.endmacro

write_test1_label:
        write_label 2, t1_str
        rts
write_test2_label:
        write_label 3, t2_str
        rts
write_test3_label:
        write_label 4, t3_str
        rts
write_test4_label:
        write_label 5, t4_str
        rts
write_test5_label:
        write_label 6, t5_str
        rts
write_test6_label:
        write_label 7, t6_str
        rts
write_test7_label:
        write_label 8, t7_str
        rts
write_test8_label:
        write_label 9, t8_str
        rts
write_test9_label:
        write_label 10, t9_str
        rts
write_test10_label:
        write_label 11, t10_str
        rts
write_test11_label:
        write_label 12, t11_str
        rts
write_test12_label:
        write_label 13, t12_str
        rts
write_test13_label:
        write_label 14, t13_str
        rts
write_test14_label:
        write_label 15, t14_str
        rts
write_test15_label:
        write_label 16, t15_str
        rts


; ======================================================================
; String Data (screen codes, null-terminated)
; ======================================================================
.segment "RODATA"

; Screen code helper: A=1, B=2, ... Z=26, 0-9=48-57, space=32
; Conversion: uppercase letter = letter_value - 64
; Digits: same as ASCII

title_str:
        ;       "65816 NATIVE MODE TEST"
        .byte   54+6, 53+6     ; '6','5' — NO, screen codes for digits are same as ASCII
        ; Let me use actual screen codes:
        ; '6'=54, '5'=53, '8'=56, '1'=49, '6'=54, ' '=32
        ; 'N'=14, 'A'=1, 'T'=20, 'I'=9, 'V'=22, 'E'=5
        ; ' '=32, 'M'=13, 'O'=15, 'D'=4, 'E'=5
        ; ' '=32, 'T'=20, 'E'=5, 'S'=19, 'T'=20
        .byte   54, 53, 56, 49, 54, 32
        .byte   14, 1, 20, 9, 22, 5
        .byte   32, 13, 15, 4, 5
        .byte   32, 20, 5, 19, 20
        .byte   0

t1_str: ; "1  CLC/XCE NATIVE ENTER"
        .byte   49, 32, 32
        .byte   3, 12, 3, 47, 24, 3, 5       ; CLC/XCE
        .byte   32, 14, 1, 20, 9, 22, 5      ; NATIVE
        .byte   32, 5, 14, 20, 5, 18         ; ENTER
        .byte   0

t2_str: ; "2  REP #$30 16BIT A/XY"
        .byte   50, 32, 32
        .byte   18, 5, 16                    ; REP
        .byte   32, 35, 36                   ; #$
        .byte   51, 48                       ; 30
        .byte   32, 49, 54                   ; 16
        .byte   2, 9, 20                     ; BIT
        .byte   32, 1, 47, 24, 25            ; A/XY
        .byte   0

t3_str: ; "3  16BIT ADC"
        .byte   51, 32, 32
        .byte   49, 54, 2, 9, 20             ; 16BIT
        .byte   32, 1, 4, 3                  ; ADC
        .byte   0

t4_str: ; "4  16BIT SBC"
        .byte   52, 32, 32
        .byte   49, 54, 2, 9, 20             ; 16BIT
        .byte   32, 19, 2, 3                 ; SBC
        .byte   0

t5_str: ; "5  DIRECT PAGE TCD"
        .byte   53, 32, 32
        .byte   4, 9, 18, 5, 3, 20           ; DIRECT
        .byte   32, 16, 1, 7, 5              ; PAGE
        .byte   32, 20, 3, 4                 ; TCD
        .byte   0

t6_str: ; "6  STACK RELOC TCS"
        .byte   54, 32, 32
        .byte   19, 20, 1, 3, 11             ; STACK
        .byte   32, 18, 5, 12, 15, 3         ; RELOC
        .byte   32, 20, 3, 19                ; TCS
        .byte   0

t7_str: ; "7  BLOCK MOVE MVN"
        .byte   55, 32, 32
        .byte   2, 12, 15, 3, 11             ; BLOCK
        .byte   32, 13, 15, 22, 5            ; MOVE
        .byte   32, 13, 22, 14               ; MVN
        .byte   0

t8_str: ; "8  BLOCK MOVE MVP"
        .byte   56, 32, 32
        .byte   2, 12, 15, 3, 11             ; BLOCK
        .byte   32, 13, 15, 22, 5            ; MOVE
        .byte   32, 13, 22, 16               ; MVP
        .byte   0

t9_str: ; "9  PEA STACK PUSH"
        .byte   57, 32, 32
        .byte   16, 5, 1                     ; PEA
        .byte   32, 19, 20, 1, 3, 11         ; STACK
        .byte   32, 16, 21, 19, 8            ; PUSH
        .byte   0

t10_str: ; "10 PEI INDIRECT"
        .byte   49, 48, 32
        .byte   16, 5, 9                     ; PEI
        .byte   32, 9, 14, 4, 9, 18, 5, 3, 20  ; INDIRECT
        .byte   0

t11_str: ; "11 PER RELATIVE"
        .byte   49, 49, 32
        .byte   16, 5, 18                    ; PER
        .byte   32, 18, 5, 12, 1, 20, 9, 22, 5 ; RELATIVE
        .byte   0

t12_str: ; "12 JSL/RTL LONG CALL"
        .byte   49, 50, 32
        .byte   10, 19, 12, 47, 18, 20, 12   ; JSL/RTL
        .byte   32, 12, 15, 14, 7            ; LONG
        .byte   32, 3, 1, 12, 12             ; CALL
        .byte   0

t13_str: ; "13 PHB/PLB DATA BANK"
        .byte   49, 51, 32
        .byte   16, 8, 2, 47, 16, 12, 2      ; PHB/PLB
        .byte   32, 4, 1, 20, 1              ; DATA
        .byte   32, 2, 1, 14, 11             ; BANK
        .byte   0

t14_str: ; "14 16BIT X/Y INDEX"
        .byte   49, 52, 32
        .byte   49, 54, 2, 9, 20             ; 16BIT
        .byte   32, 24, 47, 25               ; X/Y
        .byte   32, 9, 14, 4, 5, 24          ; INDEX
        .byte   0

t15_str: ; "15 8/16 MODE SWITCH"
        .byte   49, 53, 32
        .byte   56, 47, 49, 54               ; 8/16
        .byte   32, 13, 15, 4, 5             ; MODE
        .byte   32, 19, 23, 9, 20, 3, 8      ; SWITCH
        .byte   0

summary_str:
        ; "PASSED: "
        .byte   16, 1, 19, 19, 5, 4, 58, 32  ; PASSED:_
        .byte   32                            ; extra space
        .byte   0
