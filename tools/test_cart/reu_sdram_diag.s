; reu_sdram_diag.s — Read REU SDRAM diagnostic registers after .reu load
; Assemble: cl65 --cpu 65816 -t none -C c64-816.cfg -o reu_sdram_diag.prg reu_sdram_diag.s
; Run: SYS 2061
;
; After loading a .reu file from OSD, run this to dump:
;   - ioctl byte count (how many bytes HPS sent)
;   - SDRAM write count (how many io_cycle writes presented to SDRAM)
;   - First SDRAM write address and data
;   - SDRAM readback byte 0 (independent of CPU path)
;   - LDA long readback of bank $02:$0000 (CPU SuperRAM path)

.segment "CODE"

CHROUT = $FFD2
BASOUT = $AB1E     ; BASIC print number routine (prints A as unsigned)

start:
    ; Print header
    ldx #0
@hdr:
    lda header,x
    beq @done_hdr
    jsr CHROUT
    inx
    bne @hdr
@done_hdr:

    ; Read and print diagnostic registers $DF09-$DF1C
    ; Format: "REG $DFxx = nnn"
    ldx #9          ; start at register 9
@loop:
    stx cur_reg

    ; Print register name
    lda #'$'
    jsr CHROUT
    lda #'D'
    jsr CHROUT
    lda #'F'
    jsr CHROUT
    ; Convert register offset to hex
    txa
    jsr print_hex
    lda #'='
    jsr CHROUT

    ; Read the register
    lda $DF00,x
    jsr print_dec

    lda #13         ; newline
    jsr CHROUT

    ldx cur_reg
    inx
    cpx #29         ; stop after register 28
    bcc @loop

    ; Now test LDA long from bank $02:$0000 (SuperRAM CPU path)
    ; Need native mode for 24-bit addressing
    lda #13
    jsr CHROUT
    ldx #0
@cpu_hdr:
    lda cpu_header,x
    beq @done_cpu_hdr
    jsr CHROUT
    inx
    bne @cpu_hdr
@done_cpu_hdr:

    clc
    xce             ; switch to native mode
    .byte $AF, $00, $00, $02  ; LDA long $020000 (bank $02, addr $0000)
    sta result
    .byte $AF, $01, $00, $02  ; LDA long $020001
    sta result+1
    sec
    xce             ; back to emulation mode

    lda result
    jsr print_dec
    lda #','
    jsr CHROUT
    lda result+1
    jsr print_dec
    lda #13
    jsr CHROUT

    ; Also do STA/LDA round-trip to verify SuperRAM works
    ldx #0
@rt_hdr:
    lda rt_header,x
    beq @done_rt_hdr
    jsr CHROUT
    inx
    bne @rt_hdr
@done_rt_hdr:

    clc
    xce
    lda #$5A
    .byte $8F, $00, $01, $02  ; STA long $020100 = bank $02, addr $0100
    lda #$A5
    .byte $8F, $01, $01, $02  ; STA long $020101
    .byte $AF, $00, $01, $02  ; LDA long $020100
    sta result
    .byte $AF, $01, $01, $02  ; LDA long $020101
    sta result+1
    sec
    xce

    lda result
    jsr print_dec
    lda #','
    jsr CHROUT
    lda result+1
    jsr print_dec
    lda #13
    jsr CHROUT

    rts

; Print A as 3-digit decimal
print_dec:
    pha
    lda #0
    sta hundreds
    sta tens
    pla
    ; Count hundreds
@h: cmp #100
    bcc @t
    sbc #100
    inc hundreds
    bne @h
@t: cmp #10
    bcc @u
    sbc #10
    inc tens
    bne @t
@u: pha             ; units
    lda hundreds
    ora #'0'
    jsr CHROUT
    lda tens
    ora #'0'
    jsr CHROUT
    pla
    ora #'0'
    jsr CHROUT
    rts

; Print A as 2-digit hex
print_hex:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr @nibble
    pla
    and #$0F
    jsr @nibble
    rts
@nibble:
    cmp #10
    bcc @digit
    adc #6          ; carry set: A = A + 7
@digit:
    adc #'0'
    jmp CHROUT

header:
    .byte 13, "REU SDRAM DIAG", 13
    .byte "AFTER .REU LOAD:", 13, 0

cpu_header:
    .byte "LDA $02:0000=", 0

rt_header:
    .byte "STA/LDA RT=", 0

cur_reg:  .byte 0
result:   .byte 0, 0
hundreds: .byte 0
tens:     .byte 0
