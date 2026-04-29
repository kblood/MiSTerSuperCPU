; ============================================================================
; scpu_regress.s — SuperCPU SuperRAM regression test
; ============================================================================
; Tests bank $00 BRAM, SuperRAM banks $01/$02/$03/$20 at multiple offsets
; including $20:$20FC (Doom crash offset).
;
; Workaround: SEP #$30 after CLC+XCE, because P65C816 doesn't force M=X=1
; on emu→native transition (only on native→emu). Fix in P65C816.vhd line 412.
;
; Output: PASS/FAIL on screen via direct screen writes (no CHROUT/KERNAL).
; Build: ca65 --cpu 65816 scpu_regress.s -o scpu_regress.o
;        ld65 -C c64prg.cfg scpu_regress.o -o scpu_regress.prg
; ============================================================================

.segment "LOADADDR"
.word $0801

.segment "EXEHDR"
.word @next
.word 10
.byte $9E
.byte "2061",0
@next:
.word 0

.segment "CODE"

SCREEN = $0400
COLOR  = $D800

; Result storage in zero page (use $F0+ to avoid BASIC)
zp_t1 = $F0   ; bank $00 STA long readback
zp_t2 = $F1   ; bank $01:$0000
zp_t3 = $F2   ; bank $01:$20FC (Doom offset)
zp_t4 = $F3   ; bank $01:$4000
zp_t5 = $F4   ; bank $01:$8000
zp_t6 = $F5   ; bank $20:$20FC (Doom bank+offset)
zp_t7a = $F6  ; sequential reads
zp_t7b = $F7
zp_t7c = $F8
zp_t7d = $F9
zp_t8a = $FA  ; cross-bank
zp_t8b = $FB
zp_t8c = $FC

start:
    ; Marker '1' (emu mode) — proves we ran
    lda #$31
    sta SCREEN+40
    sei
    lda #$32
    sta SCREEN+41

    ; ===== Native mode entry =====
    clc
    xce
    .a8
    .i8
    sep #$30        ; Workaround: force M=X=1 (P65C816 bug)

    ; Marker '3' — STA abs in native mode now works
    lda #$33
    sta SCREEN+42

    ; ====================================================
    ; T1: bank $00 RAM via STA long (cassette buffer area)
    ; ====================================================
    .byte $A9, $11
    .byte $8F, $00, $03, $00      ; STA $000300
    .byte $AF, $00, $03, $00      ; LDA $000300
    .byte $85, zp_t1

    ; ====================================================
    ; T2: bank $01:$0000
    ; ====================================================
    .byte $A9, $A5
    .byte $8F, $00, $00, $01
    .byte $AF, $00, $00, $01
    .byte $85, zp_t2

    ; ====================================================
    ; T3: bank $01:$20FC (Doom crash offset)
    ; ====================================================
    .byte $A9, $5A
    .byte $8F, $FC, $20, $01
    .byte $AF, $FC, $20, $01
    .byte $85, zp_t3

    ; ====================================================
    ; T4: bank $01:$4000
    ; ====================================================
    .byte $A9, $33
    .byte $8F, $00, $40, $01
    .byte $AF, $00, $40, $01
    .byte $85, zp_t4

    ; ====================================================
    ; T5: bank $01:$8000
    ; ====================================================
    .byte $A9, $CC
    .byte $8F, $00, $80, $01
    .byte $AF, $00, $80, $01
    .byte $85, zp_t5

    ; ====================================================
    ; T6: bank $20:$20FC (Doom bank+offset)
    ; ====================================================
    .byte $A9, $77
    .byte $8F, $FC, $20, $20
    .byte $AF, $FC, $20, $20
    .byte $85, zp_t6

    ; ====================================================
    ; T7: sequential pipeline stress
    ; ====================================================
    .byte $A9, $11
    .byte $8F, $00, $10, $01
    .byte $A9, $22
    .byte $8F, $01, $10, $01
    .byte $A9, $33
    .byte $8F, $02, $10, $01
    .byte $A9, $44
    .byte $8F, $03, $10, $01
    .byte $AF, $00, $10, $01
    .byte $85, zp_t7a
    .byte $AF, $01, $10, $01
    .byte $85, zp_t7b
    .byte $AF, $02, $10, $01
    .byte $85, zp_t7c
    .byte $AF, $03, $10, $01
    .byte $85, zp_t7d

    ; ====================================================
    ; T8: cross-bank
    ; ====================================================
    .byte $A9, $AA
    .byte $8F, $00, $00, $01      ; bank 1 (overwrites $A5)
    .byte $A9, $BB
    .byte $8F, $00, $00, $02
    .byte $A9, $CC
    .byte $8F, $00, $00, $03
    .byte $AF, $00, $00, $01
    .byte $85, zp_t8a
    .byte $AF, $00, $00, $02
    .byte $85, zp_t8b
    .byte $AF, $00, $00, $03
    .byte $85, zp_t8c

    ; Marker '4' before exit
    lda #$34
    sta SCREEN+43

    ; ===== Return to emulation =====
    sec
    xce
    .a8
    .i8
    cli

    ; Marker '5' (emu)
    lda #$35
    sta SCREEN+44

    ; ============================================================
    ; Display results
    ; ============================================================

    ; Row 3 (SCREEN+120): "T1-T6 RESULTS"
    ldx #0
@hdr_loop:
    lda hdr_text,x
    beq @hdr_done
    sta SCREEN+120,x
    inx
    bne @hdr_loop
@hdr_done:

    ; Row 4 (SCREEN+160): hex bytes for T1-T6 (each + space + PASS/FAIL letter)
    ; T1 expect 11
    ldx #0
    lda zp_t1
    jsr hex_at_row4
    lda #$11
    cmp zp_t1
    jsr pf_at_row4

    inx
    inx                     ; skip 1 col
    lda zp_t2
    jsr hex_at_row4
    lda #$A5
    cmp zp_t2
    jsr pf_at_row4

    inx
    inx
    lda zp_t3
    jsr hex_at_row4
    lda #$5A
    cmp zp_t3
    jsr pf_at_row4

    inx
    inx
    lda zp_t4
    jsr hex_at_row4
    lda #$33
    cmp zp_t4
    jsr pf_at_row4

    inx
    inx
    lda zp_t5
    jsr hex_at_row4
    lda #$CC
    cmp zp_t5
    jsr pf_at_row4

    inx
    inx
    lda zp_t6
    jsr hex_at_row4
    lda #$77
    cmp zp_t6
    jsr pf_at_row4

    ; Row 6 (SCREEN+240): T7 sequential header
    ldx #0
@h7l:
    lda h7_text,x
    beq @h7d
    sta SCREEN+240,x
    inx
    bne @h7l
@h7d:

    ; Row 7 (SCREEN+280): T7 results
    ldx #0
    lda zp_t7a
    jsr hex_at_row7
    inx
    lda zp_t7b
    jsr hex_at_row7
    inx
    lda zp_t7c
    jsr hex_at_row7
    inx
    lda zp_t7d
    jsr hex_at_row7
    ; Check
    lda zp_t7a
    cmp #$11
    bne @t7f
    lda zp_t7b
    cmp #$22
    bne @t7f
    lda zp_t7c
    cmp #$33
    bne @t7f
    lda zp_t7d
    cmp #$44
    bne @t7f
    lda #$10                ; 'P'
    sta SCREEN+280+10
    lda #$01                ; 'A'
    sta SCREEN+280+11
    lda #$13                ; 'S'
    sta SCREEN+280+12
    lda #$13
    sta SCREEN+280+13
    jmp @t7d
@t7f:
    lda #$06                ; 'F'
    sta SCREEN+280+10
    lda #$01                ; 'A'
    sta SCREEN+280+11
    lda #$09                ; 'I'
    sta SCREEN+280+12
    lda #$0C                ; 'L'
    sta SCREEN+280+13
@t7d:

    ; Row 9 (SCREEN+360): T8 cross-bank header
    ldx #0
@h8l:
    lda h8_text,x
    beq @h8d
    sta SCREEN+360,x
    inx
    bne @h8l
@h8d:

    ; Row 10 (SCREEN+400): T8 results
    ldx #0
    lda zp_t8a
    jsr hex_at_row10
    inx
    lda zp_t8b
    jsr hex_at_row10
    inx
    lda zp_t8c
    jsr hex_at_row10
    lda zp_t8a
    cmp #$AA
    bne @t8f
    lda zp_t8b
    cmp #$BB
    bne @t8f
    lda zp_t8c
    cmp #$CC
    bne @t8f
    lda #$10                ; P
    sta SCREEN+400+10
    lda #$01
    sta SCREEN+400+11
    lda #$13
    sta SCREEN+400+12
    lda #$13
    sta SCREEN+400+13
    jmp @done
@t8f:
    lda #$06
    sta SCREEN+400+10
    lda #$01
    sta SCREEN+400+11
    lda #$09
    sta SCREEN+400+12
    lda #$0C
    sta SCREEN+400+13
@done:

@spin:
    jmp @spin

; ----------------------------------------------------------------
; Print A as 2 hex digits at SCREEN+160 + (X*3), advances X by 2
; ----------------------------------------------------------------
hex_at_row4:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nibble_r4
    pla
    and #$0F
    jsr nibble_r4
    rts

nibble_r4:
    cmp #$0A
    bcc :+
    sbc #$0A
    clc
    adc #$01            ; 'A'=$01 in screen code
    bra :++
:   clc
    adc #$30            ; '0'=$30
:   sta SCREEN+160,x
    inx
    rts

; PASS or FAIL letter at row 4 (single 'P' or 'F' for compactness)
; Z=1 means equal (PASS)
pf_at_row4:
    bne @f
    lda #$10            ; 'P'
    sta SCREEN+160,x
    inx
    rts
@f:
    lda #$06            ; 'F'
    sta SCREEN+160,x
    inx
    rts

hex_at_row7:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nibble_r7
    pla
    and #$0F
    jsr nibble_r7
    rts

nibble_r7:
    cmp #$0A
    bcc :+
    sbc #$0A
    clc
    adc #$01
    bra :++
:   clc
    adc #$30
:   sta SCREEN+280,x
    inx
    rts

hex_at_row10:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr nibble_r10
    pla
    and #$0F
    jsr nibble_r10
    rts

nibble_r10:
    cmp #$0A
    bcc :+
    sbc #$0A
    clc
    adc #$01
    bra :++
:   clc
    adc #$30
:   sta SCREEN+400,x
    inx
    rts

; ----------------------------------------------------------------
; Strings (screen codes, 0-terminated)
; ----------------------------------------------------------------
; "T1 T2 T3 T4 T5 T6"
hdr_text:
    .byte $14, $31, $20  ; T1 (T=$14, 1=$31)
    .byte $14, $32, $20  ; T2
    .byte $14, $33, $20  ; T3
    .byte $14, $34, $20  ; T4
    .byte $14, $35, $20  ; T5
    .byte $14, $36, 0    ; T6

; "T7 SEQ:"
h7_text:
    .byte $14, $37, $20, $13, $05, $11, $3A, 0  ; T7 SEQ: (T,7,space,S,E,Q,:)

; "T8 XBANK:"
h8_text:
    .byte $14, $38, $20, $18, $02, $01, $0E, $0B, $3A, 0
