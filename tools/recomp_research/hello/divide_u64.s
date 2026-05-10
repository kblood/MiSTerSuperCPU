
	.include macro.s

; ----- Code

	.al
	.xl

	* = $100000

	; v0|v1 = a0|a1 / a2|a3

	; copy dividend
	lda _a0 + 0
	sta _v0 + 0
	lda _a0 + 2
	sta _v0 + 2
	lda _a1 + 0
	sta _v1 + 0
	lda _a1 + 2
	sta _v1 + 2

	; clear remainder
	stz _a0 + 0
	stz _a0 + 2
	stz _a1 + 0
	stz _a1 + 2

	; set binary count to 64
	ldx #64

	; shift into partial dividend
loop
	asl _v0 + 0
	rol _v0 + 2
	rol _v1 + 0
	rol _v1 + 2
	rol _a0 + 0
	rol _a0 + 2
	rol _a1 + 0
	rol _a1 + 2

	; subtract divisor
	sec
	lda _a0 + 0
	sbc _a2 + 0
	sta _t0 + 0
	lda _a0 + 2
	sbc _a2 + 2
	sta _t0 + 2
	lda _a1 + 0
	sbc _a3 + 0
	sta _t1 + 0
	lda _a1 + 2
	sbc _a3 + 2

	; jump if divisor didn't fit
	bcc no_fit

	; store new remainder
	sta _a1 + 2
	lda _t0 + 0
	sta _a0 + 0
	lda _t0 + 2
	sta _a0 + 2
	lda _t1 + 0
	sta _a1 + 0

	; increase quotient
	inc _v0 + 0

	; loop
no_fit
	dex
	bne loop

	; return
	jmp [_ra]
