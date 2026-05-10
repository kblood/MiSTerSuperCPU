
; ----- Defines

	_v0 = ($80 + ( 2 * 4))
	_v1 = ($80 + ( 3 * 4))
	_a0 = ($80 + ( 4 * 4))
	_a1 = ($80 + ( 5 * 4))
	_a2 = ($80 + ( 6 * 4))
	_a3 = ($80 + ( 7 * 4))
	_ra = ($80 + (31 * 4))

; ----- Macros

	AS .macro
	sep #$20
	.as
	.endm

	AL .macro
	rep #$20
	.al
	.endm

	XS .macro
	sep #$10
	.xs
	.endm

	XL .macro
	rep #$10
	.xl
	.endm

	AXS .macro
	sep #$30
	.as
	.xs
	.endm

	AXL .macro
	rep #$30
	.al
	.xl
	.endm

; ----- Code

	.al
	.xl

	* = $1000

	.databank $ff ; fixme

jump_base
	.word _tick_install, _tick_uninstall, _tick
	.word _supercpu_turbo
	.word _keyboard_setup, _keyboard_get, _joystick_get

	.align $100
_tick_install
	sei

	lda #$0000
	sta _tick_count + 0
	sta _tick_count + 2

	#AS

	; Set MMU to RAM at $a000-$bfff and $e000-$ffff
	lda #$35
	sta $01

	; disable timer interrupts
	lda #$7f
	sta $dc0d
	sta $dd0d

	; disable VIC interrupts
	lda #$00
	sta $d01a

	; acknowledge interrupts
	lda $dc0d
	lda $dd0d
	lda #$ff
	sta $d019

	; set NMI vector
	lda #<_tick_irq
	sta $ffea
	lda #>_tick_irq
	sta $ffeb

	; setup timer A on CIA #2 to count 1/100 seconds
	;
	; PAL  =  985248 Hz = ( 985248 / 100) - 1 = 0x267b
	; NTSC = 1022727 Hz = (1022727 / 100) - 1 = 0x27f2
	;lda #$7b
	lda _a0 + 0
	sta $dd04
	;lda #$26
	lda _a0 + 1
	sta $dd05

	; enable timer A interrupt
	lda #%10000001
	sta $dd0d

	; set timer A to run in continuous mode and start it
	lda #%10010001
	sta $dd0e

	cli

	#AL

	; return
	jmp [_ra]

	.align $4
_tick_uninstall
	sei

	#AS

	; disable timer interrupts
	lda #$7f
	sta $dc0d
	sta $dd0d

	; disable VIC interrupts
	lda #$00
	sta $d01a

	; acknowledge interrupts
	lda $dc0d
	lda $dd0d
	lda #$ff
	sta $d019

	cli

	#AL

	; return
	jmp [_ra]

	.align $4
_tick_irq
	#AL
	pha


	clc
	lda _tick_count + 0
	adc #$0001
	sta _tick_count + 0
	lda _tick_count + 2
	adc #$0000
	sta _tick_count + 2

	#AS

	; acknowledge nmi
	lda $dd0d

	#AL
	pla

	rti

_tick_count
	.word 0, 0

	.align $4
_tick
	sei

	lda _tick_count + 0
	sta _v0 + 0
	lda _tick_count + 2
	sta _v0 + 2

	cli

	; return
	jmp [_ra]

	.align $4
_supercpu_turbo
	#AS
	lda #$00

	; stop timers
	sta $dc0e
	sta $dc0f
	sta $dd0e
	sta $dd0f

	; disable sprites
	sta $d015

	; disable VIC interrupts
	sta $d01a

	; disable timer interrupts
	lda #$7f
	sta $dc0d
	sta $dd0d

	; acknowledge interrupts
	lda $dc0d
	lda $dd0d
	lda #$ff
	sta $d019

	sta $d07e ; ENABLE HARDWARE REGISTERS

	lda _a0 + 0
	and #$01
	beq _turbo_off

_turbo_on
	; 20 MHz SCPU mode
	sta $d07b
	; BASIC optimization
	sta $d076
	bra _turbo_done

_turbo_off
	; 1 MHz SCPU mode
	sta $d07a
	; No optimization
	sta $d077

_turbo_done
	sta $d07f ; DISABLE HARDWARE REGISTERS

	#AL

	; return
	jmp [_ra]

	.align $4
_keyboard_setup
	#AS
	lda #$0
	sta $dc03	; port b ddr (input)
	lda #$ff
	sta $dc02	; port a ddr (output)
	#AL

	; return
	jmp [_ra]

	.align $4
_keyboard_get
	lda #$00ff
	sta _v0 + 0
	stz _v0 + 2

	#AS

	lda #$00
	sta $dc00	; port a
	lda $dc01	; port b
	cmp #$ff
	beq nokey

	; got column
	tay

	lda #$7f
	sta nokey2+1
	ldx #8
nokey2
	lda #0
	sta $dc00	; port a

	sec
	lda nokey2+1
	ror
	sta nokey2+1
	dex
	bmi nokey

	lda $dc01	; port b
	cmp #$ff
	beq nokey2

	; got row in x ($00-$07)
	txa
	tyx
	ora columntab,x

	sta _v0 + 0

nokey
	#AL

	; return
	jmp [_ra]

	; translate column bits ($00-$ff) to column index ($00-$38)
	; that is, a single key press = a single zero = a single column index
	; multiple key presses = multiple zeros = not handled = $ff
columntab
	.for i=0,i<256,i=i+1
		.if i = ($ff-$80)
			.byte $70/$02
		.elsif i = ($ff-$40)
			.byte $60/$02
		.elsif i = ($ff-$20)
			.byte $50/$02
		.elsif i = ($ff-$10)
			.byte $40/$02
		.elsif i = ($ff-$08)
			.byte $30/$02
		.elsif i = ($ff-$04)
			.byte $20/$02
		.elsif i = ($ff-$02)
			.byte $10/$02
		.elsif i = ($ff-$01)
			.byte $00/$02
		.else
			.byte $ff
		.endif
	.next

	.align $4
_joystick_get
	#AS

	lda #$ff
	sta $dc00	; port a
	lda $dc00
	eor #$ff

	sta _v0 + 0
	stz _v0 + 1

	#AL

	stz _v0 + 2

	; return
	jmp [_ra]

	.databank $00 ; fixme
