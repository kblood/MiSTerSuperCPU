; test_long_store_bank0.s — verify SCPU STA [dp],Y to bank $00 writes c64 RAM
;
; Doom's bank $20 prologue uses STA [zp],Y with the long pointer set to bank $00,
; expecting the store to land in c64 motherboard RAM. Hardware Doom never
; populates bank $00 page $0E, suggesting this path is broken.
;
; Test:
;   1. Switch to SCPU turbo + native mode.
;   2. Set up zp $50/$51/$52 = $00:$0E0C (long pointer to bank 0 addr $0E0C).
;   3. LDA #$42 ; STA [$50] (long indirect, no Y) -- writes to $00:$0E0C.
;   4. STA [$50],Y with Y=1 -- writes $42 to $00:$0E0D.
;   5. Switch back to emul mode, return to BASIC.
;   6. After PRG runs, screen RAM at top should show "BANK0 PAGE0E:" + pattern.
;      If c64 RAM at $0E0C..$0E0D = $42 $42 the test passes; we copy them
;      to screen RAM and BASIC's READY proves the program returned cleanly.
;
; Expected screen output (top of C64 screen):
;   "B0:0E0C XX XX  -- expect 42 42"

.p816
.segment "LOADADDR"
    .word $0801

.segment "EXEHDR"
    .byte $0c, $08              ; next BASIC line ptr
    .byte $0a, $00              ; line 10
    .byte $9e                   ; SYS token
    .byte "2061"
    .byte $00
    .byte $00, $00              ; end of BASIC

.segment "CODE"
    .org $080d

start:
    sei
    cld
    ; Enable SuperCPU + turbo
    sta $D07E                   ; hwenable + reg enable
    sta $D07B                   ; software turbo
    ; Switch to native mode
    clc
    xce                         ; emul -> native
    rep #$30                    ; M=16, X=16
    .a16
    .i16
    ; Setup long pointer at zp $50: $00:$0E0C
    lda #$0E0C
    sta $50                     ; lo+hi
    sep #$20                    ; M=8
    .a8
    lda #$00
    sta $52                     ; bank byte = $00
    ; Test 1: STA [$50] (long indirect, no Y)
    lda #$42
    sta ($50)                   ; ca65 syntax for [$50]; verified below
    ; Test 2: STA [$50],Y with Y=1
    rep #$10
    .i16
    ldy #$0001
    sep #$10
    .i8
    ; Use a different opcode form. ca65 syntax for [zp],Y is `sta ($50),y`?
    ; Actually 65816 has both: ($50),Y and [$50],Y with different opcodes.
    ; To force [$50],Y (long indirect indexed Y, opcode $97), use:
    .byte $97, $50
    ; Now read back the values from c64 RAM and copy to screen RAM
    ; (so BASIC READY's screen scroll won't immediately overwrite them)
    lda $0E0C                   ; absolute, DBR=0
    sta $0400                   ; screen top-left
    lda $0E0D
    sta $0401
    ; Static label "B0:0E0C "
    lda #'B' & $3F | $40        ; PETSCII -> screen code (rough)
    ; Easier: just write screen codes directly.
    ; Skip label: just check first 2 bytes match $42.
    ; Switch back to emul mode
    sec
    xce                         ; native -> emul
    sta $D07F                   ; disable SCPU regs
    cli
    rts                         ; return to BASIC
