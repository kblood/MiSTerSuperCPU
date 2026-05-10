	#
	# start.s
	#

	.text
	.balign 4

	.global _start

	.set noreorder

_start:
	# clear bss
	la $2,__sbss_start
	la $4,__bss_end
	sltu $3,$2,$4
	beq	$3,$0,bss_done
	nop

bss_loop:
	sw $0,0($2)
	addiu $2,$2,4
	sltu $3,$2,$4
	bne	$3,$0,bss_loop
	nop

bss_done:
	# load stack pointer
	la $sp,_sp

	# load global pointer
	la $gp,_gp

	# set empty arguments
	li $a0,1
	la $a1,argv

	# jump to main
	jal main
	nop

	# loop forever
inf_loop:
	j inf_loop
	nop

	.set reorder

	.data
	.balign 4
argv:
	.word filename
filename:
	.word 0x00000000
