; SuperRAM Pipeline Corruption Test
; Tests: STA long to bank $02, then STA long to bank $00, then LDA long from bank $02.
; This is the exact pattern that corrupts the pipeline (Doom crash root cause).
;
; Test 1: STA $020100 ($42) → STA $000500 ($55) → LDA $020100 → result to $02
;         Expected: PEEK(2) = 66 ($42)
; Test 2: STA $020100 ($42) → LDA $020100 (no intermediate bank $00 write)
;         Expected: PEEK(3) = 66 ($42)
; Test 3: Multiple interleaved writes then read-back
;         STA $020100 ($AA) → STA $000500 ($BB) → STA $030200 ($CC) → STA $000501 ($DD)
;         → LDA $020100 → result to $04, LDA $030200 → result to $05
;         Expected: PEEK(4) = 170 ($AA), PEEK(5) = 204 ($CC)
;
; Build: cl65 --cpu 65816 -t none -C c64-816.cfg -o scpu_pipeline_test.prg scpu_pipeline_test.s
; Run: SYS 2061

.p816
.smart

.segment "EXEHDR"
    .byte $0B,$08,$0A,$00,$9E,$32,$30,$36,$31,$00,$00,$00  ; 10 SYS2061

.segment "CODE"
start:
    sei

    ; Map out KERNAL so vectors read from RAM
    lda #$35
    sta $01

    ; Enter native mode
    clc
    xce
    rep #$30        ; 16-bit A, X, Y

    ; Set DP = 0, DBR = 0
    lda #$0000
    tcd
    sep #$20        ; 8-bit A
    lda #$00
    pha
    plb             ; DBR = 0

    ; === Test 1: Interleaved bank $02/$00 write, then read bank $02 ===
    lda #$42
    sta $020100     ; STA long to bank $02:$0100
    lda #$55
    sta $000500     ; STA long to bank $00:$0500 (triggers pipeline switch)
    lda $020100     ; LDA long from bank $02:$0100 — was returning 0!
    ; Return to emulation mode to store result
    sec
    xce
    sta $02         ; store Test 1 result

    ; === Test 2: Direct round-trip (no intermediate bank $00 write) ===
    clc
    xce
    sep #$20
    lda #$00
    pha
    plb
    lda #$42
    sta $020100     ; STA long to bank $02:$0100
    lda $020100     ; LDA long immediately — no bank $00 in between
    sec
    xce
    sta $03         ; store Test 2 result

    ; === Test 3: Multiple interleaved writes ===
    clc
    xce
    sep #$20
    lda #$00
    pha
    plb
    lda #$AA
    sta $020100     ; bank $02
    lda #$BB
    sta $000500     ; bank $00 (pipeline switch 1)
    lda #$CC
    sta $030200     ; bank $03
    lda #$DD
    sta $000501     ; bank $00 (pipeline switch 2)
    lda $020100     ; read back bank $02
    sec
    xce
    sta $04         ; store Test 3a result

    clc
    xce
    sep #$20
    lda #$00
    pha
    plb
    lda $030200     ; read back bank $03
    sec
    xce
    sta $05         ; store Test 3b result

    ; Done — results in $02-$05
    cli
    rts
