package main

import "core:fmt"
import "core:mem"
import "core:runtime"
import "core:strings"
import "core:sys/win32"

TO_BE_PATCHED     :i32: -858993460 // 0xcccccccc
TO_BE_PATCHED_i64 :i64: -3689348814741910324 // 0xcccccccccccccccc

Struct_Builder_Field :: struct
{
	struct_field: Descriptor_Struct_Field,
	next:         ^Struct_Builder_Field,
}

Struct_Builder :: struct
{
	offset:      i32,
	field_count: u32,
	max_size:    i32,
	field_list:  ^Struct_Builder_Field,
}

reserve_stack :: proc(builder: ^Function_Builder, descriptor: ^Descriptor) -> ^Value
{
	byte_size := descriptor_byte_size(descriptor)
	builder.stack_reserve += byte_size
	operand := stack(-builder.stack_reserve, byte_size)
	result := new_clone(Value \
	{
		descriptor = descriptor,
		operand    = operand,
	})
	return result
}

push_instruction :: proc(builder: ^Function_Builder, instruction: Instruction)
{
	append(&builder.instructions, instruction)
}

ensure_register_or_memory :: proc(builder: ^Function_Builder, value: ^Value) -> ^Value
{
	assert(value.operand.type != .None, "Expected valid operand type")
	if operand_is_immediate(&value.operand)
	{
		result := value_register_for_descriptor(.A, value.descriptor)
		move_value(builder, result, value)
		return result
	}
	return value
}

ensure_register :: proc(builder: ^Function_Builder, value: ^Value, reg: Register) -> ^Value
{
	assert(value.operand.type != .None, "Expected valid operand type")
	if value.operand.type != .Register
	{
		result := value_register_for_descriptor(reg, value.descriptor)
		// NOTE(Lothar): Need to zero out the high bits because we only move the index_value into R10 in ensure register
		// but SIB uses the whole thing!
		// TODO(Lothar): Figure out a better way to go about it
		full_reg := Operand{type = .Register, byte_size = 8, data = {reg = reg}}
		push_instruction(builder, {xor, {full_reg, full_reg, {}}, nil, #location()})
		move_value(builder, result, value)
		return result
	}
	return value
}

move_value :: proc(builder: ^Function_Builder, target: ^Value, source: ^Value, loc := #caller_location)
{
	// TODO figure out more type checking
	target_size := descriptor_byte_size(target.descriptor)
	source_size := descriptor_byte_size(source.descriptor)
	
	if target_size != source_size
	{
		if source_size < target_size
		{
			// TODO deal with unsigned numbers
			source_rm := ensure_register_or_memory(builder, source)
			if target.operand.type == .Register
			{
				if source_size == 4
				{
					adjusted_target: Operand =
					{
						type      = .Register,
						byte_size = 4,
						data      = {reg = target.operand.reg},
					}
					push_instruction(builder, {mov, {adjusted_target, source_rm.operand, {}}, nil, loc})
				}
				else
				{
					push_instruction(builder, {movsx, {target.operand, source_rm.operand, {}}, nil, loc})
				}
			}
			else
			{
				reg_a := value_register_for_descriptor(.A, target.descriptor)
				push_instruction(builder, {movsx, {reg_a.operand, source_rm.operand, {}}, nil, loc})
				push_instruction(builder, {mov, {target.operand, reg_a.operand, {}}, nil, loc})
			}
			return
		}
		else
		{
			print_operand(&target.operand)
			fmt.printf(" ")
			print_operand(&source.operand)
			fmt.println()
			assert(false, "Mismatched operand size when moving")
		}
	}
	
	if operand_is_memory(&target.operand) && operand_is_memory(&source.operand)
	{
		reg_a := value_register_for_descriptor(.A, target.descriptor)
		move_value(builder, reg_a, source, loc)
		move_value(builder, target, reg_a, loc)
		return
	}
	
	if (target.operand.type == .Register &&
	    ((source.operand.type == .Immediate_8 && source.operand.imm8 == 0) ||
	     (source.operand.type == .Immediate_32 && source.operand.imm32 == 0) ||
	     (source.operand.type == .Immediate_64 && source.operand.imm64 == 0)))
	{
		// This messes up flags register so comparisons need to be aware of this optimization
		push_instruction(builder, {xor, {target.operand, target.operand, {}}, nil, loc})
		return
	}
	
	// if (source.operand.type == .Immediate_64 && source.operand.imm64 == i64(i32(source.operand.imm64)))
	// {
	// 	move_value(builder, target, value_from_i32(i32(source.operand.imm64)), loc)
	// 	return
	// }
	
	if ((source.operand.type == .Immediate_64 &&
	     target.operand.type != .Register) ||
	    (operand_is_memory(&target.operand) &&
	     operand_is_memory(&source.operand)))
	{
		reg_a := value_register_for_descriptor(.A, target.descriptor)
		// TODO Can be a problem if RAX is already used as temp
		move_value(builder, reg_a, source, loc)
		move_value(builder, target, reg_a, loc)
	}
	else
	{
		push_instruction(builder, {mov, {target.operand, source.operand, {}}, nil, loc})
	}
}

fn_begin :: proc(program: ^Program) -> (result: ^Value, builder: ^Function_Builder)
{
	append(&program.functions, Function_Builder \
	{
		program      = program,
		instructions = make([dynamic]Instruction, 0, 32, runtime.default_allocator()),
		prolog_label = make_label(),
		epilog_label = make_label(),
		result       = new_clone(Value \
		{
			descriptor = new_clone(Descriptor \
			{
				type = .Function,
				data = {function =
				{
					arguments = make([dynamic]^Value, 0, 16),
				}},
			}),
		}),
	})
	// NOTE(Lothar): DANGER: Pointing into dynamic array!
	builder = &program.functions[len(program.functions) - 1]
	result = builder.result
	result.operand = label32(builder.prolog_label)
	
	return result, builder
}

fn_ensure_frozen :: proc(function: ^Descriptor_Function)
{
	if function.frozen do return
	
	if function.returns == nil
	{
		function.returns = &void_value
	}
	function.frozen = true
}

fn_freeze :: proc(builder: ^Function_Builder)
{
	fn_ensure_frozen(&builder.result.descriptor.function)
}

fn_is_frozen :: proc(builder: ^Function_Builder) -> bool
{
	return builder.result.descriptor.function.frozen
}

fn_end :: proc(builder: ^Function_Builder, loc := #caller_location)
{
	alignment :: 0x8
	builder.stack_reserve += builder.max_call_parameters_stack_size
	builder.stack_reserve = align(builder.stack_reserve, 16) + alignment
	
	fn_freeze(builder)
}

fn_encode :: proc(buffer: ^Buffer, builder: ^Function_Builder, loc := #caller_location)
{
	code_start := buffer.occupied
	
	encode_instruction(buffer, builder, {maybe_label = builder.prolog_label, loc = loc})
	encode_instruction(buffer, builder, {sub, {rsp, imm_auto(builder.stack_reserve), {}}, nil, loc});
	
	for instruction, i in &builder.instructions
	{
		encode_instruction(buffer, builder, instruction)
	}
	
	encode_instruction(buffer, builder, {maybe_label = builder.epilog_label, loc = loc})
	
	encode_instruction(buffer, builder, {add, {rsp, imm_auto(builder.stack_reserve), {}}, nil, loc})
	encode_instruction(buffer, builder, {ret, {}, nil, loc})
	encode_instruction(buffer, builder, {int3, {}, nil, loc})
	
	delete(builder.instructions)
}

program_end :: proc(program: ^Program, loc := #caller_location) -> Jit_Program
{
	code_buffer_size := estimate_max_code_size_in_bytes(program)
	result: Jit_Program =
	{
		code_buffer = make_buffer(code_buffer_size, PAGE_READWRITE),
		data_buffer = program.data_buffer,
	}
	program.code_base_rva = i64(uintptr(&result.code_buffer.memory[0]))
	program.data_base_rva = i64(uintptr(&result.data_buffer.memory[0]))
	
	for lib in &program.import_libraries
	{
		dll_handle := win32.load_library_a(strings.clone_to_cstring(lib.name))
		assert(dll_handle != nil, "DLL could not be loaded")
		for sym in &lib.symbols
		{
			sym_address := win32.get_proc_address(dll_handle, strings.clone_to_cstring(sym.name))
			assert(sym_address != nil, "Symbol not found in DLL")
			program.data_buffer.occupied = align(program.data_buffer.occupied, size_of(rawptr))
			offset_in_data := program.data_buffer.occupied
			buffer_append(&program.data_buffer, sym_address)
			assert(fits_into_u32(offset_in_data), "RIP offset of import too far")
			sym.offset_in_data = u32(offset_in_data)
		}
	}
	
	for builder in &program.functions
	{
		fn_encode(&result.code_buffer, &builder, loc)
	}
	
	if DEBUG_PRINT do print_buffer(result.code_buffer.memory[:result.code_buffer.occupied])
	
	// Making code executable
	dummy: u32
	win32.virtual_protect(&result.code_buffer.memory[0], uint(code_buffer_size), PAGE_EXECUTE_READ, &dummy)
	
	return result
}

fn_arg :: proc(builder: ^Function_Builder, descriptor: ^Descriptor) -> ^Value
{
	return function_push_argument(&builder.result.descriptor.function, descriptor)
}

Function_Return_Type :: enum
{
	Implicit,
	Explicit,
}

fn_return_descriptor :: proc(builder: ^Function_Builder, descriptor: ^Descriptor, return_type: Function_Return_Type,
                             loc := #caller_location)
{
	function := &builder.result.descriptor.function
	if function.returns == nil
	{
		assert(!fn_is_frozen(builder), "Function builder was frozen during fn_return")
		if descriptor.type != .Void
		{
			function.returns = value_register_for_descriptor(.A, descriptor)
		}
		else
		{
			function.returns = &void_value
		}
	}
}

fn_return :: proc(builder: ^Function_Builder, to_return: ^Value, return_type: Function_Return_Type,
                  loc := #caller_location)
{
	fn_return_descriptor(builder, to_return.descriptor, return_type, loc)
	if builder.result.descriptor.function.returns.descriptor.type == .Void
	{
		if to_return.descriptor.type != .Void
		{
			assert(return_type == .Implicit, "Nonvoid explicit return in void function")
		}
	}
	else
	{
		move_value(builder, builder.result.descriptor.function.returns, to_return)
	}
	
	push_instruction(builder, {jmp, {label32(builder.epilog_label), {}, {}}, nil, loc})
}

assert_not_register_ax :: proc(value: ^Value)
{
	assert(value != nil, "value != nil")
	if value.operand.type == .Register
	{
		assert(value.operand.reg != .A, "Value is not in A register")
	}
}

Arithmetic_Operation :: enum
{
	Plus,
	Minus,
	Times,
	Divide,
}

maybe_constant_fold :: proc(a: ^Value, b: ^Value, operation: Arithmetic_Operation) -> ^Value
{
	if operand_is_immediate(&a.operand) && operand_is_immediate(&b.operand)
	{
		a_i64 := operand_immediate_as_i64(&a.operand)
		b_i64 := operand_immediate_as_i64(&b.operand)
		switch operation
		{
			case .Plus:
			{
				return value_from_signed_immediate(a_i64 + b_i64)
			}
			case .Minus:
			{
				return value_from_signed_immediate(a_i64 - b_i64)
			}
			case .Times:
			{
				return value_from_signed_immediate(a_i64 * b_i64)
			}
			case .Divide:
			{
				return value_from_signed_immediate(a_i64 / b_i64)
			}
			case:
			{
				assert(false, "Unknown arithmetic operation")
			}
		}
	}
	return nil
}

plus_or_minus :: proc(builder: ^Function_Builder, operation: Arithmetic_Operation, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	if !(a.descriptor.type == .Pointer &&
	     b.descriptor.type == .Integer &&
	     b.descriptor.integer.byte_size == size_of(rawptr))
	{
		assert(same_value_type_or_can_implicitly_move_cast(a, b), "Types match in plus/minus")
		assert(a.descriptor.type == .Integer, "Plus/minus only works with integers")
	}
	
	assert_not_register_ax(a)
	assert_not_register_ax(b)
	
	result := maybe_constant_fold(a, b, operation)
	if result != nil do return result
	
	larger_descriptor := descriptor_byte_size(a.descriptor) > descriptor_byte_size(b.descriptor) ? a.descriptor : b.descriptor
	
	temp_b := reserve_stack(builder, larger_descriptor)
	move_value(builder, temp_b, b)
	
	reg_a := value_register_for_descriptor(.A, larger_descriptor)
	move_value(builder, reg_a, a)
	
	#partial switch operation
	{
		case .Plus:
		{
			push_instruction(builder, {add, {reg_a.operand, temp_b.operand, {}}, nil, loc})
		}
		case .Minus:
		{
			push_instruction(builder, {sub, {reg_a.operand, temp_b.operand, {}}, nil, loc})
		}
		case:
		{
			assert(false, "Unknown arithmetic operation")
		}
	}
	
	temp := reserve_stack(builder, a.descriptor)
	move_value(builder, temp, reg_a)
	
	return temp
}

plus :: proc(builder: ^Function_Builder, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	return plus_or_minus(builder, .Plus, a, b, loc)
}

minus :: proc(builder: ^Function_Builder, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	return plus_or_minus(builder, .Minus, a, b, loc)
}

multiply :: proc(builder: ^Function_Builder, x: ^Value, y: ^Value, loc := #caller_location) -> ^Value
{
	assert(same_value_type(x, y), "Types match in multiply")
	assert(x.descriptor.type == .Integer, "Multiply only works with integers")
	
	// TODO type check values
	assert_not_register_ax(x)
	assert_not_register_ax(y)
	
	result := maybe_constant_fold(x, y, .Times)
	if result != nil do return result
	
	// TODO ceal with signed / unsigned
	// TODO support double the size of the result?
	// TODO make the move only for imm value
	y_temp := reserve_stack(builder, y.descriptor)
	
	reg_a := value_register_for_descriptor(.A, y.descriptor)
	move_value(builder, reg_a, y)
	move_value(builder, y_temp, reg_a)
	
	reg_a = value_register_for_descriptor(.A, x.descriptor)
	move_value(builder, reg_a, x)
	
	push_instruction(builder, {imul, {reg_a.operand, y_temp.operand, {}}, nil, loc})
	
	temp := reserve_stack(builder, x.descriptor)
	move_value(builder, temp, reg_a)
	
	return temp
}

Divide_Operation :: enum
{
	Divide,
	Remainder,
}

divide_or_remainder :: proc(builder: ^Function_Builder, operation: Divide_Operation, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	assert(same_value_type_or_can_implicitly_move_cast(a, b), "Types match in divide")
	assert(a.descriptor.type == .Integer, "Divide only works with integers")
	
	// TODO type check values
	assert_not_register_ax(a)
	assert_not_register_ax(b)
	
	if operand_is_immediate(&a.operand) && operand_is_immediate(&b.operand)
	{
		dividend := operand_immediate_as_i64(&a.operand)
		divisor  := operand_immediate_as_i64(&b.operand)
		assert(divisor != 0, "Divide by zero")
		return value_from_signed_immediate(dividend / divisor)
	}
	
	// Save RDX as it will be used for the remainder
	rdx_temp := reserve_stack(builder, &descriptor_i64)
	
	reg_rdx := value_register_for_descriptor(.D, &descriptor_i64)
	move_value(builder, rdx_temp, reg_rdx)
	
	larger_descriptor := descriptor_byte_size(a.descriptor) > descriptor_byte_size(b.descriptor) ? a.descriptor : b.descriptor
	
	// TODO deal with signed / unsigned
	divisor := reserve_stack(builder, larger_descriptor)
	move_value(builder, divisor, b)
	
	reg_a := value_register_for_descriptor(.A, larger_descriptor)
	move_value(builder, reg_a, a)
	
	switch descriptor_byte_size(larger_descriptor)
	{
		case 8:
		{
			push_instruction(builder, {cqo, {}, nil, loc})
		}
		case 4:
		{
			push_instruction(builder, {cdq, {}, nil, loc})
		}
		case 2:
		{
			push_instruction(builder, {cwd, {}, nil, loc})
		}
		case 1:
		{
			// No need to sign extend in D register
		}
		case:
		{
			assert(false, "Unsupported byte size when dividing")
		}
	}
	push_instruction(builder, {idiv, {divisor.operand, {}, {}}, nil, loc})
	
	result := reserve_stack(builder, larger_descriptor)
	if operation == .Divide
	{
		move_value(builder, result, reg_a)
	}
	else
	{
		if descriptor_byte_size(larger_descriptor) == 1
		{
			move_value(builder, result, value_register_for_descriptor(.AH, larger_descriptor))
		}
		else
		{
			move_value(builder, result, value_register_for_descriptor(.D, larger_descriptor))
		}
	}
	
	// Restore RDX
	move_value(builder, reg_rdx, rdx_temp)
	
	return result
}

divide :: proc(builder: ^Function_Builder, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	return divide_or_remainder(builder, .Divide, a, b, loc)
}

remainder :: proc(builder: ^Function_Builder, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	return divide_or_remainder(builder, .Remainder, a, b, loc)
}

Compare :: enum
{
	Equal,
	Not_Equal,
	Less,
	Greater,
}

maybe_constant_compare :: proc(a: ^Value, b: ^Value, operation: Compare) -> ^Value
{
	if operand_is_immediate(&a.operand) && operand_is_immediate(&b.operand)
	{
		a_i64 := operand_immediate_as_i64(&a.operand)
		b_i64 := operand_immediate_as_i64(&b.operand)
		switch operation
		{
			case .Equal:
			{
				return value_from_i8(i8(a_i64 == b_i64))
			}
			case .Not_Equal:
			{
				return value_from_i8(i8(a_i64 != b_i64))
			}
			case .Less:
			{
				return value_from_i8(i8(a_i64 < b_i64))
			}
			case .Greater:
			{
				return value_from_i8(i8(a_i64 > b_i64))
			}
			case:
			{
				assert(false, "Unsupported comparison")
			}
		}
	}
	return nil
}

compare :: proc(builder: ^Function_Builder, operation: Compare, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	assert(a.descriptor.type == .Integer, "Can only compare integers")
	assert(b.descriptor.type == .Integer, "Can only compare integers")
	
	const_result := maybe_constant_compare(a, b, operation)
	if const_result != nil do return const_result
	
	larger_descriptor := descriptor_byte_size(a.descriptor) > descriptor_byte_size(b.descriptor) ? a.descriptor : b.descriptor
	
	temp_b := reserve_stack(builder, larger_descriptor)
	move_value(builder, temp_b, b, loc)
	
	reg_a := value_register_for_descriptor(.A, larger_descriptor)
	move_value(builder, reg_a, a, loc)
	
	push_instruction(builder, {cmp, {reg_a.operand, temp_b.operand, {}}, nil, loc})
	
	result := reserve_stack(builder, &descriptor_i8)
	
	switch operation
	{
		case .Equal:
		{
			push_instruction(builder, {setz, {result.operand, {}, {}}, nil, loc})
		}
		case .Not_Equal:
		{
			push_instruction(builder, {setne, {result.operand, {}, {}}, nil, loc})
		}
		case .Less:
		{
			push_instruction(builder, {setl, {result.operand, {}, {}}, nil, loc})
		}
		case .Greater:
		{
			push_instruction(builder, {setg, {result.operand, {}, {}}, nil, loc})
		}
		case:
		{
			assert(false, "Unsupported comparison")
		}
	}
	return result
}

value_pointer_to :: proc(builder: ^Function_Builder, value: ^Value, loc := #caller_location) -> ^Value
{
	// TODO support registers
	// TODO support immediates
	assert(value.operand.type == .Memory_Indirect ||
	       value.operand.type == .RIP_Relative)
	result_descriptor := descriptor_pointer_to(value.descriptor)
	
	reg_a := value_register_for_descriptor(.A, result_descriptor)
	push_instruction(builder, {lea, {reg_a.operand, value.operand, {}}, nil, loc})
	
	result := reserve_stack(builder, result_descriptor)
	move_value(builder, result, reg_a)
	
	return result
}

call_function_overload :: proc(builder: ^Function_Builder, to_call: ^Value, args: ..^Value) -> ^Value
{
	assert(to_call.descriptor.type == .Function, "Value to call must be a function")
	descriptor := &to_call.descriptor.function
	assert(len(descriptor.arguments) == len(args), "Correct number of arguments passed when calling function value")
	
	fn_ensure_frozen(descriptor)
	
	for arg, i in args
	{
		// FIXME add proper type checks for arguments
		assert(same_value_type_or_can_implicitly_move_cast(descriptor.arguments[i], arg), "Argument types match")
		move_value(builder, descriptor.arguments[i], arg)
	}
	
	// If we call a function, then we need to reserve space for the home
	// area of at least 4 arguments?
	parameters_stack_size := i32(max(len(args), 4) * size_of(i64))
	
	// FIXME support this for fns that accept arguments
	return_size := descriptor_byte_size(descriptor.returns.descriptor)
	if return_size > size_of(i64)
	{
		parameters_stack_size += return_size
		return_pointer_descriptor := descriptor_pointer_to(descriptor.returns.descriptor)
		reg_c := value_register_for_descriptor(.C, return_pointer_descriptor)
		push_instruction(builder, {lea, {reg_c.operand, descriptor.returns.operand, {}}, nil, #location()})
	}
	
	builder.max_call_parameters_stack_size = max(builder.max_call_parameters_stack_size, parameters_stack_size)
	
	if to_call.operand.type == .Label_32
	{
		push_instruction(builder, {call, {to_call.operand, {}, {}}, nil, #location()})
	}
	else
	{
		reg_a := value_register_for_descriptor(.A, to_call.descriptor)
		move_value(builder, reg_a, to_call)
		push_instruction(builder, {call, {reg_a.operand, {}, {}}, nil, #location()})
	}
	
	if return_size != 0 && return_size <= size_of(i64)
	{
		result := reserve_stack(builder, descriptor.returns.descriptor)
		move_value(builder, result, descriptor.returns)
		return result
	}
	
	return descriptor.returns
}

Overload_Match :: struct
{
	value: ^Value,
	score: int,
}

calculate_arguments_match_score :: proc(descriptor: ^Descriptor_Function, arguments: []^Value) -> int
{
	Score_Exact :: 100000
	Score_Cast  :: 1
	
	score := 0
	for source_arg, i in arguments
	{
		target_arg := descriptor.arguments[i]
		if same_value_type(target_arg, source_arg)
		{
			score += Score_Exact
		}
		else if same_value_type_or_can_implicitly_move_cast(target_arg, source_arg)
		{
			score += Score_Cast
		}
		else
		{
			return -1
		}
	}
	return score
}

call_function_value :: proc(builder: ^Function_Builder, to_call: ^Value, arguments: ..^Value) -> ^Value
{
	assert(to_call.descriptor.type == .Function, "Value to call must be a function")
	
	match: Overload_Match = {score = -1}
	overload_loop: for overload := to_call; overload != nil; overload = overload.descriptor.function.next_overload
	{
		descriptor := &overload.descriptor.function
		if len(arguments) != len(descriptor.arguments) do continue
		score := calculate_arguments_match_score(descriptor, arguments)
		if score > match.score
		{
			// FIXME think about same scores
			match.value = overload
			match.score = score
		}
		
	}
	if match.value != nil
	{
		return call_function_overload(builder, match.value, ..arguments)
	}
	assert(false, "No matching overload found")
	return nil
}

label_ :: proc(builder: ^Function_Builder, label: ^Label, loc := #caller_location)
{
	push_instruction(builder, {maybe_label = label, loc = loc})
}

goto :: proc(builder: ^Function_Builder, label: ^Label, loc := #caller_location)
{
	push_instruction(builder, {jmp, {label32(label), {}, {}}, nil, loc})
}

make_if :: proc(builder: ^Function_Builder, value: ^Value, loc := #caller_location) -> ^Label
{
	is_always_true := false
	if operand_is_immediate(&value.operand)
	{
		imm := operand_immediate_as_i64(&value.operand)
		if imm == 0 do return nil
		is_always_true = true
	}
	
	label := make_label()
	if !is_always_true
	{
		byte_size := descriptor_byte_size(value.descriptor)
		if byte_size == 4 || byte_size == 8
		{
			push_instruction(builder, {cmp, {value.operand, imm32(0), {}}, nil, loc})
		}
		else if byte_size == 1
		{
			push_instruction(builder, {cmp, {value.operand, imm8(0), {}}, nil, loc})
		}
		else
		{
			assert(false, "Unsupported value inside `if`")
		}
		
		push_instruction(builder, {jz, {label32(label), {}, {}}, nil, loc})
	}
	return label
}

end_if :: label_

make_match :: make_label

end_match :: label_

make_case :: make_if

end_case :: proc(builder: ^Function_Builder, end_match_label: ^Label, end_case_label: ^Label, loc := #caller_location)
{
	goto(builder, end_match_label, loc)
	label_(builder, end_case_label, loc)
}

Loop_Builder :: struct
{
	label_start: ^Label,
	label_end:   ^Label,
}

loop_start :: proc(builder: ^Function_Builder, loc := #caller_location) -> Loop_Builder
{
	label_start := make_label()
	push_instruction(builder, {maybe_label = label_start, loc = loc})
	return Loop_Builder{label_start, make_label()}
}

loop_end :: proc(builder: ^Function_Builder, loop: Loop_Builder, loc := #caller_location)
{
	push_instruction(builder, {jmp, {label32(loop.label_start), {}, {}}, nil, loc})
	push_instruction(builder, {maybe_label = loop.label_end})
}

make_and :: proc(builder: ^Function_Builder, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	result := reserve_stack(builder, &descriptor_i8)
	label := make_label()
	i := make_if(builder, a)
	{
		rhs := compare(builder, .Not_Equal, b, value_from_i8(0))
		move_value(builder, result, rhs)
		push_instruction(builder, {jmp, {label32(label), {}, {}}, nil, loc})
	}
	end_if(builder, i)
	move_value(builder, result, value_from_i8(0))
	label_(builder, label)
	
	return result
}

make_or :: proc(builder: ^Function_Builder, a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	result := reserve_stack(builder, &descriptor_i8)
	label := make_label()
	i := make_if(builder, compare(builder, .Equal, a, value_from_i8(0)))
	{
		rhs := compare(builder, .Not_Equal, b, value_from_i8(0))
		move_value(builder, result, rhs)
		push_instruction(builder, {jmp, {label32(label), {}, {}}, nil, loc})
	}
	end_if(builder, i)
	move_value(builder, result, value_from_i8(1))
	label_(builder, label)
	
	return result
}

ensure_memory :: proc(value: ^Value) -> ^Value
{
	operand := value.operand
	if operand.type == .Memory_Indirect do return value
	if value.descriptor.type != .Pointer do assert(false, "Not implemented")
	if value.operand.type != .Register do assert(false, "Not implemented")
	return new_clone(Value \
	{
		descriptor = value.descriptor.pointer_to,
		operand =
		{
			type = .Memory_Indirect,
			data = {indirect =
			{
				reg          = value.operand.reg,
				displacement = 0,
			}},
		},
	})
}

struct_get_field :: proc(struct_value: ^Value, name: string) -> ^Value
{
	struct_value := ensure_memory(struct_value)
	descriptor := struct_value.descriptor
	assert(descriptor.type == .Struct, "Can only get fields of structs")
	for field in &descriptor.struct_.fields
	{
		if field.name == name
		{
			operand := struct_value.operand
			// FIXME support more operands
			assert(operand.type == .Memory_Indirect)
			operand.indirect.displacement += field.offset
			operand.byte_size = descriptor_byte_size(field.descriptor)
			result := new_clone(Value \
			{
				descriptor = field.descriptor,
				operand    = operand,
			})
			return result
		}
	}
	
	assert(false, "Could not find a field with specified name")
	return nil
}

//
//
//

peek :: proc(arr: ^[dynamic]$E, loc := #caller_location) -> E
{
	assert(len(arr^) > 0, "Peek at empty array", loc)
	return arr^[len(arr^) - 1]
}

Function_Context :: struct
{
	builder:     ^Function_Builder,
	if_stack:    [dynamic]^Label,
	match_stack: [dynamic]^Label,
	case_stack:  [dynamic]^Label,
	loop_stack:  [dynamic]Loop_Builder,
}

get_builder_from_context :: proc() -> ^Function_Builder
{
	context_stack := cast(^[dynamic]Function_Context)context.user_ptr
	return context_stack[len(context_stack) - 1].builder
}

get_if_stack_from_context :: proc() -> ^[dynamic]^Label
{
	context_stack := cast(^[dynamic]Function_Context)context.user_ptr
	return &context_stack[len(context_stack) - 1].if_stack
}

get_match_stack_from_context :: proc() -> ^[dynamic]^Label
{
	context_stack := cast(^[dynamic]Function_Context)context.user_ptr
	return &context_stack[len(context_stack) - 1].match_stack
}

get_case_stack_from_context :: proc() -> ^[dynamic]^Label
{
	context_stack := cast(^[dynamic]Function_Context)context.user_ptr
	return &context_stack[len(context_stack) - 1].case_stack
}

get_loop_stack_from_context :: proc() -> ^[dynamic]Loop_Builder
{
	context_stack := cast(^[dynamic]Function_Context)context.user_ptr
	return &context_stack[len(context_stack) - 1].loop_stack
}

//
//
//

Function :: proc(program: ^Program = nil) -> ^Value
{
	program := program == nil ? &test_program : program
	
	result, builder := fn_begin(program)
	
	context_stack := cast(^[dynamic]Function_Context)context.user_ptr
	append(context_stack, Function_Context{builder = builder})
	
	return result
}

End_Function :: proc(loc := #caller_location)
{
	builder     := get_builder_from_context()
	if_stack    := get_if_stack_from_context()
	match_stack := get_match_stack_from_context()
	case_stack  := get_case_stack_from_context()
	loop_stack  := get_loop_stack_from_context()
	
	assert(len(if_stack)    == 0, "Unmatched If in function",    loc)
	assert(len(match_stack) == 0, "Unmatched Match in function", loc)
	assert(len(case_stack)  == 0, "Unmatched Case in function",  loc)
	assert(len(loop_stack)  == 0, "Unmatched Loop in function",  loc)
	
	fn_end(builder)
	
	context_stack := cast(^[dynamic]Function_Context)context.user_ptr
	pop(context_stack, loc)
}

Return :: proc(to_return: ^Value, loc := #caller_location)
{
	builder := get_builder_from_context()
	
	fn_return(builder, to_return, .Explicit, loc)
}

Arg :: proc(descriptor: ^Descriptor) -> ^Value
{
	builder := get_builder_from_context()
	
	return fn_arg(builder, descriptor)
}

Arg_i8  :: proc() -> ^Value { return Arg(&descriptor_i8) }
Arg_i32 :: proc() -> ^Value { return Arg(&descriptor_i32) }
Arg_i64 :: proc() -> ^Value { return Arg(&descriptor_i64) }

Stack :: proc(descriptor: ^Descriptor, value: ^Value = nil, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	result := reserve_stack(builder, descriptor)
	if value != nil
	{
		move_value(builder, result, value, loc)
	}
	return result
}

Stack_i8  :: proc(value: ^Value = nil, loc := #caller_location) -> ^Value { return Stack(&descriptor_i8, value, loc) }
Stack_i32 :: proc(value: ^Value = nil, loc := #caller_location) -> ^Value { return Stack(&descriptor_i32, value, loc) }
Stack_i64 :: proc(value: ^Value = nil, loc := #caller_location) -> ^Value { return Stack(&descriptor_i64, value, loc) }

Assign :: proc(dest: ^Value, source: ^Value, loc := #caller_location)
{
	builder := get_builder_from_context()
	
	move_value(builder, dest, source, loc)
}

PointerTo :: proc(value: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return value_pointer_to(builder, value, loc)
}

Call :: proc(to_call: ^Value, args: ..^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return call_function_value(builder, to_call, ..args)
}

Plus :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return plus(builder, a, b, loc)
}

Minus :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return minus(builder, a, b, loc)
}

Multiply :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return multiply(builder, a, b, loc)
}

Divide :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return divide(builder, a, b, loc)
}

Remainder :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return remainder(builder, a, b, loc)
}

SizeOfDescriptor :: proc(descriptor: ^Descriptor) -> ^Value
{
	return value_from_i32(descriptor_byte_size(descriptor))
}

SizeOf :: proc(value: ^Value) -> ^Value
{
	return value_byte_size(value)
}

ReflectDescriptor :: proc(descriptor: ^Descriptor) -> ^Value
{
	builder := get_builder_from_context()
	
	return fn_reflect(builder, descriptor)
}

StructField :: proc(value: ^Value, name: string) -> ^Value
{
	return struct_get_field(value, name)
}

Label_ :: proc(label: ^Label, loc := #caller_location)
{
	builder := get_builder_from_context()
	
	label_(builder, label, loc)
}

Goto :: proc(label: ^Label, loc := #caller_location)
{
	builder := get_builder_from_context()
	
	goto(builder, label, loc)
}

If :: proc(value: ^Value, loc := #caller_location) -> bool
{
	builder  := get_builder_from_context()
	if_stack := get_if_stack_from_context()
	
	label := make_if(builder, value, loc)
	if label == nil do return false
	append(if_stack, label)
	return true
}

End_If :: proc(loc := #caller_location)
{
	builder  := get_builder_from_context()
	if_stack := get_if_stack_from_context()
	
	label := pop(if_stack, loc)
	label_(builder, label, loc)
}

Match :: proc(loc := #caller_location)
{
	match_stack := get_match_stack_from_context()
	
	label := make_match()
	append(match_stack, label)
}

End_Match :: proc(loc := #caller_location)
{
	builder     := get_builder_from_context()
	match_stack := get_match_stack_from_context()
	
	label := pop(match_stack, loc)
	end_match(builder, label, loc)
}

Case :: proc(value: ^Value, loc := #caller_location)
{
	builder    := get_builder_from_context()
	case_stack := get_case_stack_from_context()
	
	label := make_case(builder, value, loc)
	append(case_stack, label)
}

End_Case :: proc(loc := #caller_location)
{
	builder     := get_builder_from_context()
	match_stack := get_match_stack_from_context()
	case_stack  := get_case_stack_from_context()
	
	end_match_label := peek(match_stack, loc)
	end_case_label  := pop(case_stack, loc)
	end_case(builder, end_match_label, end_case_label, loc)
}

CaseAny :: proc(loc := #caller_location) {}

End_CaseAny :: proc(loc := #caller_location) {}

Loop :: proc(loc := #caller_location)
{
	builder    := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := loop_start(builder, loc)
	append(loop_stack, loop)
}

End_Loop :: proc(loc := #caller_location)
{
	builder    := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := pop(loop_stack, loc)
	loop_end(builder, loop)
}

Continue :: proc(loc := #caller_location)
{
	builder    := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := peek(loop_stack, loc)
	goto(builder, loop.label_start)
}

Break :: proc(loc := #caller_location)
{
	builder    := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := peek(loop_stack, loc)
	goto(builder, loop.label_end)
}

NotEq :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Not_Equal, a, b, loc)
}

Eq :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Equal, a, b, loc)
}

Less :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Less, a, b, loc)
}

Greater :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Greater, a, b, loc)
}

And :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return make_and(builder, a, b, loc)
}

Or :: proc(a: ^Value, b: ^Value, loc := #caller_location) -> ^Value
{
	builder := get_builder_from_context()
	
	return make_or(builder, a, b, loc)
}
