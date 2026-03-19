; scpu_superram_test.s — Test SuperRAM bank access via 65816 24-bit addressing
;
; Tests:
; 1. Write pattern to bank $01 via long STA, read back via long LDA
; 2. Write different pattern to bank $02, verify bank $01 unchanged
; 3. Block move MVN between bank $00 and bank $01
; 4. Sequential write/read across multiple banks ($01-$08)
;
; Build:
;   ca65 --cpu 65816 -o out/scpu_superram_test.o scpu_superram_test.s
;   ld65 -C c64-816.cfg -o out/scpu_superram_test.prg out/scpu_superram_test.o

.p816
.smart

; ── Segments ─────────────────────────────────────────
.segment "LOADADDR"
    .word $0801

.segment "EXEHDR"
BasicStub:
    .word @end
    .word 10
    .byte $9E
    .byte "2064"
    .byte 0
@end:
    .word 0

.segment "CODE"

SCREEN = $0400
COLOR  = $D800
ROW    = 40

; PETSCII screen codes
SC_S = 19
SC_U = 21
SC_P = 16
SC_E = 5
SC_R = 18
SC_A = 1
SC_M = 13
SC_T = 20
SC_I = 9
SC_B = 2
SC_K = 11
SC_W = 23
SC_N = 14
SC_D = 4
SC_V = 22
SC_O = 15
SC_L = 12
SC_F = 6
SC_0 = 48
SC_1 = 49
SC_2 = 50
SC_3 = 51
SC_4 = 52
SC_SPACE = 32
SC_COLON = 58
SC_DASH  = 45
SC_DOT   = 46
SC_PASS  = 16  ; 'P'
SC_FAIL  = 6   ; 'F'

; ZP variables (use $F0+ to avoid BASIC conflicts)
zp_tmp    = $F0
zp_tmp2   = $F1
zp_result = $F2    ; bit field: bit N = test N passed
zp_pass   = $F3    ; pass count

start:
    sei
    cld

    ; Clear result
    lda #0
    sta zp_result
    sta zp_pass

    ; Set screen colors
    lda #$00
    sta $D021       ; black background
    lda #$06
    sta $D020       ; blue border

    ; Clear screen
    ldx #0
@clr:
    lda #SC_SPACE
    sta SCREEN,x
    sta SCREEN+256,x
    sta SCREEN+512,x
    sta SCREEN+768,x
    lda #$01        ; white text
    sta COLOR,x
    sta COLOR+256,x
    sta COLOR+512,x
    sta COLOR+768,x
    inx
    bne @clr

    ; Title: "SUPERRAM BANK TEST"
    lda #SC_S
    sta SCREEN+0*ROW+11
    lda #SC_U
    sta SCREEN+0*ROW+12
    lda #SC_P
    sta SCREEN+0*ROW+13
    lda #SC_E
    sta SCREEN+0*ROW+14
    lda #SC_R
    sta SCREEN+0*ROW+15
    lda #SC_R
    sta SCREEN+0*ROW+16
    lda #SC_A
    sta SCREEN+0*ROW+17
    lda #SC_M
    sta SCREEN+0*ROW+18
    lda #SC_SPACE
    sta SCREEN+0*ROW+19
    lda #SC_B
    sta SCREEN+0*ROW+20
    lda #SC_A
    sta SCREEN+0*ROW+21
    lda #SC_N
    sta SCREEN+0*ROW+22
    lda #SC_K
    sta SCREEN+0*ROW+23
    lda #SC_SPACE
    sta SCREEN+0*ROW+24
    lda #SC_T
    sta SCREEN+0*ROW+25
    lda #SC_E
    sta SCREEN+0*ROW+26
    lda #SC_S
    sta SCREEN+0*ROW+27
    lda #SC_T
    sta SCREEN+0*ROW+28

    ; Color title yellow
    ldx #18
@coltitle:
    lda #$07
    sta COLOR+0*ROW+11,x
    dex
    bpl @coltitle

    ; ── Label row 2: "1 BANK 01 WRITE/READ" ──
    lda #SC_1
    sta SCREEN+2*ROW+1
    lda #SC_B
    sta SCREEN+2*ROW+3
    lda #SC_A
    sta SCREEN+2*ROW+4
    lda #SC_N
    sta SCREEN+2*ROW+5
    lda #SC_K
    sta SCREEN+2*ROW+6
    lda #SC_SPACE
    sta SCREEN+2*ROW+7
    lda #SC_0
    sta SCREEN+2*ROW+8
    lda #SC_1
    sta SCREEN+2*ROW+9

    ; ═══════════════════════════════════════════════════
    ; TEST 1: Write $A5 to bank $01 address $4000, read back
    ; ═══════════════════════════════════════════════════
    clc
    xce                 ; enter native mode
    .a8
    .i8

    ; Write $A5 to $01:4000 using long addressing
    lda #$A5
    sta $014000         ; STA long — bank $01, address $4000

    ; Read it back
    lda $014000         ; LDA long — should return $A5
    cmp #$A5

    sec
    xce                 ; back to emulation
    .a8
    .i8

    bne @t1_fail
    lda #1
    sta zp_tmp
    jmp @t1_show
@t1_fail:
    lda #0
    sta zp_tmp
@t1_show:
    ; Show PASS/FAIL at column 35
    lda zp_tmp
    beq @t1_showfail
    lda #SC_P           ; 'P'
    sta SCREEN+2*ROW+35
    lda #SC_A
    sta SCREEN+2*ROW+36
    lda #SC_S
    sta SCREEN+2*ROW+37
    lda #SC_S
    sta SCREEN+2*ROW+38
    ; Green color
    lda #$05
    sta COLOR+2*ROW+35
    sta COLOR+2*ROW+36
    sta COLOR+2*ROW+37
    sta COLOR+2*ROW+38
    inc zp_pass
    lda zp_result
    ora #$01
    sta zp_result
    jmp @t2_start
@t1_showfail:
    lda #SC_F
    sta SCREEN+2*ROW+35
    lda #SC_A
    sta SCREEN+2*ROW+36
    lda #SC_I
    sta SCREEN+2*ROW+37
    lda #SC_L
    sta SCREEN+2*ROW+38
    lda #$02            ; red
    sta COLOR+2*ROW+35
    sta COLOR+2*ROW+36
    sta COLOR+2*ROW+37
    sta COLOR+2*ROW+38

    ; ═══════════════════════════════════════════════════
    ; TEST 2: Write $5A to bank $02, verify bank $01 unchanged
    ; ═══════════════════════════════════════════════════
@t2_start:
    ; Label: "2 BANK ISOLATION"
    lda #SC_2
    sta SCREEN+3*ROW+1
    lda #SC_B
    sta SCREEN+3*ROW+3
    lda #SC_A
    sta SCREEN+3*ROW+4
    lda #SC_N
    sta SCREEN+3*ROW+5
    lda #SC_K
    sta SCREEN+3*ROW+6
    lda #SC_SPACE
    sta SCREEN+3*ROW+7
    lda #SC_I
    sta SCREEN+3*ROW+8
    lda #SC_S
    sta SCREEN+3*ROW+9
    lda #SC_O
    sta SCREEN+3*ROW+10
    lda #SC_L
    sta SCREEN+3*ROW+11

    clc
    xce                 ; native mode
    .a8
    .i8

    ; Write $5A to bank $02
    lda #$5A
    sta $024000

    ; Verify bank $01 still has $A5
    lda $014000
    cmp #$A5
    bne @t2_failn
    ; Verify bank $02 has $5A
    lda $024000
    cmp #$5A

@t2_failn:
    sec
    xce                 ; back to emulation
    .a8
    .i8

    bne @t2_fail
    lda #1
    sta zp_tmp
    jmp @t2_show
@t2_fail:
    lda #0
    sta zp_tmp
@t2_show:
    lda zp_tmp
    beq @t2_showfail
    lda #SC_P
    sta SCREEN+3*ROW+35
    lda #SC_A
    sta SCREEN+3*ROW+36
    lda #SC_S
    sta SCREEN+3*ROW+37
    lda #SC_S
    sta SCREEN+3*ROW+38
    lda #$05
    sta COLOR+3*ROW+35
    sta COLOR+3*ROW+36
    sta COLOR+3*ROW+37
    sta COLOR+3*ROW+38
    inc zp_pass
    lda zp_result
    ora #$02
    sta zp_result
    jmp @t3_start
@t2_showfail:
    lda #SC_F
    sta SCREEN+3*ROW+35
    lda #SC_A
    sta SCREEN+3*ROW+36
    lda #SC_I
    sta SCREEN+3*ROW+37
    lda #SC_L
    sta SCREEN+3*ROW+38
    lda #$02
    sta COLOR+3*ROW+35
    sta COLOR+3*ROW+36
    sta COLOR+3*ROW+37
    sta COLOR+3*ROW+38

    ; ═══════════════════════════════════════════════════
    ; TEST 3: Multi-bank sequential ($01-$08)
    ; ═══════════════════════════════════════════════════
@t3_start:
    lda #SC_3
    sta SCREEN+4*ROW+1
    lda #SC_M
    sta SCREEN+4*ROW+3
    lda #SC_U
    sta SCREEN+4*ROW+4
    lda #SC_L
    sta SCREEN+4*ROW+5
    lda #SC_T
    sta SCREEN+4*ROW+6
    lda #SC_I
    sta SCREEN+4*ROW+7
    lda #SC_DASH
    sta SCREEN+4*ROW+8
    lda #SC_B
    sta SCREEN+4*ROW+9
    lda #SC_A
    sta SCREEN+4*ROW+10
    lda #SC_N
    sta SCREEN+4*ROW+11
    lda #SC_K
    sta SCREEN+4*ROW+12

    clc
    xce                 ; native
    .a8
    .i8

    ; Write bank number as pattern to each bank $01-$08 at $5000
    lda #$01
    sta $015000
    lda #$02
    sta $025000
    lda #$03
    sta $035000
    lda #$04
    sta $045000
    lda #$05
    sta $055000
    lda #$06
    sta $065000
    lda #$07
    sta $075000
    lda #$08
    sta $085000

    ; Read back and verify all 8 banks
    lda $015000
    cmp #$01
    bne @t3_failn
    lda $025000
    cmp #$02
    bne @t3_failn
    lda $035000
    cmp #$03
    bne @t3_failn
    lda $045000
    cmp #$04
    bne @t3_failn
    lda $055000
    cmp #$05
    bne @t3_failn
    lda $065000
    cmp #$06
    bne @t3_failn
    lda $075000
    cmp #$07
    bne @t3_failn
    lda $085000
    cmp #$08

@t3_failn:
    sec
    xce
    .a8
    .i8

    bne @t3_fail
    lda #1
    sta zp_tmp
    jmp @t3_show
@t3_fail:
    lda #0
    sta zp_tmp
@t3_show:
    lda zp_tmp
    beq @t3_showfail
    lda #SC_P
    sta SCREEN+4*ROW+35
    lda #SC_A
    sta SCREEN+4*ROW+36
    lda #SC_S
    sta SCREEN+4*ROW+37
    lda #SC_S
    sta SCREEN+4*ROW+38
    lda #$05
    sta COLOR+4*ROW+35
    sta COLOR+4*ROW+36
    sta COLOR+4*ROW+37
    sta COLOR+4*ROW+38
    inc zp_pass
    lda zp_result
    ora #$04
    sta zp_result
    jmp @done
@t3_showfail:
    lda #SC_F
    sta SCREEN+4*ROW+35
    lda #SC_A
    sta SCREEN+4*ROW+36
    lda #SC_I
    sta SCREEN+4*ROW+37
    lda #SC_L
    sta SCREEN+4*ROW+38
    lda #$02
    sta COLOR+4*ROW+35
    sta COLOR+4*ROW+36
    sta COLOR+4*ROW+37
    sta COLOR+4*ROW+38

@done:
    ; Show pass count
    lda #SC_R
    sta SCREEN+6*ROW+1
    lda #SC_E
    sta SCREEN+6*ROW+2
    lda #SC_S
    sta SCREEN+6*ROW+3
    lda #SC_U
    sta SCREEN+6*ROW+4
    lda #SC_L
    sta SCREEN+6*ROW+5
    lda #SC_T
    sta SCREEN+6*ROW+6
    lda #SC_COLON
    sta SCREEN+6*ROW+7
    lda zp_pass
    clc
    adc #48             ; convert to screen code digit
    sta SCREEN+6*ROW+9
    lda #47             ; '/'
    sta SCREEN+6*ROW+10
    lda #SC_3
    sta SCREEN+6*ROW+11

    ; Ensure turbo on
    sta $D07B

    ; Infinite loop
@halt:
    jmp @halt
