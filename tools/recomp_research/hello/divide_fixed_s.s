
	.include macro.s

; ----- Code

	.al
	.xl

	* = $100000

	; v0 = a0 / a1

	; copy dividend shifted 16 bits (absolute value)
	stz _v0 + 0
	lda _a0 + 2
	bpl dividend_positive

	; negative
	sec
	lda #0
	sbc _a0 + 0
	sta _v0 + 2
	lda #0
	sbc _a0 + 2
	sta _v0 + 4
	bra dividend_done

	; positive
dividend_positive
	sta _v0 + 4
	lda _a0 + 0
	sta _v0 + 2

	; copy divisor (absolute value)
dividend_done
	lda _a1 + 2
	bpl divisor_positive

	; negative
	sec
	lda #0
	sbc _a1 + 0
	sta _t2 + 0
	lda #0
	sbc _a1 + 2
	sta _t2 + 2
	bra divisor_done

	; positive
divisor_positive
	sta _t2 + 2
	lda _a1 + 0
	sta _t2 + 0

	; clear remainder
divisor_done
	stz _a2 + 0
	stz _a2 + 2
	stz _a2 + 4

	; set binary count to 48
	ldx #48

	; shift into partial dividend
loop
	asl _v0 + 0
	rol _v0 + 2
	rol _v0 + 4
	rol _a2 + 0
	rol _a2 + 2
	rol _a2 + 4

	; subtract divisor
	sec
	lda _a2 + 0
	sbc _t2 + 0
	sta _t0 + 0
	lda _a2 + 2
	sbc _t2 + 2
	sta _t0 + 2
	lda _a2 + 4
	sbc #0

	; jump if divisor didn't fit
	bcc no_fit

	; store new remainder
	sta _a2 + 4
	lda _t0 + 0
	sta _a2 + 0
	lda _t0 + 2
	sta _a2 + 2

	; increase quotient
	inc _v0 + 0

	; loop
no_fit
	dex
	bne loop

	; correct quotient sign
	lda _a0 + 2
	eor _a1 + 2
	bpl sign_done

	; negate quotient
	sec
	lda #0
	sbc _v0 + 0
	sta _v0 + 0
	lda #0
	sbc _v0 + 2
	sta _v0 + 2

	; return
sign_done
	jmp [_ra]
