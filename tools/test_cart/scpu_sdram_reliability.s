; scpu_sdram_reliability.s — SDRAM read reliability test
;
; Writes $AA to SuperRAM $02:0000 via io_cycle (POKE $DF1D),
; then reads it back 256 times via LDA long, counting mismatches.
; Result stored at $0400 (screen RAM) for easy visibility.
;
; Build:
;   ca65 --cpu 65816 -o out/scpu_sdram_reliability.o scpu_sdram_reliability.s
;   ld65 -C c64-816.cfg -o out/scpu_sdram_reliability.prg out/scpu_sdram_reliability.o
;
; Run via BASIC: SYS 2061

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

SCREEN  = $0400
DF1D    = $DF1D        ; io_cycle write port (writes to SuperRAM)
ERRCNT  = $02          ; zero page: error count
READVAL = $03          ; zero page: last read value
ITER    = $04          ; zero page: iteration counter (16-bit)
EXPECT  = $AA          ; expected value

Start:
    ; --- Phase 1: Write $AA to SuperRAM $02:0000 via io_cycle ---
    ; First set REU address registers to point to $020000
    ; $DF02/$DF03 = REU address low/high = $0000
    ; $DF04 = REU bank = $02
    LDA #$00
    STA $DF02          ; REU addr low = $00
    STA $DF03          ; REU addr high = $00
    LDA #$02
    STA $DF04          ; REU bank = $02
    ; Write the test byte
    LDA #EXPECT
    STA DF1D           ; io_cycle write: $AA -> SuperRAM $02:0000

    ; --- Phase 2: Switch to native mode, read via LDA long ---
    SEI
    CLC
    XCE                ; native mode
    .a8
    .i8

    LDA #$00
    STA ERRCNT         ; error count = 0
    STA ITER
    STA ITER+1

    ; Read 256 times
    LDX #$00
@loop:
    ; LDA long $020000
    LDA $020000        ; AF 00 00 02 — LDA long from SuperRAM
    CMP #EXPECT
    BEQ @ok
    ; Mismatch!
    INC ERRCNT
    STA READVAL        ; save last bad value
@ok:
    INX
    BNE @loop          ; 256 iterations

    ; --- Phase 3: Back to emulation mode, display results ---
    SEC
    XCE                ; back to emulation mode
    .a8
    .i8
    CLI

    ; Display error count as decimal at screen position
    ; First clear a line
    LDA #$20           ; space
    LDX #$00
@clr:
    STA SCREEN,X
    INX
    CPX #40
    BNE @clr

    ; Show "ERRORS:" at screen start
    LDA #$05           ; E
    STA SCREEN+0
    LDA #$12           ; R
    STA SCREEN+1
    LDA #$12           ; R
    STA SCREEN+2
    LDA #$0F           ; O
    STA SCREEN+3
    LDA #$12           ; R
    STA SCREEN+4
    LDA #$13           ; S
    STA SCREEN+5
    LDA #$3A           ; :
    STA SCREEN+6

    ; Convert error count to decimal (0-255)
    LDA ERRCNT
    JSR ShowByte       ; show at SCREEN+7

    ; Show "LAST:" and last bad value
    LDA #$20           ; space
    STA SCREEN+10
    LDA #$0C           ; L
    STA SCREEN+11
    LDA #$01           ; A
    STA SCREEN+12
    LDA #$13           ; S
    STA SCREEN+13
    LDA #$14           ; T
    STA SCREEN+14
    LDA #$3A           ; :
    STA SCREEN+15

    LDA READVAL
    JSR ShowByte2      ; show at SCREEN+16

    RTS

; Show byte in A as decimal at SCREEN+7
ShowByte:
    LDX #$00           ; hundreds
@h: CMP #100
    BCC @tens
    SBC #100
    INX
    BCS @h
@tens:
    PHA
    TXA
    CLC
    ADC #$30
    STA SCREEN+7
    PLA
    LDX #$00
@t: CMP #10
    BCC @ones
    SBC #10
    INX
    BCS @t
@ones:
    PHA
    TXA
    CLC
    ADC #$30
    STA SCREEN+8
    PLA
    CLC
    ADC #$30
    STA SCREEN+9
    RTS

; Show byte in A as decimal at SCREEN+16
ShowByte2:
    LDX #$00
@h: CMP #100
    BCC @tens
    SBC #100
    INX
    BCS @h
@tens:
    PHA
    TXA
    CLC
    ADC #$30
    STA SCREEN+16
    PLA
    LDX #$00
@t: CMP #10
    BCC @ones
    SBC #10
    INX
    BCS @t
@ones:
    PHA
    TXA
    CLC
    ADC #$30
    STA SCREEN+17
    PLA
    CLC
    ADC #$30
    STA SCREEN+18
    RTS
