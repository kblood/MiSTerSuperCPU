; scpu_sdram_timing_test.s — Verify ioctl-written SuperRAM data is visible via LDA long
; Build: cl65 -t none -C c64-816.cfg --cpu 65816 -o scpu_sdram_timing_test.prg scpu_sdram_timing_test.s
; Load: python tools/mister_debug.py load_prg tools/test_cart/scpu_sdram_timing_test.prg
; Run: SYS 2061

.segment "EXEHDR"
    .byte $0B,$08   ; next line ptr
    .byte $0A,$00   ; line 10
    .byte $9E       ; SYS token
    .byte "2061"    ; SYS 2061
    .byte $00       ; end of line
    .byte $00,$00   ; end of BASIC

.segment "CODE"
.setcpu "65816"

; Result buffer at $C000 (untouched by BASIC)
SCREEN = $C000

start:
    ; Switch to native mode
    clc
    xce

    ; === Test 1: STA/LDA round-trip at bank $02:$0100 ===
    rep #$20            ; 16-bit accumulator
    .a16
    lda #$A55A          ; test pattern
    sta $020100         ; STA long to bank $02:$0100
    lda $020100         ; LDA long from same address
    sep #$20            ; back to 8-bit
    .a8
    sta SCREEN          ; store low byte at screen pos 0 (expect $5A)
    xba
    sta SCREEN+1        ; store high byte at screen pos 1 (expect $A5)

    ; === Test 2: Read bank $02:$0000 — should show ioctl data if .reu loaded ===
    lda $020000         ; LDA long bank $02 addr $0000
    sta SCREEN+3        ; store at screen pos 3

    ; === Test 3: Read bank $02:$0001 ===
    lda $020001
    sta SCREEN+4

    ; === Test 4: Read bank $01:$0000 ===
    lda $010000
    sta SCREEN+6

    ; === Test 5: Read bank $01:$0001 ===
    lda $010001
    sta SCREEN+7

    ; === Test 6: STA/LDA round-trip bank $01:$0000 ===
    lda #$42
    sta $010000
    lda $010000
    sta SCREEN+9        ; expect $42

    ; === Test 7: Write $BE to bank $02:$0000, read back ===
    lda #$BE
    sta $020000
    lda $020000
    sta SCREEN+11       ; expect $BE

    ; Switch back to emulation mode
    sec
    xce

    rts
