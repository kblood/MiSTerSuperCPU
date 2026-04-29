; SuperRAM Execute + Write Test
; Tests: can the CPU execute from bank $20 while writing to bank $10?
; This is the exact pattern Doom C64 uses during init.
;
; Test procedure:
; 1. Copy test loop to bank $20:$8000 via STA long
; 2. JML to bank $20:$8000
; 3. From bank $20, write 256 values to bank $10:$0000 via STA long
; 4. Write success marker ($42) to bank $00:$0500 via STA long
; 5. JML back to bank $00 for verification
;
; Build: cl65 --cpu 65816 -t none -C c64-816.cfg -o scpu_superram_exec_test.prg scpu_superram_exec_test.s
; Run: SYS 2061

.p816
.smart

.segment "STARTUP"
    ; Skip over BASIC header
    jmp start

.segment "CODE"
start:
    sei

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

    ; --- Copy remote_code to bank $20:$8000 via STA long ---
    rep #$30
    ldx #$0000
copy_loop:
    sep #$20
    lda remote_code,x
    sta $208000,x   ; STA long to bank $20:$8000+X (actually STA f:$208000,X)
    rep #$20
    inx
    cpx #remote_code_end - remote_code
    bne copy_loop

    ; Cache flush before jumping
    sep #$20
    sta $D078

    ; Set up return address in DP for the remote code
    ; Store success: the remote code will write $42 to $00:0500

    ; JML to bank $20:$8000
    jml $208000

; --- Code that runs in bank $20 ---
remote_code:
    ; This code executes from SuperRAM bank $20
    ; It writes to SuperRAM bank $10 (different bank)
    sep #$20        ; 8-bit A
    rep #$10        ; 16-bit X
    ldx #$0000

write_loop:
    txa             ; A = low byte of X (counter value)
    sta $100000,x   ; STA long to bank $10:$0000+X
    inx
    cpx #$0100      ; 256 iterations
    bne write_loop

    ; Write success marker
    lda #$42
    sta $000500     ; STA long to bank $00:$0500

    ; Write another marker
    lda #$99
    sta $000501     ; bank $00:$0501

    ; Return to emulation mode and bank $00
    sec
    xce             ; back to emulation mode
    jml $00C100     ; JML to verify routine in bank $00

remote_code_end:

; This code is at $C100 area in bank $00 (reached via JML from bank $20)
.org $C100 - $080D + start  ; adjust for load address offset
verify:
    ; We're back in emulation mode, bank $00
    ; Store result to screen for BASIC to read
    ; PEEK(1280) should be $42 (66), PEEK(1281) should be $99 (153)
    lda $0500
    sta $0502       ; copy to $0502 for verification
    lda $0501
    sta $0503       ; copy to $0503
    rts
