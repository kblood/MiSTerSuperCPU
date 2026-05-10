
	.include macro.s

; ----- Code

	.al
	.xl

	* = $100000

	; LO * LO
	ldy _a1+0
	lda _a0+0

	sta mb0 ;set zp adresses
	sta mb1
	sta mb2
	sta mb3
	eor #$ffff
	sta mb4
	sta mb5
	sta mb6
	sta mb7

	#AS
	sec
	lda [mb0],y
	sbc [mb4],y
	lda [mb1],y
	sbc [mb5],y
	lda [mb2],y
	sbc [mb6],y
	sta _v0+0
	lda [mb3],y
	sbc [mb7],y
	sta _v0+1
	#AL

	; LO * HI
	ldy _a1+2

	#AS
	sec
	lda [mb0],y
	sbc [mb4],y
	sta vt0+0
	lda [mb1],y
	sbc [mb5],y
	sta vt0+1
	lda [mb2],y
	sbc [mb6],y
	sta vt0+2
	lda [mb3],y
	sbc [mb7],y
	sta vt0+3
	#AL

	; PROD
	clc
	lda vt0+0
	adc _v0+0
	sta _v0+0
	lda vt0+2
	adc #0
	sta _v0+2

	; HI * LO
	ldy _a1+0
	lda _a0+2

	sta mb0 ;set zp adresses
	sta mb1
	sta mb2
	sta mb3
	eor #$ffff
	sta mb4
	sta mb5
	sta mb6
	sta mb7

	#AS
	sec
	lda [mb0],y
	sbc [mb4],y
	sta vt0+0
	lda [mb1],y
	sbc [mb5],y
	sta vt0+1
	lda [mb2],y
	sbc [mb6],y
	sta vt0+2
	lda [mb3],y
	sbc [mb7],y
	sta vt0+3
	#AL

	; PROD
	clc
	lda vt0+0
	adc _v0+0
	sta _v0+0
	lda vt0+2
	adc _v0+2
	sta _v0+2

	; HI * HI
	ldy _a1+2

	#AS
	sec
	lda [mb0],y
	sbc [mb4],y
	sta vt0+0
	lda [mb1],y
	sbc [mb5],y
	sta vt0+1
	#AL

	; PROD
	clc
	lda vt0+0
	adc _v0+2
	sta _v0+2

	; SIGN

	; if _a0 < 0, subtract _a1 from upper half of result
	lda _a0+2
	bpl +
	sec
	lda _v0+2
	sbc _a1+0
	sta _v0+2
+

	; if _a1 < 0, subtract _a0 from upper half of result
	lda _a1+2
	bpl +
	sec
	lda _v0+2
	sbc _a0+0
	sta _v0+2
+

	; return
	jmp [_ra]
