
	.include macro.s

; ----- Code

	.al
	.xl

	* = $100000

	ldx #$ffff
	lda _a0+2

	.for i=0,i<8,i=i+1
		stz mb0+(i*4)+0
		sta mb0+(i*4)+2
		.if i>3
			stx mt0+(i*4)+0
			sta mt0+(i*4)+2
		.fi
		.if i<7
			ina
			.if i<4
				stz mt0+(i*4)+0
				sta mt0+(i*4)+2
			.fi
			ina
		.fi
	.next

	ldx #$0000
	stz vt0+0
	stz vt0+2
	stz vt1+0

loop1
	txa
	lsr
	clc
	adc vt0+0
	sta vt0+0
	lda #$0000
	adc vt0+2
	sta vt0+2

	#AS
	txy
	lda vt0+0
	sta [mb0],y
	sta [mt4],y
	lda vt0+1
	sta [mb1],y
	sta [mt5],y
	lda vt0+2
	sta [mb2],y
	sta [mt6],y
	lda vt0+3
	sta [mb3],y
	sta [mt7],y
	#AL

	stx vt1
	sec
	lda #$ffff
	sbc vt1
	tay

	#AS
	lda vt0+0
	sta [mb4],y
	lda vt0+1
	sta [mb5],y
	lda vt0+2
	sta [mb6],y
	lda vt0+3
	sta [mb7],y
	#AL

	inx
	bne loop1

loop2
	txa
	lsr
	ora #$8000
	clc
	adc vt0+0
	sta vt0+0
	lda #$0000
	adc vt0+2
	sta vt0+2

	#AS
	txy
	lda vt0+0
	sta [mt0],y
	lda vt0+1
	sta [mt1],y
	lda vt0+2
	sta [mt2],y
	lda vt0+3
	sta [mt3],y
	#AL

	inx
	bne loop2

	; return
	jmp [_ra]
