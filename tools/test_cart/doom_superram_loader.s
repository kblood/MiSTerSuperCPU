; doom_superram_loader.s - Doom loader using SuperRAM LDA long instead of REU DMA
; Replaces REU DMA FETCH with direct 65C816 long addressing
;
; The doom.reu file is loaded by MiSTer ioctl into SDRAM at REU_ADDR (0x1000000).
; SuperRAM banks $01-$FF map to REU_ADDR + {bank, addr16}.
; So doom.reu offset $010000 = SuperRAM bank $01:$0000, etc.
;
; The original doom_loader.prg reads from REU using DMA FETCH, then copies
; via STA [$FB],Y to SuperRAM. Since the data is ALREADY in SuperRAM,
; we can skip the DMA step and use LDA long directly.
;
; Build: cl65 -t none -C c64-816.cfg --cpu 65816 -o doom_superram_loader.prg doom_superram_loader.s

.setcpu "65816"

.segment "LOADADDR"
    .word $0801

.segment "STARTUP"
    ; BASIC stub: 10 SYS 2061
    .word @end
    .word 10
    .byte $9E, "2061", 0
@end:
    .word 0

.segment "CODE"

start:
    sei

    ; Clear screen
    ldx #$00
@clr:
    lda #$20
    sta $0400,x
    sta $0500,x
    sta $0600,x
    sta $0700,x
    lda #$01
    sta $D800,x
    sta $D900,x
    sta $DA00,x
    sta $DB00,x
    inx
    bne @clr

    ; Set border to indicate we're running
    lda #$07        ; yellow border = loading
    sta $D020

    ; Read the doom.reu header/jump table from REU offset $00:$FF00
    ; The original loader reads from address stored at $07B8-$07BA
    ; Default doom.reu: game code starts near offset $00:$FF00 or similar

    ; First, check if doom data is present by reading SuperRAM bank $00 offset $0000
    ; (This is REU offset $000000 = first byte of doom.reu)
    lda #$34        ; RAM under I/O for long addressing
    sta $01

    .a8
    .i8
    ; Switch to native mode for long addressing
    clc
    xce             ; Enter 65C816 native mode

    ; Enable SuperCPU turbo
    sta $D07B

    ; Read first bytes of doom.reu from SuperRAM bank $00
    ; SuperRAM bank $00 = REU_ADDR + $000000 = C64 main RAM (bank 0)
    ; Actually, SuperRAM bank $00 IS the C64 main RAM, not REU offset $0000
    ; REU offset $000000 maps to SuperRAM bank $00 = C64 RAM
    ; REU offset $010000 maps to SuperRAM bank $01
    ;
    ; So doom.reu[0x000000] = C64 RAM (bank $00) — overwritten by KERNAL
    ; doom.reu[0x010000] = SuperRAM bank $01 — actual game data
    ;
    ; Check bank $01 for game data signature
    lda $010000     ; LDA long from bank $01, addr $0000

    ; Store to screen for visibility
    sec
    xce             ; Back to emulation mode
    lda #$35
    sta $01         ; Restore I/O

    ; Display the value we read at position 0,0
    sta $0400       ; Won't show the right thing, we need to convert to PETSCII

    ; Actually, let's just check if bank $01 has non-zero data
    ; The original loader uses a jump table at specific REU offsets
    ; For now, let's try to find where DOOM expects to JML to

    ; The original loader ends with JML [$0004]
    ; This means the game entry point is stored at $0004-$0006 (long pointer)
    ; The original loader uses REU DMA to copy this data from REU to C64 RAM

    ; In the original doom.reu format:
    ; The data at REU offset specified by the loader's data table ($07B5-$07BA)
    ; gets DMA'd to $0400 and $0500, then the code at $0500+ gets copied to
    ; SuperRAM via STA long indirect

    ; Since we can't easily replicate the full loader logic without knowing
    ; the exact doom.reu format, let's try a simpler approach:
    ; Just display what we find at various SuperRAM offsets

    ; Display values from SuperRAM bank $01 at screen positions
    lda #$34
    sta $01
    clc
    xce             ; Native mode

    rep #$10        ; 16-bit index
    .i16
    ldx #$0000
@read_loop:
    lda $010000,x   ; Read from SuperRAM bank $01

    ; Convert to screen code (just show raw hex nibbles)
    pha
    lsr
    lsr
    lsr
    lsr
    jsr hex_to_screen
    sec
    xce
    lda #$35
    sta $01
    sta $0400,x     ; Store high nibble on screen
    lda #$34
    sta $01
    clc
    xce

    pla
    and #$0F
    jsr hex_to_screen
    sec
    xce
    lda #$35
    sta $01
    sta $0428,x     ; Store low nibble on second line
    lda #$34
    sta $01
    clc
    xce

    inx
    cpx #$0028      ; 40 chars
    bne @read_loop

    ; Back to emulation mode
    sec
    xce
    lda #$35
    sta $01

    ; Set border to green = done
    lda #$05
    sta $D020

    ; Halt
@halt:
    jmp @halt

; Convert nibble in A to screen code
hex_to_screen:
    .a8
    cmp #$0A
    bcc @digit
    adc #$00        ; A-F: add offset for letter screen codes
    rts
@digit:
    adc #$30        ; 0-9: ASCII/PETSCII digit
    rts
