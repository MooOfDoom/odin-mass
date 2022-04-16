package main

import "core:fmt"

SIB_Scale_1 :u8: 0b00
SIB_Scale_2 :u8: 0b01
SIB_Scale_4 :u8: 0b10
SIB_Scale_8 :u8: 0b11

MOD_Displacement_0   :u8: 0b00
MOD_Displacement_i8  :u8: 0b01
MOD_Displacement_i32 :u8: 0b10
MOD_Register         :u8: 0b11

REX   :u8: 0b01000000
REX_W :u8: 0b01001000 // 0 = Operand size determined by CS.D; 1 = 64 Bit Operand Size
REX_R :u8: 0b01000100 // Extension of the ModR/M reg field
REX_X :u8: 0b01000010 // Extension of the SIB index field
REX_B :u8: 0b01000001 // Extension of the ModR/M r/m field, SIB base field, or Opcode reg field

encode_instruction :: proc(builder: ^Fn_Builder, instruction: Instruction)
{
	instruction := instruction
	
	buffer := builder.buffer
	
	if instruction.maybe_label != nil
	{
		label := instruction.maybe_label
		assert(label.target == nil)
		label.target = &buffer.memory[buffer.occupied]
		
		for location in label.locations
		{
			diff := i32(uintptr(label.target) - uintptr(location.from_offset))
			assert(diff >= 0)
			location.patch_target^ = diff
		}
		clear(&label.locations)
		return
	}
	
	operand_count := len(instruction.operands)
	encoding_loop: for encoding in &instruction.mnemonic.encoding_list
	{
		for operand_index in 0 ..< operand_count
		{
			operand_encoding := &encoding.operands[operand_index]
			operand          := &instruction.operands[operand_index]
			if operand.byte_size != i32(operand_encoding.size)
			{
				continue encoding_loop
			}
			
			if operand.type == .None && operand_encoding.type == .None
			{
				continue
			}
			if operand.type == .Register && operand_encoding.type == .Register
			{
				continue
			}
			if operand.type == .Register && operand_encoding.type == .Register_Memory
			{
				continue
			}
			if operand.type == .RIP_Relative && operand_encoding.type == .Register_Memory
			{
				continue
			}
			if operand.type == .Memory_Indirect && operand_encoding.type == .Register_Memory
			{
				continue
			}
			if operand.type == .RIP_Relative && operand_encoding.type == .Memory
			{
				continue
			}
			if operand.type == .Memory_Indirect && operand_encoding.type == .Memory
			{
				continue
			}
			if operand_encoding.type == .Immediate
			{
				if operand.type == .Immediate_8 && operand_encoding.size == .Size_8
				{
					continue
				}
				if operand.type == .Label_32 && operand_encoding.size == .Size_32
				{
					continue
				}
				if operand.type == .Immediate_32 && operand_encoding.size == .Size_32
				{
					continue
				}
				if operand.type == .Immediate_64 && operand_encoding.size == .Size_64
				{
					continue
				}
			}
			continue encoding_loop
		}
		
		needs_mod_r_m:  bool
		reg_or_op_code: u8
		rex_byte:       u8
		r_m:            u8
		mod := MOD_Register
		op_code := encoding.op_code
		needs_sib: bool
		sib_byte:  u8
		
		encoding_stack_operand: bool
		
		for operand_index in 0 ..< operand_count
		{
			operand          := &instruction.operands[operand_index]
			operand_encoding := &encoding.operands[operand_index]
			
			if operand.byte_size == 8
			{
				rex_byte |= REX_W
			}
			
			if operand.type == .Register
			{
				if operand_encoding.type == .Register
				{
					assert(encoding.extension_type != .Op_Code)
					
					if encoding.extension_type == .Plus_Register
					{
						op_code[1] += u8(operand.reg) & 0b111
						if u8(operand.reg) & 0b1000 != 0
						{
							rex_byte |= REX_B
						}
					}
					else
					{
						reg_or_op_code = u8(operand.reg) & 0b111
						if u8(operand.reg) & 0b1000 != 0
						{
							rex_byte |= REX_R
						}
					}
				}
			}
			if (operand_encoding.type == .Register_Memory ||
			    operand_encoding.type == .Memory)
			{
				needs_mod_r_m = true
				if operand.type == .RIP_Relative
				{
					mod = 0b00
					r_m = 0b101
				}
				else if operand.type == .Register
				{
					mod = MOD_Register
					r_m = u8(operand.reg) & 0b111
					if u8(operand.reg) & 0b1000 != 0
					{
						rex_byte |= REX_B
					}
				}
				else
				{
					assert(operand.type == .Memory_Indirect)
					mod = MOD_Displacement_i32
					r_m = u8(operand.indirect.reg)
					if r_m == u8(rsp.reg)
					{
						encoding_stack_operand = true
						needs_sib = true
						// FIXME support proper SIB for non-rsp registers
						sib_byte = ((SIB_Scale_1 << 6) |
						            (r_m << 3) |
						            (r_m))
					}
				}
			}
		}
		
		if encoding.extension_type == .Op_Code
		{
			reg_or_op_code = encoding.op_code_extension
		}
		
		if encoding.explicit_byte_size == 8
		{
			rex_byte |= REX_W
		}
		
		if rex_byte != 0
		{
			buffer_append(buffer, rex_byte)
		}
		
		// FIXME if op code is 2 bytes need different append
		if op_code[0] != 0
		{
			buffer_append(buffer, op_code[0])
		}
		buffer_append(buffer, op_code[1])
		
		// FIXME Implement proper mod support
		// FIXME mask register index
		if needs_mod_r_m
		{
			mod_r_m: u8 = ((mod << 6) |
			               (reg_or_op_code << 3) |
			               (r_m))
			buffer_append(buffer, mod_r_m)
		}
		
		if needs_sib
		{
			buffer_append(buffer, sib_byte)
		}
		
		offset_of_displacement: int
		stack_byte_size: i32
		
		// Write out displacement
		if needs_mod_r_m && mod != MOD_Register
		{
			for operand_index in 0 ..< len(instruction.operands)
			{
				operand := &instruction.operands[operand_index]
				if operand.type == .RIP_Relative
				{
					start_address := i64(uintptr(&buffer.memory[0]))
					end_address := start_address + i64(len(buffer.memory))
					assert(operand.imm64 >= start_address && operand.imm64 < end_address)
					next_instruction_address := start_address + i64(buffer.occupied) + size_of(i32)
					
					displacement_i64 := operand.imm64 - next_instruction_address
					assert(displacement_i64 >= i64(min(i32)) && displacement_i64 < i64(max(i32)))
					displacement := i32(displacement_i64)
					
					buffer_append(buffer, displacement)
				}
				else if operand.type == .Memory_Indirect
				{
					if encoding_stack_operand
					{
						offset_of_displacement = buffer.occupied
						stack_byte_size = operand.byte_size
					}
					if mod == MOD_Displacement_i32
					{
						buffer_append(buffer, operand.indirect.displacement)
					}
					else if mod == MOD_Displacement_i8
					{
						buffer_append(buffer, i8(operand.indirect.displacement))
					}
					else
					{
						assert(mod == MOD_Displacement_0)
					}
				}
			}
		}
		// Write out immediate operand(s?)
		for operand in &instruction.operands
		{
			if operand.type == .Immediate_8
			{
				buffer_append(buffer, operand.imm8)
			}
			else if operand.type == .Label_32
			{
				if operand.label32.target != nil
				{
					from := &buffer.memory[buffer.occupied + size_of(i32)]
					diff := i32(uintptr(operand.label32.target) - uintptr(from))
					buffer_append(buffer, diff)
				}
				else
				{
					patch_target := cast(^i32)&buffer.memory[buffer.occupied]
					buffer_append(buffer, i32(TO_BE_PATCHED))
					append(&operand.label32.locations, Label_Location{patch_target, &buffer.memory[buffer.occupied]})
				}
			}
			else if operand.type == .Immediate_32
			{
				buffer_append(buffer, operand.imm32)
			}
			else if operand.type == .Immediate_64
			{
				buffer_append(buffer, operand.imm64)
			}
		}
		
		if offset_of_displacement != 0
		{
			location := cast(^i32)(&builder.buffer.memory[offset_of_displacement])
			append(&builder.stack_displacements, Stack_Patch \
			{
				location = location,
				byte_size = stack_byte_size,
			})
		}
		return
	}
	fmt.printf("%v", instruction.mnemonic.name)
	for operand in &instruction.operands
	{
		fmt.printf(" ")
		print_operand(&operand)
	}
	fmt.println()
	// Didn't find any encoding
	assert(false, "Did not find acceptable encoding")
}
