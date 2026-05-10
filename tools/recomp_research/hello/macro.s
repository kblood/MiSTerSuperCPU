
; ----- Defines

	vt0 = ($80 - (25 * 4)) ; multiply temporary
	vt1 = ($80 - (24 * 4)) ; multiply temporary

	mt0 = ($80 - (23 * 4)) ; multiply temporary
	mt1 = ($80 - (22 * 4)) ; multiply temporary
	mt2 = ($80 - (21 * 4)) ; multiply temporary
	mt3 = ($80 - (20 * 4)) ; multiply temporary
	mt4 = ($80 - (19 * 4)) ; multiply temporary
	mt5 = ($80 - (18 * 4)) ; multiply temporary
	mt6 = ($80 - (17 * 4)) ; multiply temporary
	mt7 = ($80 - (16 * 4)) ; multiply temporary

	mb0 = ($80 - (15 * 4)) ; multiply base
	mb1 = ($80 - (14 * 4)) ; multiply base
	mb2 = ($80 - (13 * 4)) ; multiply base
	mb3 = ($80 - (12 * 4)) ; multiply base
	mb4 = ($80 - (11 * 4)) ; multiply base
	mb5 = ($80 - (10 * 4)) ; multiply base
	mb6 = ($80 - ( 9 * 4)) ; multiply base
	mb7 = ($80 - ( 8 * 4)) ; multiply base

	_x0 = ($80 - ( 7 * 4)) ; reserved for recompiler
	_x1 = ($80 - ( 6 * 4)) ; reserved for recompiler
	_x2 = ($80 - ( 5 * 4)) ; reserved for recompiler
	_x3 = ($80 - ( 4 * 4)) ; reserved for recompiler
	_x4 = ($80 - ( 3 * 4)) ; reserved for recompiler

	_lo = ($80 - ( 2 * 4))
	_hi = ($80 - ( 1 * 4))

	_rq = _lo
	_rr = _hi

	_z0 = ($80 + ( 0 * 4))
	_at = ($80 + ( 1 * 4))
	_v0 = ($80 + ( 2 * 4))
	_v1 = ($80 + ( 3 * 4))
	_a0 = ($80 + ( 4 * 4))
	_a1 = ($80 + ( 5 * 4))
	_a2 = ($80 + ( 6 * 4))
	_a3 = ($80 + ( 7 * 4))
	_t0 = ($80 + ( 8 * 4))
	_t1 = ($80 + ( 9 * 4))
	_t2 = ($80 + (10 * 4))
	_t3 = ($80 + (11 * 4))
	_t4 = ($80 + (12 * 4))
	_t5 = ($80 + (13 * 4))
	_t6 = ($80 + (14 * 4))
	_t7 = ($80 + (15 * 4))
	_s0 = ($80 + (16 * 4))
	_s1 = ($80 + (17 * 4))
	_s2 = ($80 + (18 * 4))
	_s3 = ($80 + (19 * 4))
	_s4 = ($80 + (20 * 4))
	_s5 = ($80 + (21 * 4))
	_s6 = ($80 + (22 * 4))
	_s7 = ($80 + (23 * 4))
	_t8 = ($80 + (24 * 4))
	_t9 = ($80 + (25 * 4))
	_k0 = ($80 + (26 * 4))
	_k1 = ($80 + (27 * 4))
	_gp = ($80 + (28 * 4))
	_sp = ($80 + (29 * 4))
	_s8 = ($80 + (30 * 4))
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
