; SuperRAM read/write test for MiSTer SuperCPU
; Tests write-then-read at various bank/offset combinations
; Build: ca65 --cpu 65816 superram_test.s -o superram_test.o
;        ld65 -t c64 superram_test.o -o superram_test.prg

.segment "LOADADDR"
.word $0801

.segment "EXEHDR"
; BASIC stub: 10 SYS 2062
.word @nextline
.word 10          ; line number
.byte $9E         ; SYS token
.byte "2061",0    ; address as ASCII
@nextline:
.word 0           ; end of BASIC program

.segment "CODE"

SCREEN = $0400

; ---- Entry point ----
    jmp main

; ---- Zero page usage ----
; $02-$0D: test results
; $FB/$FC: screen pointer
; $FD/$FE: string pointer

; ---- Helper: set screen pointer to row A (0-24) ----
set_row:
    tax
    lda #<SCREEN
    sta $FB
    lda #>SCREEN
    sta $FC
    cpx #0
    beq @done
@loop:
    clc
    lda $FB
    adc #40
    sta $FB
    bcc @noinc
    inc $FC
@noinc:
    dex
    bne @loop
@done:
    ldy #0
    rts

; ---- Helper: print A as 2 hex digits at ($FB),Y; advances Y ----
print_hex:
    pha
    lsr a
    lsr a
    lsr a
    lsr a
    jsr print_nib
    pla
    ; fall through
print_nib:
    and #$0F
    cmp #$0A
    bcc @digit
    adc #$06      ; carry set, so +7
@digit:
    adc #$30      ; +'0'
    sta ($FB),y
    iny
    rts

; ---- Helper: print inline string at ($FB),Y; advances Y ----
; Usage: jsr print_str / .byte "TEXT",0
print_str:
    ; Pull return address (points to byte before string)
    pla
    sta $FD
    pla
    sta $FE
    ; Advance to first string byte
    inc $FD
    bne @loop
    inc $FE
@loop:
    sty $F9         ; save Y (screen offset)
    ldy #0
    lda ($FD),y
    beq @done
    ldy $F9         ; restore screen Y
    sta ($FB),y
    iny
    inc $FD
    bne @loop
    inc $FE
    bne @loop       ; always taken
@done:
    ldy $F9         ; restore screen Y
    ; Push address of byte after null as return
    lda $FE
    pha
    lda $FD
    pha
    rts

; ---- Helper: print " OK" or " FAIL" based on ZP match ----
; A = zp address, X = expected value
check_result:
    sta @ldcmp+1    ; self-modify: LDA $zp
    stx @cmpval+1   ; self-modify: CMP #$xx
@ldcmp:
    lda $02         ; patched
@cmpval:
    cmp #$00        ; patched
    bne @fail
    jsr print_str
    .byte " OK",0
    rts
@fail:
    jsr print_str
    .byte " FAIL",0
    rts

; ==== MAIN ====
main:
    ; Clear screen
    lda #$20        ; space
    ldx #0
@clr:
    sta $0400,x
    sta $0500,x
    sta $0600,x
    sta $06E8,x
    dex
    bne @clr

    ; Set colors
    lda #$00
    sta $D020
    sta $D021

    ; Title
    lda #0
    jsr set_row
    jsr print_str
    .byte "SUPERRAM READ/WRITE TEST",0

    ; ---- Enter native mode ----
    sei
    clc
    xce             ; CLC+XCE = switch to native mode

    ; === Test 1: bank $01, offset $0000 ===
    .a8
    .i8
    lda #$A5
    sta $010000     ; STA long
    lda $010000     ; LDA long
    sta $02

    ; === Test 2: bank $01, offset $20FC ===
    lda #$5A
    sta $0120FC
    lda $0120FC
    sta $03

    ; === Test 3: bank $01, offset $4000 ===
    lda #$33
    sta $014000
    lda $014000
    sta $04

    ; === Test 4: bank $01, offset $8000 ===
    lda #$CC
    sta $018000
    lda $018000
    sta $05

    ; === Test 5: bank $20, offset $20FC (Doom's bank) ===
    lda #$77
    sta $2020FC
    lda $2020FC
    sta $06

    ; === Test 6: sequential writes then reads (pipeline stress) ===
    lda #$11
    sta $011000
    lda #$22
    sta $011001
    lda #$33
    sta $011002
    lda #$44
    sta $011003
    ; Read back rapidly
    lda $011000
    sta $07
    lda $011001
    sta $08
    lda $011002
    sta $09
    lda $011003
    sta $0A

    ; === Test 7: cross-bank reads ===
    lda #$AA
    sta $010000
    lda #$BB
    sta $020000
    lda #$CC
    sta $030000
    lda $010000
    sta $0B
    lda $020000
    sta $0C
    lda $030000
    sta $0D

    ; ---- Return to emulation mode ----
    sec
    xce             ; SEC+XCE = back to emulation mode
    .a8
    .i8

    ; ---- Display results ----

    ; Test 1
    lda #2
    jsr set_row
    jsr print_str
    .byte "T1 $01:0000 W:A5 R:",0
    lda $02
    jsr print_hex
    lda #$02
    ldx #$A5
    jsr check_result

    ; Test 2
    lda #3
    jsr set_row
    jsr print_str
    .byte "T2 $01:20FC W:5A R:",0
    lda $03
    jsr print_hex
    lda #$03
    ldx #$5A
    jsr check_result

    ; Test 3
    lda #4
    jsr set_row
    jsr print_str
    .byte "T3 $01:4000 W:33 R:",0
    lda $04
    jsr print_hex
    lda #$04
    ldx #$33
    jsr check_result

    ; Test 4
    lda #5
    jsr set_row
    jsr print_str
    .byte "T4 $01:8000 W:CC R:",0
    lda $05
    jsr print_hex
    lda #$05
    ldx #$CC
    jsr check_result

    ; Test 5
    lda #6
    jsr set_row
    jsr print_str
    .byte "T5 $20:20FC W:77 R:",0
    lda $06
    jsr print_hex
    lda #$06
    ldx #$77
    jsr check_result

    ; Test 6 - sequential
    lda #8
    jsr set_row
    jsr print_str
    .byte "T6 SEQ $01:1000-3:",0
    lda $07
    jsr print_hex
    lda #' '
    sta ($FB),y
    iny
    lda $08
    jsr print_hex
    lda #' '
    sta ($FB),y
    iny
    lda $09
    jsr print_hex
    lda #' '
    sta ($FB),y
    iny
    lda $0A
    jsr print_hex

    lda #9
    jsr set_row
    jsr print_str
    .byte "  EXPECT: 11 22 33 44",0

    ; Test 7 - cross-bank
    lda #11
    jsr set_row
    jsr print_str
    .byte "T7 XBANK $01-03:0000:",0
    lda $0B
    jsr print_hex
    lda #' '
    sta ($FB),y
    iny
    lda $0C
    jsr print_hex
    lda #' '
    sta ($FB),y
    iny
    lda $0D
    jsr print_hex

    lda #12
    jsr set_row
    jsr print_str
    .byte "  EXPECT: AA BB CC",0

    ; Done - infinite loop
@spin:
    jmp @spin
