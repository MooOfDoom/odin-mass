package main

import "core:runtime"

Instruction_Extension_Type :: enum
{
	None,
	Register,
	Op_Code,
	Plus_Register,
}

Operand_Encoding_Type :: enum
{
	None,
	Register,
	Register_A,
	Register_Memory,
	Memory,
	Immediate,
}

Operand_Size :: enum
{
	Size_Any = 0,
	Size_8   = 1,
	Size_16  = 2,
	Size_32  = 4,
	Size_64  = 8,
}

Operand_Encoding :: struct
{
	type: Operand_Encoding_Type,
	size: Operand_Size,
}

Instruction_Encoding :: struct
{
	op_code:            [2]u8,
	extension_type:     Instruction_Extension_Type,
	explicit_byte_size: u32,
	op_code_extension:  u8,
	operands:           [3]Operand_Encoding,
}

X64_Mnemonic :: struct
{
	name:          string,
	encoding_list: []Instruction_Encoding,
}

Instruction :: struct
{
	mnemonic:    X64_Mnemonic,
	operands:    [3]Operand,
	maybe_label: ^Label,
	loc:         runtime.Source_Code_Location,
}

@(private="file")
Instruction_Extension :: struct
{
	type: Instruction_Extension_Type,
	ext:  u8,
}

@(private="file") none :: Instruction_Extension{.None, 0}
@(private="file") _r :: Instruction_Extension{.Register, 0}
@(private="file") plus_r :: Instruction_Extension{.Plus_Register, 0}
@(private="file") _op_code :: proc(ext: u8) -> Instruction_Extension { return Instruction_Extension{.Op_Code, ext} }

@(private="file") r_al   :: Operand_Encoding{.Register_A, .Size_8}
@(private="file") r_ax   :: Operand_Encoding{.Register_A, .Size_16}
@(private="file") r_eax  :: Operand_Encoding{.Register_A, .Size_32}
@(private="file") r_rax  :: Operand_Encoding{.Register_A, .Size_64}

@(private="file") r_8    :: Operand_Encoding{.Register, .Size_8}
@(private="file") r_16   :: Operand_Encoding{.Register, .Size_16}
@(private="file") r_32   :: Operand_Encoding{.Register, .Size_32}
@(private="file") r_64   :: Operand_Encoding{.Register, .Size_64}

@(private="file") r_m8   :: Operand_Encoding{.Register_Memory, .Size_8}
@(private="file") r_m16  :: Operand_Encoding{.Register_Memory, .Size_16}
@(private="file") r_m32  :: Operand_Encoding{.Register_Memory, .Size_32}
@(private="file") r_m64  :: Operand_Encoding{.Register_Memory, .Size_64}

@(private="file") m      :: Operand_Encoding{.Memory, .Size_Any}
@(private="file") m_8    :: Operand_Encoding{.Memory, .Size_8}
@(private="file") m_16   :: Operand_Encoding{.Memory, .Size_16}
@(private="file") m_32   :: Operand_Encoding{.Memory, .Size_32}
@(private="file") m_64   :: Operand_Encoding{.Memory, .Size_64}

@(private="file") imm_8  :: Operand_Encoding{.Immediate, .Size_8}
@(private="file") imm_16 :: Operand_Encoding{.Immediate, .Size_16}
@(private="file") imm_32 :: Operand_Encoding{.Immediate, .Size_32}
@(private="file") imm_64 :: Operand_Encoding{.Immediate, .Size_64}

@(private="file")
encoding :: proc(op_code_u16: u16, extension: Instruction_Extension, operands: ..Operand_Encoding) -> Instruction_Encoding
{
	assert(len(operands) <= 3)
	result: Instruction_Encoding =
	{
		op_code           = {u8(op_code_u16 >> 8), u8(op_code_u16)},
		extension_type    = extension.type,
		op_code_extension = (extension.ext & 0b111),
	}
	for op, i in operands
	{
		result.operands[i] = op
	}
	return result
}

////////////////////////////////////////////////////////////////////////////////
// mov
////////////////////////////////////////////////////////////////////////////////
mov_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x88, _r, r_m8,  r_8),
	encoding(0x89, _r, r_m16, r_16),
	encoding(0x89, _r, r_m32, r_32),
	encoding(0x89, _r, r_m64, r_64),
	
	encoding(0x8a, _r, r_8,  r_m8),
	encoding(0x8b, _r, r_16, r_m16),
	encoding(0x8b, _r, r_32, r_m32),
	encoding(0x8b, _r, r_64, r_m64),
	
	encoding(0xc6, _op_code(0), r_m8,  imm_8),
	encoding(0xc7, _op_code(0), r_m16, imm_16),
	encoding(0xc7, _op_code(0), r_m32, imm_32),
	encoding(0xc7, _op_code(0), r_m64, imm_32),
	
	encoding(0xb8, plus_r, r_16, imm_16),
	encoding(0xb8, plus_r, r_32, imm_32),
	encoding(0xb8, plus_r, r_64, imm_64),
}
mov := X64_Mnemonic{name = "mov", encoding_list = mov_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// movsx
////////////////////////////////////////////////////////////////////////////////
movsx_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x0fbe, _r, r_32, r_m8),
	encoding(0x0fbe, _r, r_64, r_m8),
	encoding(0x0fbf, _r, r_32, r_m16),
	encoding(0x0fbf, _r, r_64, r_m16),
}
movsx := X64_Mnemonic{name = "movsx", encoding_list = movsx_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// lea
////////////////////////////////////////////////////////////////////////////////
lea_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x8d, _r, r_64, m),
}
lea := X64_Mnemonic{name = "lea", encoding_list = lea_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// int3
////////////////////////////////////////////////////////////////////////////////
int3_encoding_list := [?]Instruction_Encoding \
{
	encoding(0xcc, none),
}
int3 := X64_Mnemonic{name = "int3", encoding_list = int3_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// ret
////////////////////////////////////////////////////////////////////////////////
ret_encoding_list := [?]Instruction_Encoding \
{
	encoding(0xc3, none),
}
ret := X64_Mnemonic{name = "ret", encoding_list = ret_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// inc
////////////////////////////////////////////////////////////////////////////////
inc_encoding_list := [?]Instruction_Encoding \
{
	encoding(0xff, _r, r_m32),
}
inc := X64_Mnemonic{name = "inc", encoding_list = inc_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// xor
////////////////////////////////////////////////////////////////////////////////
xor_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x32, _r, r_8,  r_m8),
	encoding(0x33, _r, r_16, r_m16),
	encoding(0x33, _r, r_32, r_m32),
	encoding(0x33, _r, r_64, r_m64),
}
xor := X64_Mnemonic{name = "xor", encoding_list = xor_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// add
////////////////////////////////////////////////////////////////////////////////
add_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x04, none, r_al,  imm_8),
	encoding(0x05, none, r_ax,  imm_16),
	encoding(0x05, none, r_eax, imm_32),
	encoding(0x05, none, r_rax, imm_32),
	
	encoding(0x00, _r, r_m8,  r_8),
	encoding(0x01, _r, r_m16, r_16),
	encoding(0x01, _r, r_m32, r_32),
	encoding(0x01, _r, r_m64, r_64),
	
	encoding(0x02, _r, r_8,  r_m8),
	encoding(0x03, _r, r_16, r_m16),
	encoding(0x03, _r, r_32, r_m32),
	encoding(0x03, _r, r_64, r_m64),
	
	encoding(0x80, _op_code(0), r_m8,  imm_8),
	encoding(0x81, _op_code(0), r_m16, imm_16),
	encoding(0x81, _op_code(0), r_m32, imm_32),
	encoding(0x81, _op_code(0), r_m64, imm_32),
	
	encoding(0x83, _op_code(0), r_m16, imm_8),
	encoding(0x83, _op_code(0), r_m32, imm_8),
	encoding(0x83, _op_code(0), r_m64, imm_8),
}
add := X64_Mnemonic{name = "add", encoding_list = add_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// sub
////////////////////////////////////////////////////////////////////////////////
sub_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x28, _r, r_m8,  r_8),
	encoding(0x29, _r, r_m16, r_16),
	encoding(0x29, _r, r_m32, r_32),
	encoding(0x29, _r, r_m64, r_64),
	
	encoding(0x2a, _r, r_8,  r_m8),
	encoding(0x2b, _r, r_16, r_m16),
	encoding(0x2b, _r, r_32, r_m32),
	encoding(0x2b, _r, r_64, r_m64),
	
	encoding(0x80, _op_code(5), r_m8, imm_8),
	encoding(0x81, _op_code(5), r_m16, imm_16),
	encoding(0x81, _op_code(5), r_m32, imm_32),
	encoding(0x81, _op_code(5), r_m64, imm_32),
	
	encoding(0x83, _op_code(5), r_m16, imm_8),
	encoding(0x83, _op_code(5), r_m32, imm_8),
	encoding(0x83, _op_code(5), r_m64, imm_8),
}
sub := X64_Mnemonic{name = "sub", encoding_list = sub_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// imul
////////////////////////////////////////////////////////////////////////////////
imul_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x0faf, _r, r_16, r_m16),
	encoding(0x0faf, _r, r_32, r_m32),
	encoding(0x0faf, _r, r_64, r_m64),
	
	encoding(0x69, _r, r_16, r_m16, imm_16),
	encoding(0x69, _r, r_32, r_m32, imm_32),
	encoding(0x69, _r, r_64, r_m64, imm_32),
}
imul := X64_Mnemonic{name = "imul", encoding_list = imul_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// idiv
////////////////////////////////////////////////////////////////////////////////
idiv_encoding_list := [?]Instruction_Encoding \
{
	encoding(0xf6, _op_code(7), r_m8),
	encoding(0xf7, _op_code(7), r_m16),
	encoding(0xf7, _op_code(7), r_m32),
	encoding(0xf7, _op_code(7), r_m64),
}
idiv := X64_Mnemonic{name = "idiv", encoding_list = idiv_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// cwd/cdq/cqo
////////////////////////////////////////////////////////////////////////////////
cqo_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x4899, none),
}
cqo := X64_Mnemonic{name = "cqo", encoding_list = cqo_encoding_list[:]}

cdq_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x99, none),
}
cdq := X64_Mnemonic{name = "cdq", encoding_list = cdq_encoding_list[:]}

cwd_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x99, none),
}
cwd := X64_Mnemonic{name = "cwd", encoding_list = cwd_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// call
////////////////////////////////////////////////////////////////////////////////
call_encoding_list := [?]Instruction_Encoding \
{
	encoding(0xe8, none, imm_16),
	encoding(0xe8, none, imm_32),
	
	encoding(0xff, _op_code(2), r_m16),
	encoding(0xff, _op_code(2), r_m32),
	encoding(0xff, _op_code(2), r_m64),
}
call := X64_Mnemonic{name = "call", encoding_list = call_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// cmp
////////////////////////////////////////////////////////////////////////////////
cmp_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x80, _op_code(7), r_m8,  imm_8),
	encoding(0x81, _op_code(7), r_m16, imm_16),
	encoding(0x81, _op_code(7), r_m32, imm_32),
	encoding(0x81, _op_code(7), r_m64, imm_32),
	
	encoding(0x38, _r, r_m8,  r_8),
	encoding(0x39, _r, r_m16, r_16),
	encoding(0x39, _r, r_m32, r_32),
	encoding(0x39, _r, r_m64, r_64),
	
	encoding(0x3a, _r, r_8,  r_m8),
	encoding(0x3b, _r, r_16, r_m16),
	encoding(0x3b, _r, r_32, r_m32),
	encoding(0x3b, _r, r_64, r_m64),
}
cmp := X64_Mnemonic{name = "cmp", encoding_list = cmp_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// jnz
////////////////////////////////////////////////////////////////////////////////
jnz_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x75, none, imm_8),
	encoding(0x0f85, none, imm_32),
}
jnz := X64_Mnemonic{name = "jnz", encoding_list = jnz_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// jz
////////////////////////////////////////////////////////////////////////////////
jz_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x0f84, none, imm_32),
}
jz := X64_Mnemonic{name = "jz", encoding_list = jz_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// setz
////////////////////////////////////////////////////////////////////////////////
setz_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x0f94, none, r_m8),
}
setz := X64_Mnemonic{name = "setz", encoding_list = setz_encoding_list[:]}
sete := X64_Mnemonic{name = "sete", encoding_list = setz_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// setne
////////////////////////////////////////////////////////////////////////////////
setne_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x0f95, none, r_m8),
}
setne := X64_Mnemonic{name = "setne", encoding_list = setne_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// setl
////////////////////////////////////////////////////////////////////////////////
setl_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x0f9c, none, r_m8),
}
setl := X64_Mnemonic{name = "setl", encoding_list = setl_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// setg
////////////////////////////////////////////////////////////////////////////////
setg_encoding_list := [?]Instruction_Encoding \
{
	encoding(0x0f9f, none, r_m8),
}
setg := X64_Mnemonic{name = "setg", encoding_list = setg_encoding_list[:]}

////////////////////////////////////////////////////////////////////////////////
// jmp
////////////////////////////////////////////////////////////////////////////////
jmp_encoding_list := [?]Instruction_Encoding \
{
	encoding(0xeb, none, imm_8),
	encoding(0xe9, none, imm_32),
}
jmp := X64_Mnemonic{name = "jmp", encoding_list = jmp_encoding_list[:]}
