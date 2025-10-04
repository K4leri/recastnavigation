	.text
	.def	@feat.00;
	.scl	3;
	.type	0;
	.endef
	.globl	@feat.00
.set @feat.00, 0
	.intel_syntax noprefix
	.file	"asm_test"
	.def	testDistanceCalculation;
	.scl	2;
	.type	32;
	.endef
	.globl	testDistanceCalculation
	.p2align	4, 0x90
testDistanceCalculation:
.Lfunc_begin0:
	.cv_func_id 0
	.cv_file	1 "E:\\Projects\\CS2\\navMesh\\movement\\fullProject\\recast\\zig-recast\\bench\\asm_test.zig"
	.cv_loc	0 1 3 0
.seh_proc testDistanceCalculation
	push	rbp
	.seh_pushreg rbp
	mov	rbp, rsp
	.seh_setframe rbp, 0
	.seh_endprologue
.Ltmp0:
	.cv_loc	0 1 6 24
	vsubss	xmm1, xmm1, dword ptr [rbp + 48]
.Ltmp1:
	.cv_loc	0 1 7 24
	vsubss	xmm2, xmm2, dword ptr [rbp + 56]
.Ltmp2:
	.cv_loc	0 1 5 24
	vsubss	xmm0, xmm0, xmm3
.Ltmp3:
	.cv_loc	0 1 10 5
	.cv_loc	0 1 9 23
	vmulss	xmm0, xmm0, xmm0
	.cv_loc	0 1 9 43
	vmulss	xmm1, xmm1, xmm1
	.cv_loc	0 1 9 33
	vaddss	xmm0, xmm0, xmm1
	.cv_loc	0 1 9 63
	vmulss	xmm1, xmm2, xmm2
	.cv_loc	0 1 9 53
	vaddss	xmm0, xmm0, xmm1
.Ltmp4:
	.cv_loc	0 1 10 5
	pop	rbp
	ret
.Ltmp5:
.Lfunc_end0:
	.seh_endproc

	.def	testVec3Distance;
	.scl	2;
	.type	32;
	.endef
	.globl	testVec3Distance
	.p2align	4, 0x90
testVec3Distance:
.Lfunc_begin1:
	.cv_func_id 1
	.cv_loc	1 1 32 0
.seh_proc testVec3Distance
	push	rbp
	.seh_pushreg rbp
	mov	rbp, rsp
	.seh_setframe rbp, 0
	.seh_endprologue
.Ltmp6:
	vmovss	xmm5, dword ptr [rbp + 48]
	vmovss	xmm4, dword ptr [rbp + 56]
.Ltmp7:
	.cv_inline_site_id 2 within 1 inlined_at 1 35 20
	.cv_loc	2 1 24 28
	vsubss	xmm0, xmm3, xmm0
.Ltmp8:
	.cv_loc	1 1 35 5
.Ltmp9:
	.cv_loc	2 1 27 19
	vmulss	xmm0, xmm0, xmm0
.Ltmp10:
	.cv_loc	2 1 25 28
	vsubss	xmm1, xmm5, xmm1
.Ltmp11:
	.cv_loc	2 1 26 28
	vsubss	xmm2, xmm4, xmm2
.Ltmp12:
	.cv_loc	2 1 27 29
	vmulss	xmm1, xmm1, xmm1
.Ltmp13:
	.cv_loc	2 1 27 24
	vaddss	xmm0, xmm0, xmm1
	.cv_loc	2 1 27 39
	vmulss	xmm1, xmm2, xmm2
	.cv_loc	2 1 27 34
	vaddss	xmm0, xmm0, xmm1
.Ltmp14:
	.cv_loc	1 1 35 5
	pop	rbp
	ret
.Ltmp15:
.Lfunc_end1:
	.seh_endproc

	.def	testDecodePolyId;
	.scl	2;
	.type	32;
	.endef
	.globl	testDecodePolyId
	.p2align	4, 0x90
testDecodePolyId:
.Lfunc_begin2:
	.cv_func_id 3
	.cv_loc	3 1 39 0
.seh_proc testDecodePolyId
	push	rbp
	.seh_pushreg rbp
	mov	rbp, rsp
	.seh_setframe rbp, 0
	.seh_endprologue
.Ltmp16:
	.cv_loc	3 1 40 47
	lea	eax, [r8 + rdx]
	.cv_loc	3 1 43 41
	and	r9b, 31
.Ltmp17:
	.cv_loc	3 1 44 41
	and	r8b, 31
.Ltmp18:
	.cv_loc	3 1 51 5
	.cv_loc	3 1 47 23
	shrx	eax, ecx, eax
	bzhi	r9d, eax, r9d
.Ltmp19:
	.cv_loc	3 1 48 23
	shrx	eax, ecx, edx
	.cv_loc	3 1 45 41
	and	dl, 31
.Ltmp20:
	.cv_loc	3 1 48 23
	bzhi	r8d, eax, r8d
.Ltmp21:
	.cv_loc	3 1 49 5
	bzhi	eax, ecx, edx
.Ltmp22:
	.cv_loc	3 1 51 17
	add	eax, r8d
.Ltmp23:
	.cv_loc	3 1 51 24
	add	eax, r9d
	.cv_loc	3 1 51 5
	pop	rbp
	ret
.Ltmp24:
.Lfunc_end2:
	.seh_endproc

	.section	.debug$S,"dr"
	.p2align	2, 0x0
	.long	4
	.long	241
	.long	.Ltmp26-.Ltmp25
.Ltmp25:
	.short	.Ltmp28-.Ltmp27
.Ltmp27:
	.short	4353
	.long	0
	.byte	0
	.p2align	2, 0x0
.Ltmp28:
	.short	.Ltmp30-.Ltmp29
.Ltmp29:
	.short	4412
	.long	0
	.short	208
	.short	0
	.short	14
	.short	0
	.short	0
	.short	19017
	.short	0
	.short	0
	.short	0
	.asciz	"zig 0.14.0"
	.p2align	2, 0x0
.Ltmp30:
.Ltmp26:
	.p2align	2, 0x0
	.long	246
	.long	.Ltmp32-.Ltmp31
.Ltmp31:
	.long	0


	.long	4102
	.cv_filechecksumoffset	1
	.long	23
.Ltmp32:
	.p2align	2, 0x0
	.long	241
	.long	.Ltmp34-.Ltmp33
.Ltmp33:
	.short	.Ltmp36-.Ltmp35
.Ltmp35:
	.short	4423
	.long	0
	.long	0
	.long	0
	.long	.Lfunc_end0-testDistanceCalculation
	.long	0
	.long	0
	.long	4105
	.secrel32	testDistanceCalculation
	.secidx	testDistanceCalculation
	.byte	129
	.asciz	"testDistanceCalculation"
	.p2align	2, 0x0
.Ltmp36:
	.short	.Ltmp38-.Ltmp37
.Ltmp37:
	.short	4114
	.long	8
	.long	0
	.long	0
	.long	0
	.long	0
	.short	0
	.long	1220608
	.p2align	2, 0x0
.Ltmp38:
	.short	.Ltmp40-.Ltmp39
.Ltmp39:
	.short	4414
	.long	64
	.short	1
	.asciz	"center_x"
	.p2align	2, 0x0
.Ltmp40:
	.cv_def_range	 .Lfunc_begin0 .Ltmp3, reg, 154
	.short	.Ltmp42-.Ltmp41
.Ltmp41:
	.short	4414
	.long	64
	.short	1
	.asciz	"center_y"
	.p2align	2, 0x0
.Ltmp42:
	.cv_def_range	 .Lfunc_begin0 .Ltmp1, reg, 155
	.short	.Ltmp44-.Ltmp43
.Ltmp43:
	.short	4414
	.long	64
	.short	1
	.asciz	"center_z"
	.p2align	2, 0x0
.Ltmp44:
	.cv_def_range	 .Lfunc_begin0 .Ltmp2, reg, 156
	.short	.Ltmp46-.Ltmp45
.Ltmp45:
	.short	4414
	.long	64
	.short	1
	.asciz	"closest_x"
	.p2align	2, 0x0
.Ltmp46:
	.cv_def_range	 .Lfunc_begin0 .Lfunc_end0, reg, 157
	.short	.Ltmp48-.Ltmp47
.Ltmp47:
	.short	4414
	.long	64
	.short	1
	.asciz	"closest_y"
	.p2align	2, 0x0
.Ltmp48:
	.cv_def_range	 .Ltmp0 .Lfunc_end0, frame_ptr_rel, 48
	.short	.Ltmp50-.Ltmp49
.Ltmp49:
	.short	4414
	.long	64
	.short	1
	.asciz	"closest_z"
	.p2align	2, 0x0
.Ltmp50:
	.cv_def_range	 .Ltmp0 .Lfunc_end0, frame_ptr_rel, 56
	.short	.Ltmp52-.Ltmp51
.Ltmp51:
	.short	4414
	.long	4106
	.short	256
	.asciz	"diff"
	.p2align	2, 0x0
.Ltmp52:
	.short	.Ltmp54-.Ltmp53
.Ltmp53:
	.short	4414
	.long	64
	.short	0
	.asciz	"d"
	.p2align	2, 0x0
.Ltmp54:
	.cv_def_range	 .Ltmp4 .Lfunc_end0, reg, 154
	.short	2
	.short	4431
.Ltmp34:
	.p2align	2, 0x0
	.cv_linetable	0, testDistanceCalculation, .Lfunc_end0
	.long	241
	.long	.Ltmp56-.Ltmp55
.Ltmp55:
	.short	.Ltmp58-.Ltmp57
.Ltmp57:
	.short	4423
	.long	0
	.long	0
	.long	0
	.long	.Lfunc_end1-testVec3Distance
	.long	0
	.long	0
	.long	4107
	.secrel32	testVec3Distance
	.secidx	testVec3Distance
	.byte	129
	.asciz	"testVec3Distance"
	.p2align	2, 0x0
.Ltmp58:
	.short	.Ltmp60-.Ltmp59
.Ltmp59:
	.short	4114
	.long	8
	.long	0
	.long	0
	.long	0
	.long	0
	.short	0
	.long	1220608
	.p2align	2, 0x0
.Ltmp60:
	.short	.Ltmp62-.Ltmp61
.Ltmp61:
	.short	4456
	.long	1
	.long	4102
	.p2align	2, 0x0
.Ltmp62:
	.short	.Ltmp64-.Ltmp63
.Ltmp63:
	.short	4414
	.long	64
	.short	1
	.asciz	"ax"
	.p2align	2, 0x0
.Ltmp64:
	.cv_def_range	 .Lfunc_begin1 .Ltmp8, reg, 154
	.short	.Ltmp66-.Ltmp65
.Ltmp65:
	.short	4414
	.long	64
	.short	1
	.asciz	"ay"
	.p2align	2, 0x0
.Ltmp66:
	.cv_def_range	 .Lfunc_begin1 .Ltmp11, reg, 155
	.short	.Ltmp68-.Ltmp67
.Ltmp67:
	.short	4414
	.long	64
	.short	1
	.asciz	"az"
	.p2align	2, 0x0
.Ltmp68:
	.cv_def_range	 .Lfunc_begin1 .Ltmp12, reg, 156
	.short	.Ltmp70-.Ltmp69
.Ltmp69:
	.short	4414
	.long	64
	.short	1
	.asciz	"bx"
	.p2align	2, 0x0
.Ltmp70:
	.cv_def_range	 .Lfunc_begin1 .Lfunc_end1, reg, 157
	.short	.Ltmp72-.Ltmp71
.Ltmp71:
	.short	4414
	.long	64
	.short	1
	.asciz	"by"
	.p2align	2, 0x0
.Ltmp72:
	.cv_def_range	 .Ltmp6 .Lfunc_end1, frame_ptr_rel, 48
	.short	.Ltmp74-.Ltmp73
.Ltmp73:
	.short	4414
	.long	64
	.short	1
	.asciz	"bz"
	.p2align	2, 0x0
.Ltmp74:
	.cv_def_range	 .Ltmp6 .Lfunc_end1, frame_ptr_rel, 56
	.short	.Ltmp76-.Ltmp75
.Ltmp75:
	.short	4414
	.long	4101
	.short	0
	.asciz	"a"
	.p2align	2, 0x0
.Ltmp76:
	.cv_def_range	 .Ltmp6 .Ltmp8, subfield_reg, 154, 0
	.cv_def_range	 .Ltmp6 .Ltmp11, subfield_reg, 155, 4
	.cv_def_range	 .Ltmp6 .Ltmp12, subfield_reg, 156, 8
	.short	.Ltmp78-.Ltmp77
.Ltmp77:
	.short	4414
	.long	4101
	.short	0
	.asciz	"b"
	.p2align	2, 0x0
.Ltmp78:
	.cv_def_range	 .Ltmp6 .Lfunc_end1, subfield_reg, 157, 0
	.cv_def_range	 .Ltmp6 .Lfunc_end1, reg_rel, 334, 65, 48
	.cv_def_range	 .Ltmp6 .Lfunc_end1, reg_rel, 334, 129, 56
	.short	.Ltmp80-.Ltmp79
.Ltmp79:
	.short	4429
	.long	0
	.long	0
	.long	4102
	.cv_inline_linetable	2 1 23 .Lfunc_begin1 .Lfunc_end1
	.p2align	2, 0x0
.Ltmp80:
	.short	.Ltmp82-.Ltmp81
.Ltmp81:
	.short	4414
	.long	4101
	.short	1
	.asciz	"self"
	.p2align	2, 0x0
.Ltmp82:
	.cv_def_range	 .Lfunc_begin1 .Ltmp8, subfield_reg, 154, 0
	.cv_def_range	 .Lfunc_begin1 .Ltmp11, subfield_reg, 155, 4
	.cv_def_range	 .Lfunc_begin1 .Ltmp12, subfield_reg, 156, 8
	.short	.Ltmp84-.Ltmp83
.Ltmp83:
	.short	4414
	.long	4101
	.short	1
	.asciz	"other"
	.p2align	2, 0x0
.Ltmp84:
	.cv_def_range	 .Lfunc_begin1 .Lfunc_end1, subfield_reg, 157, 0
	.cv_def_range	 .Ltmp6 .Lfunc_end1, reg_rel, 334, 65, 48
	.cv_def_range	 .Ltmp6 .Lfunc_end1, reg_rel, 334, 129, 56
	.short	.Ltmp86-.Ltmp85
.Ltmp85:
	.short	4414
	.long	64
	.short	0
	.asciz	"dx"
	.p2align	2, 0x0
.Ltmp86:
	.cv_def_range	 .Ltmp8 .Ltmp10, reg, 154
	.short	.Ltmp88-.Ltmp87
.Ltmp87:
	.short	4414
	.long	64
	.short	0
	.asciz	"dy"
	.p2align	2, 0x0
.Ltmp88:
	.cv_def_range	 .Ltmp11 .Ltmp13, reg, 155
	.short	.Ltmp90-.Ltmp89
.Ltmp89:
	.short	4414
	.long	64
	.short	0
	.asciz	"dz"
	.p2align	2, 0x0
.Ltmp90:
	.cv_def_range	 .Ltmp12 .Lfunc_end1, reg, 156
	.short	2
	.short	4430
	.short	2
	.short	4431
.Ltmp56:
	.p2align	2, 0x0
	.cv_linetable	1, testVec3Distance, .Lfunc_end1
	.long	241
	.long	.Ltmp92-.Ltmp91
.Ltmp91:
	.short	.Ltmp94-.Ltmp93
.Ltmp93:
	.short	4423
	.long	0
	.long	0
	.long	0
	.long	.Lfunc_end2-testDecodePolyId
	.long	0
	.long	0
	.long	4110
	.secrel32	testDecodePolyId
	.secidx	testDecodePolyId
	.byte	129
	.asciz	"testDecodePolyId"
	.p2align	2, 0x0
.Ltmp94:
	.short	.Ltmp96-.Ltmp95
.Ltmp95:
	.short	4114
	.long	8
	.long	0
	.long	0
	.long	0
	.long	0
	.short	0
	.long	1220608
	.p2align	2, 0x0
.Ltmp96:
	.short	.Ltmp98-.Ltmp97
.Ltmp97:
	.short	4414
	.long	117
	.short	1
	.asciz	"ref"
	.p2align	2, 0x0
.Ltmp98:
	.cv_def_range	 .Lfunc_begin2 .Lfunc_end2, reg, 18
	.short	.Ltmp100-.Ltmp99
.Ltmp99:
	.short	4414
	.long	32
	.short	1
	.asciz	"poly_bits"
	.p2align	2, 0x0
.Ltmp100:
	.cv_def_range	 .Lfunc_begin2 .Ltmp20, reg, 3
	.short	.Ltmp102-.Ltmp101
.Ltmp101:
	.short	4414
	.long	32
	.short	1
	.asciz	"tile_bits"
	.p2align	2, 0x0
.Ltmp102:
	.cv_def_range	 .Lfunc_begin2 .Ltmp18, reg, 344
	.short	.Ltmp104-.Ltmp103
.Ltmp103:
	.short	4414
	.long	32
	.short	1
	.asciz	"salt_bits"
	.p2align	2, 0x0
.Ltmp104:
	.cv_def_range	 .Lfunc_begin2 .Ltmp17, reg, 345
	.short	.Ltmp106-.Ltmp105
.Ltmp105:
	.short	4414
	.long	32
	.short	256
	.asciz	"salt_shift"
	.p2align	2, 0x0
.Ltmp106:
	.short	.Ltmp108-.Ltmp107
.Ltmp107:
	.short	4414
	.long	32
	.short	256
	.asciz	"tile_shift"
	.p2align	2, 0x0
.Ltmp108:
	.short	.Ltmp110-.Ltmp109
.Ltmp109:
	.short	4414
	.long	117
	.short	0
	.asciz	"salt"
	.p2align	2, 0x0
.Ltmp110:
	.cv_def_range	 .Ltmp19 .Lfunc_end2, reg, 361
	.short	.Ltmp112-.Ltmp111
.Ltmp111:
	.short	4414
	.long	117
	.short	256
	.asciz	"tile_mask"
	.p2align	2, 0x0
.Ltmp112:
	.short	.Ltmp114-.Ltmp113
.Ltmp113:
	.short	4414
	.long	117
	.short	0
	.asciz	"tile"
	.p2align	2, 0x0
.Ltmp114:
	.cv_def_range	 .Ltmp21 .Lfunc_end2, reg, 360
	.short	.Ltmp116-.Ltmp115
.Ltmp115:
	.short	4414
	.long	117
	.short	0
	.asciz	"poly"
	.p2align	2, 0x0
.Ltmp116:
	.cv_def_range	 .Ltmp22 .Ltmp23, reg, 17
	.short	.Ltmp118-.Ltmp117
.Ltmp117:
	.short	4414
	.long	117
	.short	256
	.asciz	"salt_mask"
	.p2align	2, 0x0
.Ltmp118:
	.short	.Ltmp120-.Ltmp119
.Ltmp119:
	.short	4414
	.long	117
	.short	256
	.asciz	"poly_mask"
	.p2align	2, 0x0
.Ltmp120:
	.short	2
	.short	4431
.Ltmp92:
	.p2align	2, 0x0
	.cv_linetable	3, testDecodePolyId, .Lfunc_end2
	.long	241
	.long	.Ltmp122-.Ltmp121
.Ltmp121:
	.short	.Ltmp124-.Ltmp123
.Ltmp123:
	.short	4360
	.long	4101
	.asciz	"asm_test.Vec3"
	.p2align	2, 0x0
.Ltmp124:
.Ltmp122:
	.p2align	2, 0x0
	.cv_filechecksums
	.cv_stringtable
	.long	241
	.long	.Ltmp126-.Ltmp125
.Ltmp125:
	.short	.Ltmp128-.Ltmp127
.Ltmp127:
	.short	4428
	.long	4114
	.p2align	2, 0x0
.Ltmp128:
.Ltmp126:
	.p2align	2, 0x0
	.section	.debug$T,"dr"
	.p2align	2, 0x0
	.long	4
	.short	0x22
	.short	0x1505
	.short	0x0
	.short	0x80
	.long	0x0
	.long	0x0
	.long	0x0
	.short	0x0
	.asciz	"asm_test.Vec3"
	.short	0xa
	.short	0x1002
	.long	0x1000
	.long	0x1000c
	.short	0xe
	.short	0x1201
	.long	0x2
	.long	0x1001
	.long	0x1001
	.short	0xe
	.short	0x1008
	.long	0x40
	.byte	0x0
	.byte	0x0
	.short	0x2
	.long	0x1002
	.short	0x26
	.short	0x1203
	.short	0x150d
	.short	0x3
	.long	0x40
	.short	0x0
	.asciz	"x"
	.short	0x150d
	.short	0x3
	.long	0x40
	.short	0x4
	.asciz	"y"
	.short	0x150d
	.short	0x3
	.long	0x40
	.short	0x8
	.asciz	"z"
	.short	0x22
	.short	0x1505
	.short	0x3
	.short	0x0
	.long	0x1004
	.long	0x0
	.long	0x0
	.short	0xc
	.asciz	"asm_test.Vec3"
	.short	0x12
	.short	0x1601
	.long	0x0
	.long	0x1003
	.asciz	"distSq"
	.byte	241
	.short	0x1e
	.short	0x1201
	.long	0x6
	.long	0x40
	.long	0x40
	.long	0x40
	.long	0x40
	.long	0x40
	.long	0x40
	.short	0xe
	.short	0x1008
	.long	0x40
	.byte	0x0
	.byte	0x0
	.short	0x6
	.long	0x1007
	.short	0x22
	.short	0x1601
	.long	0x0
	.long	0x1008
	.asciz	"testDistanceCalculation"
	.short	0xe
	.short	0x1503
	.long	0x40
	.long	0x23
	.short	0xc
	.byte	0
	.byte	241
	.short	0x1e
	.short	0x1601
	.long	0x0
	.long	0x1008
	.asciz	"testVec3Distance"
	.byte	243
	.byte	242
	.byte	241
	.short	0x16
	.short	0x1201
	.long	0x4
	.long	0x75
	.long	0x20
	.long	0x20
	.long	0x20
	.short	0xe
	.short	0x1008
	.long	0x75
	.byte	0x0
	.byte	0x0
	.short	0x4
	.long	0x100c
	.short	0x1e
	.short	0x1601
	.long	0x0
	.long	0x100d
	.asciz	"testDecodePolyId"
	.byte	243
	.byte	242
	.byte	241
	.short	0x4e
	.short	0x1605
	.long	0x0
	.asciz	"E:\\Projects\\CS2\\navMesh\\movement\\fullProject\\recast\\zig-recast\\bench"
	.byte	243
	.byte	242
	.byte	241
	.short	0x12
	.short	0x1605
	.long	0x0
	.asciz	"asm_test"
	.byte	243
	.byte	242
	.byte	241
	.short	0xa
	.short	0x1605
	.long	0x0
	.byte	0
	.byte	243
	.byte	242
	.byte	241
	.short	0x1a
	.short	0x1603
	.short	0x5
	.long	0x100f
	.long	0x0
	.long	0x1010
	.long	0x1011
	.long	0x0
	.byte	242
	.byte	241
