
	.include macro.s

; ----- Code

	.al
	.xl

	* = $100000

	; v0 = a0 / a1

	; copy dividend shifted 16 bits
	stz _v0 + 0
	lda _a0 + 0
	sta _v0 + 2
	lda _a0 + 2
	sta _v0 + 4

	; clear remainder
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
	sbc _a1 + 0
	sta _t0 + 0
	lda _a2 + 2
	sbc _a1 + 2
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

	; return
	jmp [_ra]
