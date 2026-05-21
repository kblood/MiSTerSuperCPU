
	.include macro.s

; ----- Code

	.al
	.xl

	* = $100000

	; v0|v1 = a0|a1 / a2|a3

	; copy dividend (absolute value)
	lda _a1 + 2
	bpl dividend_positive

	; negative
	sec
	lda #0
	sbc _a0 + 0
	sta _v0 + 0
	lda #0
	sbc _a0 + 2
	sta _v0 + 2
	lda #0
	sbc _a1 + 0
	sta _v1 + 0
	lda #0
	sbc _a1 + 2
	sta _v1 + 2
	bra dividend_done

	; positive
dividend_positive
	sta _v1 + 2
	lda _a0 + 0
	sta _v0 + 0
	lda _a0 + 2
	sta _v0 + 2
	lda _a1 + 0
	sta _v1 + 0

	; copy divisor (absolute value)
dividend_done
	lda _a3 + 2
	bpl divisor_positive

	; negative
	sec
	lda #0
	sbc _a2 + 0
	sta _t2 + 0
	lda #0
	sbc _a2 + 2
	sta _t2 + 2
	lda #0
	sbc _a3 + 0
	sta _t3 + 0
	lda #0
	sbc _a3 + 2
	sta _t3 + 2
	bra divisor_done

	; positive
divisor_positive
	sta _t3 + 2
	lda _a2 + 0
	sta _t2 + 0
	lda _a2 + 2
	sta _t2 + 2
	lda _a3 + 0
	sta _t3 + 0

	; clear remainder
divisor_done
	stz _t4 + 0
	stz _t4 + 2
	stz _t5 + 0
	stz _t5 + 2

	; set binary count to 64
	ldx #64

	; shift into partial dividend
loop
	asl _v0 + 0
	rol _v0 + 2
	rol _v1 + 0
	rol _v1 + 2
	rol _t4 + 0
	rol _t4 + 2
	rol _t5 + 0
	rol _t5 + 2

	; subtract divisor
	sec
	lda _t4 + 0
	sbc _t2 + 0
	sta _t0 + 0
	lda _t4 + 2
	sbc _t2 + 2
	sta _t0 + 2
	lda _t5 + 0
	sbc _t3 + 0
	sta _t1 + 0
	lda _t5 + 2
	sbc _t3 + 2

	; jump if divisor didn't fit
	bcc no_fit

	; store new remainder
	sta _t5 + 2
	lda _t0 + 0
	sta _t4 + 0
	lda _t0 + 2
	sta _t4 + 2
	lda _t1 + 0
	sta _t5 + 0

	; increase quotient
	inc _v0 + 0

	; loop
no_fit
	dex
	bne loop

	; correct quotient sign
	lda _a1 + 2
	eor _a3 + 2
	bpl sign_done

	; negate quotient
	sec
	lda #0
	sbc _v0 + 0
	sta _v0 + 0
	lda #0
	sbc _v0 + 2
	sta _v0 + 2
	lda #0
	sbc _v1 + 0
	sta _v1 + 0
	lda #0
	sbc _v1 + 2
	sta _v1 + 2

	; return
sign_done
	jmp [_ra]
