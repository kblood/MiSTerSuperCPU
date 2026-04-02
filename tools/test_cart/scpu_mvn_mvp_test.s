; scpu_mvn_mvp_test.s — Test MVN/MVP block move instructions + REU cross-path
;
; Tests:
; 1. MVN: copy 16 bytes within bank $00 (forward)
; 2. MVP: copy 16 bytes within bank $00 (backward)
; 3. MVN: copy 16 bytes from bank $00 to bank $02 (SuperRAM)
; 4. MVN: copy 16 bytes from bank $02 back to bank $00
; 5. REU STASH $55 to addr $020100, then LDA long $02:$0100, compare
; 6. STA long from bank $02 code to bank $00 target
;
; Build:
;   ca65 --cpu 65816 -o out/scpu_mvn_mvp_test.o scpu_mvn_mvp_test.s
;   ld65 -C c64-816.cfg -o out/scpu_mvn_mvp_test.prg out/scpu_mvn_mvp_test.o

.p816
.smart

.segment "LOADADDR"
    .word $0801

.segment "EXEHDR"
BasicStub:
    .word @end
    .word 10
    .byte $9E
    .byte "2061"
    .byte 0
@end:
    .word 0

.segment "CODE"

SCREEN = $0400
COLOR  = $D800
ROW    = 40

; Screen codes
SC_SPACE = 32
SC_COLON = 58
SC_DASH  = 45
SC_SLASH = 47
SC_0     = 48
SC_1     = 49
SC_2     = 50
SC_3     = 51
SC_4     = 52
SC_5     = 53
SC_6     = 54
SC_A     = 1
SC_B     = 2
SC_C     = 3
SC_D     = 4
SC_E     = 5
SC_F     = 6
SC_I     = 9
SC_K     = 11
SC_L     = 12
SC_M     = 13
SC_N     = 14
SC_O     = 15
SC_P     = 16
SC_R     = 18
SC_S     = 19
SC_T     = 20
SC_U     = 21
SC_V     = 22
SC_W     = 23
SC_X     = 24

; ZP
zp_pass    = $F0
zp_total   = $F1
zp_tmp     = $F2
zp_bank    = $F3     ; saved bank byte
zp_ptr     = $FA     ; 16-bit pointer for screen writes (FA-FB)

; Test data area in bank $00
SRC_AREA   = $5000   ; source data for block moves
DST_AREA   = $5100   ; destination for block moves
DST_AREA2  = $5200   ; second destination
VERIFY_AREA = $5300  ; for SuperRAM readback

; SuperRAM target
SRAM_BANK  = $02
SRAM_ADDR  = $2000

; REU registers
REU_STATUS = $DF00
REU_CMD    = $DF01
REU_C64LO  = $DF02
REU_C64HI  = $DF03
REU_RAMLO  = $DF04
REU_RAMMI  = $DF05
REU_RAMHI  = $DF06
REU_LENLO  = $DF07
REU_LENHI  = $DF08

start:
    sei
    cld

    ; Init
    lda #0
    sta zp_pass
    lda #6
    sta zp_total

    ; Colors
    lda #$00
    sta $D021
    lda #$06
    sta $D020

    ; Clear screen
    ldx #0
@clr:
    lda #SC_SPACE
    sta SCREEN,x
    sta SCREEN+256,x
    sta SCREEN+512,x
    sta SCREEN+768,x
    lda #$01
    sta COLOR,x
    sta COLOR+256,x
    sta COLOR+512,x
    sta COLOR+768,x
    inx
    bne @clr

    ; Title: "MVN/MVP TEST"
    ldx #0
@title_loop:
    lda title_text,x
    beq @title_done
    sta SCREEN+12,x
    lda #$07
    sta COLOR+12,x
    inx
    bne @title_loop
@title_done:

    ; ═══════════════════════════════════════════
    ; TEST 1: MVN within bank $00 (forward copy)
    ; ═══════════════════════════════════════════
    ; Label
    ldx #0
@t1_lbl:
    lda t1_text,x
    beq @t1_lbl_done
    sta SCREEN+2*ROW+1,x
    inx
    bne @t1_lbl
@t1_lbl_done:

    ; Fill source with pattern $A0+i
    ldx #15
@t1_fill:
    txa
    clc
    adc #$A0
    sta SRC_AREA,x
    dex
    bpl @t1_fill

    ; Clear destination
    ldx #15
    lda #$00
@t1_clr:
    sta DST_AREA,x
    dex
    bpl @t1_clr

    ; Enter native mode, 16-bit index
    clc
    xce
    .a8
    .i8
    rep #$10         ; 16-bit X/Y
    .i16

    ; MVN: copy 16 bytes from $00:SRC_AREA to $00:DST_AREA
    ; C = length - 1 = 15
    ; X = source start, Y = dest start
    ldx #SRC_AREA
    ldy #DST_AREA
    lda #15          ; 8-bit A = count-1 low byte... wait, C register
    ; Actually need 16-bit C for block move count
    sep #$20         ; keep A 8-bit for now
    .a8
    ; MVN uses C register (16-bit accumulator). Set A to 16-bit for count.
    rep #$20
    .a16
    lda #15          ; C = 15 means copy 16 bytes
    mvn $00, $00     ; MVN dst_bank, src_bank

    ; Back to emulation
    sep #$30
    .a8
    .i8
    sec
    xce

    ; Verify
    ldx #15
@t1_chk:
    lda DST_AREA,x
    sta zp_tmp
    txa
    clc
    adc #$A0
    cmp zp_tmp
    bne @t1_fail
    dex
    bpl @t1_chk

    ; PASS
    lda #<(SCREEN+2*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+2*ROW+35)
    sta zp_ptr+1
    jsr show_pass_at
    inc zp_pass
    jmp @t2_start

@t1_fail:
    lda #<(SCREEN+2*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+2*ROW+35)
    sta zp_ptr+1
    jsr show_fail_at

    ; ═══════════════════════════════════════════
    ; TEST 2: MVP within bank $00 (backward copy)
    ; ═══════════════════════════════════════════
@t2_start:
    ldx #0
@t2_lbl:
    lda t2_text,x
    beq @t2_lbl_done
    sta SCREEN+3*ROW+1,x
    inx
    bne @t2_lbl
@t2_lbl_done:

    ; Clear DST_AREA2
    ldx #15
    lda #$00
@t2_clr:
    sta DST_AREA2,x
    dex
    bpl @t2_clr

    ; Enter native mode
    clc
    xce
    .a8
    .i8
    rep #$30         ; 16-bit A and X/Y
    .a16
    .i16

    ; MVP: backward copy 16 bytes from $00:SRC_AREA to $00:DST_AREA2
    ; For MVP: X = source END, Y = dest END
    ldx #(SRC_AREA + 15)
    ldy #(DST_AREA2 + 15)
    lda #15
    mvp $00, $00     ; MVP dst_bank, src_bank

    ; Back to emulation
    sep #$30
    .a8
    .i8
    sec
    xce

    ; Verify
    ldx #15
@t2_chk:
    lda DST_AREA2,x
    sta zp_tmp
    txa
    clc
    adc #$A0
    cmp zp_tmp
    bne @t2_fail
    dex
    bpl @t2_chk

    lda #<(SCREEN+3*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+3*ROW+35)
    sta zp_ptr+1
    jsr show_pass_at
    inc zp_pass
    jmp @t3_start

@t2_fail:
    lda #<(SCREEN+3*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+3*ROW+35)
    sta zp_ptr+1
    jsr show_fail_at

    ; ═══════════════════════════════════════════
    ; TEST 3: MVN bank $00 → bank $02 (SuperRAM)
    ; ═══════════════════════════════════════════
@t3_start:
    ldx #0
@t3_lbl:
    lda t3_text,x
    beq @t3_lbl_done
    sta SCREEN+4*ROW+1,x
    inx
    bne @t3_lbl
@t3_lbl_done:

    ; Show ">" indicator before MVN starts
    lda #62              ; '>' screen code
    sta SCREEN+4*ROW+38

    ; Enter native mode
    clc
    xce
    .a8
    .i8
    rep #$30
    .a16
    .i16

    ; MVN: copy 16 bytes from $00:SRC_AREA to $02:SRAM_ADDR
    ldx #SRC_AREA
    ldy #SRAM_ADDR
    lda #15
    mvn SRAM_BANK, $00   ; dst=bank $02, src=bank $00

    ; Show "<" indicator after MVN completes
    sep #$20
    .a8
    lda #60              ; '<' screen code
    sta $00 + SCREEN+4*ROW+39
    ; Read first byte from $02:SRAM_ADDR
    lda $020000 + SRAM_ADDR
    sta $00 + zp_tmp

    ; Back to emulation
    sep #$10
    .i8
    sec
    xce

    ; Check first byte
    lda zp_tmp
    cmp #$A0            ; first byte of pattern
    bne @t3_fail

    ; Check more bytes using LDA long in native mode
    clc
    xce
    .a8
    .i8

    lda $020000 + SRAM_ADDR + 1
    cmp #$A1
    bne @t3_fail_n
    lda $020000 + SRAM_ADDR + 15
    cmp #$AF
    bne @t3_fail_n

    sec
    xce

    lda #<(SCREEN+4*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+4*ROW+35)
    sta zp_ptr+1
    jsr show_pass_at
    inc zp_pass
    jmp @t4_start

@t3_fail_n:
    sec
    xce
@t3_fail:
    lda #<(SCREEN+4*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+4*ROW+35)
    sta zp_ptr+1
    jsr show_fail_at

    ; ═══════════════════════════════════════════
    ; TEST 4: MVN bank $02 → bank $00 (readback)
    ; ═══════════════════════════════════════════
@t4_start:
    ldx #0
@t4_lbl:
    lda t4_text,x
    beq @t4_lbl_done
    sta SCREEN+5*ROW+1,x
    inx
    bne @t4_lbl
@t4_lbl_done:

    ; Clear verify area
    ldx #15
    lda #$00
@t4_clr:
    sta VERIFY_AREA,x
    dex
    bpl @t4_clr

    ; Enter native mode
    clc
    xce
    .a8
    .i8
    rep #$30
    .a16
    .i16

    ; MVN: copy 16 bytes from $02:SRAM_ADDR to $00:VERIFY_AREA
    ldx #SRAM_ADDR
    ldy #VERIFY_AREA
    lda #15
    mvn $00, SRAM_BANK   ; dst=bank $00, src=bank $02

    ; Back to emulation
    sep #$30
    .a8
    .i8
    sec
    xce

    ; Verify
    ldx #15
@t4_chk:
    lda VERIFY_AREA,x
    sta zp_tmp
    txa
    clc
    adc #$A0
    cmp zp_tmp
    bne @t4_fail
    dex
    bpl @t4_chk

    lda #<(SCREEN+5*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+5*ROW+35)
    sta zp_ptr+1
    jsr show_pass_at
    inc zp_pass
    jmp @t5_start

@t4_fail:
    lda #<(SCREEN+5*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+5*ROW+35)
    sta zp_ptr+1
    jsr show_fail_at

    ; ═══════════════════════════════════════════
    ; TEST 5: REU cross-path — STASH $55, LDA long verify
    ; STASH to REU addr $020100 (= bank $02, addr $0100)
    ; Then LDA long $02:$0100 should return $55
    ; ═══════════════════════════════════════════
@t5_start:
    ldx #0
@t5_lbl:
    lda t5_text,x
    beq @t5_lbl_done
    sta SCREEN+6*ROW+1,x
    inx
    bne @t5_lbl
@t5_lbl_done:

    ; Write $55 to a temp location in bank $00
    lda #$55
    sta SRC_AREA

    ; Setup REU STASH: C64 addr = SRC_AREA, REU addr = $020100, length = 1
    lda #<SRC_AREA
    sta REU_C64LO
    lda #>SRC_AREA
    sta REU_C64HI
    lda #$00          ; REU addr low = $00
    sta REU_RAMLO
    lda #$01          ; REU addr mid = $01
    sta REU_RAMMI
    lda #$02          ; REU addr high = $02
    sta REU_RAMHI
    lda #$01          ; length = 1
    sta REU_LENLO
    lda #$00
    sta REU_LENHI

    ; Execute STASH (cmd $90 = STASH with autostart)
    lda #$90
    sta REU_CMD

    ; Small delay for DMA to complete
    ldx #$20
@t5_dly:
    dex
    bne @t5_dly

    ; Now read back via LDA long $02:$0100
    clc
    xce
    .a8
    .i8

    lda $020100        ; LDA long — should return $55

    sec
    xce

    cmp #$55
    bne @t5_fail

    lda #<(SCREEN+6*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+6*ROW+35)
    sta zp_ptr+1
    jsr show_pass_at
    inc zp_pass
    jmp @t6_start

@t5_fail:
    ; Show what we got instead (hex at col 30)
    pha
    lda #<(SCREEN+6*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+6*ROW+35)
    sta zp_ptr+1
    jsr show_fail_at
    pla
    ; Display hex value of what we read
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hex_chars,x
    sta SCREEN+6*ROW+30
    pla
    and #$0F
    tax
    lda hex_chars,x
    sta SCREEN+6*ROW+31

    ; ═══════════════════════════════════════════
    ; TEST 6: STA abs from SuperRAM code to bank $00
    ; Write routine to SuperRAM, JML there, routine
    ; does STA $5400 (bank $00), JML back, verify
    ; ═══════════════════════════════════════════
@t6_start:
    ldx #0
@t6_lbl:
    lda t6_text,x
    beq @t6_lbl_done
    sta SCREEN+7*ROW+1,x
    inx
    bne @t6_lbl
@t6_lbl_done:

    ; Clear target
    lda #$00
    sta $5400

    ; Write routine to $02:$3000 using STA long
    ; Routine:
    ;   LDA #$42           A9 42
    ;   STA $5400          8D 00 54     (absolute — uses DBR, which should be $00)
    ;   SEC                38
    ;   XCE                FB
    ;   JML $00:return     5C lo hi 00
    ; Total: 10 bytes

    clc
    xce
    .a8
    .i8

    lda #$A9             ; LDA #imm opcode
    sta $023000
    lda #$42             ; immediate value
    sta $023001
    lda #$8D             ; STA abs opcode
    sta $023002
    lda #$00             ; addr low
    sta $023003
    lda #$54             ; addr high
    sta $023004
    lda #$38             ; SEC
    sta $023005
    lda #$FB             ; XCE
    sta $023006
    lda #$5C             ; JML
    sta $023007
    lda #<@t6_return     ; return addr low
    sta $023008
    lda #>@t6_return     ; return addr high
    sta $023009
    lda #$00             ; bank $00
    sta $02300A

    ; Set DBR to $00 so STA abs targets bank $00
    lda #$00
    pha
    plb                  ; DBR = $00

    ; Set 8-bit mode
    sep #$30
    .a8
    .i8

    ; JML to SuperRAM routine
    jml $023000

@t6_return:
    ; Back in emulation mode
    .a8
    .i8

    ; Check $5400
    lda $5400
    cmp #$42
    bne @t6_fail

    lda #<(SCREEN+7*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+7*ROW+35)
    sta zp_ptr+1
    jsr show_pass_at
    inc zp_pass
    jmp @done

@t6_fail:
    ; Show what we got
    pha
    lda #<(SCREEN+7*ROW+35)
    sta zp_ptr
    lda #>(SCREEN+7*ROW+35)
    sta zp_ptr+1
    jsr show_fail_at
    pla
    pha
    lsr
    lsr
    lsr
    lsr
    tax
    lda hex_chars,x
    sta SCREEN+7*ROW+30
    pla
    and #$0F
    tax
    lda hex_chars,x
    sta SCREEN+7*ROW+31

@done:
    ; Show summary: "RESULT: n/6"
    ldx #0
@res_lbl:
    lda result_text,x
    beq @res_done
    sta SCREEN+9*ROW+1,x
    inx
    bne @res_lbl
@res_done:
    lda zp_pass
    clc
    adc #SC_0
    sta SCREEN+9*ROW+9
    lda #SC_SLASH
    sta SCREEN+9*ROW+10
    lda #SC_6
    sta SCREEN+9*ROW+11

    ; Color summary based on pass count
    lda zp_pass
    cmp #6
    bne @not_all_pass
    ; All pass — green border
    lda #$05
    sta $D020
    ldx #11
@green:
    lda #$05
    sta COLOR+9*ROW+1,x
    dex
    bpl @green
    jmp @halt

@not_all_pass:
    ; Red border
    lda #$02
    sta $D020
    ldx #11
@red:
    lda #$02
    sta COLOR+9*ROW+1,x
    dex
    bpl @red

@halt:
    ; Keep turbo on
    sta $D07B
    jmp @halt

; ── Subroutines ──
; zp_ptr (FA-FB) = screen address for first char of PASS/FAIL

show_pass_at:
    ldy #0
    lda #SC_P
    sta (zp_ptr),y
    iny
    lda #SC_A
    sta (zp_ptr),y
    iny
    lda #SC_S
    sta (zp_ptr),y
    iny
    lda #SC_S
    sta (zp_ptr),y
    ; Color: add $D400 offset (COLOR - SCREEN = $D800 - $0400 = $D400)
    lda zp_ptr
    clc
    adc #<(COLOR - SCREEN)
    sta zp_ptr
    lda zp_ptr+1
    adc #>(COLOR - SCREEN)
    sta zp_ptr+1
    ldy #0
    lda #$05           ; green
    sta (zp_ptr),y
    iny
    sta (zp_ptr),y
    iny
    sta (zp_ptr),y
    iny
    sta (zp_ptr),y
    rts

show_fail_at:
    ldy #0
    lda #SC_F
    sta (zp_ptr),y
    iny
    lda #SC_A
    sta (zp_ptr),y
    iny
    lda #SC_I
    sta (zp_ptr),y
    iny
    lda #SC_L
    sta (zp_ptr),y
    ; Color
    lda zp_ptr
    clc
    adc #<(COLOR - SCREEN)
    sta zp_ptr
    lda zp_ptr+1
    adc #>(COLOR - SCREEN)
    sta zp_ptr+1
    ldy #0
    lda #$02           ; red
    sta (zp_ptr),y
    iny
    sta (zp_ptr),y
    iny
    sta (zp_ptr),y
    iny
    sta (zp_ptr),y
    rts

; ── Data ──

hex_chars:
    .byte 48,49,50,51,52,53,54,55,56,57,1,2,3,4,5,6  ; 0-9,A-F as screen codes

title_text:
    .byte SC_M, SC_V, SC_N, SC_SLASH, SC_M, SC_V, SC_P
    .byte SC_SPACE, SC_T, SC_E, SC_S, SC_T, 0

t1_text:
    .byte SC_1, SC_SPACE, SC_M, SC_V, SC_N, SC_SPACE
    .byte SC_B, SC_K, SC_0, SC_0, SC_SPACE
    .byte SC_F, SC_W, SC_D, 0

t2_text:
    .byte SC_2, SC_SPACE, SC_M, SC_V, SC_P, SC_SPACE
    .byte SC_B, SC_K, SC_0, SC_0, SC_SPACE
    .byte SC_B, SC_W, SC_D, 0

t3_text:
    .byte SC_3, SC_SPACE, SC_M, SC_V, SC_N, SC_SPACE
    .byte SC_0, SC_0, SC_DASH, 48+2, SC_0, SC_2, 0

t4_text:
    .byte SC_4, SC_SPACE, SC_M, SC_V, SC_N, SC_SPACE
    .byte 48+2, SC_0, SC_2, SC_DASH, SC_0, SC_0, 0

t5_text:
    .byte SC_5, SC_SPACE, SC_R, SC_E, SC_U, SC_SPACE
    .byte SC_X, SC_DASH, SC_P, SC_A, SC_T, SC_SPACE, 0

t6_text:
    .byte SC_6, SC_SPACE, SC_S, SC_T, SC_A, SC_SPACE
    .byte SC_F, SC_R, SC_O, SC_M, SC_SPACE
    .byte SC_S, SC_R, SC_A, SC_M, 0

result_text:
    .byte SC_R, SC_E, SC_S, SC_U, SC_L, SC_T, SC_COLON, SC_SPACE, 0
