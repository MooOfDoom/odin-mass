package main

import "core:mem"
import "core:runtime"

TO_BE_PATCHED :i32: -858993460 // 0xcccccccc

reserve_stack :: proc(builder: ^Fn_Builder, descriptor: ^Descriptor) -> ^Value
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

push_instruction :: proc(builder: ^Fn_Builder, instruction: Instruction)
{
	append(&builder.instructions, instruction)
}

move_value :: proc(builder: ^Fn_Builder, a: ^Value, b: ^Value)
{
	// TODO figure out more type checking
	a_size := descriptor_byte_size(a.descriptor)
	b_size := descriptor_byte_size(b.descriptor)
	
	// if a_size != b_size
	// {
	// 	if b.operand.typ == .Memory_Indirect ||
	// 	if !(b.operand.type == .Immediate_32 && a_size == 8)
	// 	{
	// 		assert(false, "Mismatched operand size when moving")
	// 	}
	// }
	
	if b_size == 1 && a_size >= 2 && a_size < 8
	{
		assert(a.operand.type == .Register)
		zero := value_from_i64(0)
		zero.descriptor = a.descriptor
		
		move_value(builder, a, zero)
		push_instruction(builder, {mov, {a.operand, b.operand, {}}, nil})
		// FIXME use movsx
		// push_instruction(builder, {movsx, {a.operand, b.operand, {}}, nil})
		return
	}
	
	if (a.operand.type == .Register &&
	    ((b.operand.type == .Immediate_8 && b.operand.imm8 == 0) ||
	     (b.operand.type == .Immediate_32 && b.operand.imm32 == 0) ||
	     (b.operand.type == .Immediate_64 && b.operand.imm64 == 0)))
	{
		// This messes up flags register so comparisons need to be aware of this optimization
		push_instruction(builder, {xor, {a.operand, a.operand, {}}, nil})
		return
	}
	
	if (b.operand.type == .Immediate_64 && b.operand.imm64 == i64(i32(b.operand.imm64)))
	{
		move_value(builder, a, value_from_i32(i32(b.operand.imm64)))
		return
	}
	
	if ((b.operand.type == .Immediate_64 &&
	     a.operand.type != .Register) ||
	    (a.operand.type == .Memory_Indirect &&
	     b.operand.type == .Memory_Indirect))
	{
		reg_a := value_register_for_descriptor(.A, a.descriptor)
		// TODO Can be a problem if RAX is already used as temp
		move_value(builder, reg_a, b)
		move_value(builder, a, reg_a)
	}
	else
	{
		push_instruction(builder, {mov, {a.operand, b.operand, {}}, nil})
	}
}

fn_begin :: proc(buffer: ^Buffer) -> (result: ^Value, builder: Fn_Builder)
{
	builder =
	{
		buffer = buffer,
		code_offset = buffer.occupied,
		stack_displacements = make([dynamic]Stack_Patch, 0, 128, runtime.default_allocator()),
		instructions        = make([dynamic]Instruction, 0, 4096, runtime.default_allocator()),
		epilog_label        = make_label(),
		result = new_clone(Value \
		{
			descriptor = new_clone(Descriptor \
			{
				type = .Function,
				function =
				{
					arguments = make([dynamic]Value, 0, 16),
				},
			}),
			operand = label32(make_label(&buffer.memory[buffer.occupied])),
		}),
	}
	result = builder.result
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

fn_freeze :: proc(builder: ^Fn_Builder)
{
	fn_ensure_frozen(&builder.result.descriptor.function)
}

fn_is_frozen :: proc(builder: ^Fn_Builder) -> bool
{
	return builder.result.descriptor.function.frozen
}

fn_end :: proc(builder: ^Fn_Builder)
{
	alignment :: 0x8
	builder.stack_reserve += builder.max_call_parameters_stack_size
	stack_size := align(builder.stack_reserve, 16) + alignment
	
	encode_instruction(builder, {sub, {rsp, imm_auto(stack_size), {}}, nil});
	
	// instruction_index_offsets := make([][^]byte, len(builder.instructions), runtime.default_allocator())
	
	for instruction, i in &builder.instructions
	{
		// instruction_index_offsets[i] = &builder.buffer.memory[builder.buffer.occupied]
		encode_instruction(builder, instruction)
	}
	
	for patch in builder.stack_displacements
	{
		displacement := patch.location^
		// @Volatile @StackPatch
		if displacement < 0
		{
			// Negative displacement is used to push_instruction local variables
			patch.location^ = stack_size + displacement
		}
		else if displacement >= builder.max_call_parameters_stack_size
		{
			// Positive values larger than max_call_parameters_stack_size
			// Return address will be pushed on the stack by the caller and we need to account for that
			return_address_size: i32 = size_of(rawptr)
			patch.location^ = stack_size + displacement + return_address_size
		}
	}
	
	encode_instruction(builder, {maybe_label = builder.epilog_label})
	
	encode_instruction(builder, {add, {rsp, imm_auto(stack_size), {}}, nil})
	encode_instruction(builder, {ret, {}, nil})
	
	if DEBUG_PRINT do print_buffer(builder.buffer.memory[builder.code_offset:builder.buffer.occupied])
	
	fn_freeze(builder)
	
	delete(builder.stack_displacements)
	delete(builder.instructions)
	// delete(instruction_index_offsets, runtime.default_allocator())
}

fn_arg :: proc(builder: ^Fn_Builder, descriptor: ^Descriptor) -> ^Value
{
	byte_size := descriptor_byte_size(descriptor)
	assert(byte_size <= 8, "Arg byte size <= 8")
	argument_index := len(builder.result.descriptor.function.arguments)
	switch argument_index
	{
		case 0:
		{
			append(&builder.result.descriptor.function.arguments, value_register_for_descriptor(.C, descriptor)^)
		}
		case 1:
		{
			append(&builder.result.descriptor.function.arguments, value_register_for_descriptor(.D, descriptor)^)
		}
		case 2:
		{
			append(&builder.result.descriptor.function.arguments, value_register_for_descriptor(.R8, descriptor)^)
		}
		case 3:
		{
			append(&builder.result.descriptor.function.arguments, value_register_for_descriptor(.R9, descriptor)^)
		}
		case:
		{
			// @Volatile @StackPatch
			offset := i32(argument_index * size_of(i64))
			operand := stack(offset, byte_size)
			
			append(&builder.result.descriptor.function.arguments, Value \
			{
				descriptor = descriptor,
				operand    = operand,
			})
		}
	}
	return &builder.result.descriptor.function.arguments[argument_index] // NOTE(Lothar): Danger! Pointing into dynamic array!
}

fn_return :: proc(builder: ^Fn_Builder, to_return: ^Value)
{
	// We can no longer modify the return value after fn has been called
	// or after builder has been committed through fn_end() call
	// FIXME
	// assert(!builder.frozen)
	
	// FIXME @Overloads
	if builder.result.descriptor.function.returns != nil
	{
		assert(same_value_type(builder.result.descriptor.function.returns, to_return))
	}
	else
	{
		assert(!fn_is_frozen(builder))
		if to_return.descriptor.type != .Void
		{
			builder.result.descriptor.function.returns = value_register_for_descriptor(.A, to_return.descriptor)
		}
		else
		{
			builder.result.descriptor.function.returns = &void_value
		}
	}
	
	if to_return.descriptor.type != .Void
	{
		move_value(builder, builder.result.descriptor.function.returns, to_return)
	}
	push_instruction(builder, {jmp, {label32(builder.epilog_label), {}, {}}, nil})
}

label_ :: proc(builder: ^Fn_Builder, label: ^Label)
{
	push_instruction(builder, {maybe_label = label})
}

goto :: proc(builder: ^Fn_Builder, label: ^Label)
{
	push_instruction(builder, {jmp, {label32(label), {}, {}}, nil})
}

make_if :: proc(builder: ^Fn_Builder, value: ^Value) -> ^Label
{
	label := make_label()
	byte_size := descriptor_byte_size(value.descriptor)
	if byte_size == 4 || byte_size == 8
	{
		push_instruction(builder, {cmp, {value.operand, imm32(0), {}}, nil})
	}
	else if byte_size == 1
	{
		push_instruction(builder, {cmp, {value.operand, imm8(0), {}}, nil})
	}
	else
	{
		assert(false, "Unsupported value inside `if`")
	}
	
	push_instruction(builder, {jz, {label32(label), {}, {}}, nil})
	return label
}

end_if :: label_

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
}

plus_or_minus :: proc(builder: ^Fn_Builder, operation: Arithmetic_Operation, a: ^Value, b: ^Value) -> ^Value
{
	if !(a.descriptor.type == .Pointer &&
	     b.descriptor.type == .Integer &&
	     b.descriptor.integer.byte_size == size_of(rawptr))
	{
		assert(same_value_type(a, b), "Types match in plus/minus")
		assert(a.descriptor.type == .Integer, "Plus/minus only works with integers")
	}
	
	// TODO type check values
	assert_not_register_ax(a)
	assert_not_register_ax(b)
	
	temp_b := reserve_stack(builder, b.descriptor)
	move_value(builder, temp_b, b)
	
	reg_a := value_register_for_descriptor(.A, a.descriptor)
	move_value(builder, reg_a, a)
	
	switch operation
	{
		case .Plus:
		{
			push_instruction(builder, {add, {reg_a.operand, temp_b.operand, {}}, nil})
		}
		case .Minus:
		{
			push_instruction(builder, {sub, {reg_a.operand, temp_b.operand, {}}, nil})
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

plus :: proc(builder: ^Fn_Builder, a: ^Value, b: ^Value) -> ^Value
{
	return plus_or_minus(builder, .Plus, a, b)
}

minus :: proc(builder: ^Fn_Builder, a: ^Value, b: ^Value) -> ^Value
{
	return plus_or_minus(builder, .Minus, a, b)
}

multiply :: proc(builder: ^Fn_Builder, x: ^Value, y: ^Value) -> ^Value
{
	assert(same_value_type(x, y), "Types match in multiply")
	assert(x.descriptor.type == .Integer, "Multiply only works with integers")
	
	// TODO type check values
	assert_not_register_ax(x)
	assert_not_register_ax(y)
	
	// TODO ceal with signed / unsigned
	// TODO support double the size of the result?
	// TODO make the move only for imm value
	y_temp := reserve_stack(builder, y.descriptor)
	
	reg_a := value_register_for_descriptor(.A, y.descriptor)
	move_value(builder, reg_a, y)
	move_value(builder, y_temp, reg_a)
	
	reg_a = value_register_for_descriptor(.A, x.descriptor)
	move_value(builder, reg_a, x)
	
	// TODO check operand sizes
	push_instruction(builder, {imul, {reg_a.operand, y_temp.operand, {}}, nil})
	
	temp := reserve_stack(builder, x.descriptor)
	move_value(builder, temp, reg_a)
	
	return temp
}

divide :: proc(builder: ^Fn_Builder, a: ^Value, b: ^Value) -> ^Value
{
	assert(same_value_type(a, b), "Types match in divide")
	assert(a.descriptor.type == .Integer, "Divide only works with integers")
	
	// TODO type check values
	assert_not_register_ax(a)
	assert_not_register_ax(b)
	
	// Save RDX as it will be used for the remainder
	rdx_temp := reserve_stack(builder, &descriptor_i64)
	
	reg_rdx := value_register_for_descriptor(.D, &descriptor_i64)
	move_value(builder, rdx_temp, reg_rdx)
	
	reg_a := value_register_for_descriptor(.A, a.descriptor)
	move_value(builder, reg_a, a)
	
	// TODO deal with signed / unsigned
	divisor := reserve_stack(builder, a.descriptor)
	move_value(builder, divisor, b)
	
	switch descriptor_byte_size(a.descriptor)
	{
		case 8:
		{
			push_instruction(builder, {cqo, {}, nil})
		}
		case 4:
		{
			push_instruction(builder, {cdq, {}, nil})
		}
		case 2:
		{
			push_instruction(builder, {cwd, {}, nil})
		}
		case:
		{
			assert(false, "Unsupported byte size when dividing")
		}
	}
	push_instruction(builder, {idiv, {divisor.operand, {}, {}}, nil})
	
	// TODO correctly size the temporary value
	temp := reserve_stack(builder, a.descriptor)
	move_value(builder, temp, reg_a)
	
	// Restore RDX
	move_value(builder, reg_rdx, rdx_temp)
	
	return temp
}

Compare :: enum
{
	Equal,
	Not_Equal,
	Less,
	Greater,
}

compare :: proc(builder: ^Fn_Builder, operation: Compare, a: ^Value, b: ^Value) -> ^Value
{
	assert(same_value_type(a, b), "Types match in compare")
	
	temp_b := reserve_stack(builder, b.descriptor)
	move_value(builder, temp_b, b)
	
	reg_a := value_register_for_descriptor(.A, a.descriptor)
	move_value(builder, reg_a, a)
	
	// TODO check that types are comparable
	push_instruction(builder, {cmp, {reg_a.operand, temp_b.operand, {}}, nil})
	
	result := reserve_stack(builder, &descriptor_i8)
	
	switch operation
	{
		case .Equal:
		{
			push_instruction(builder, {setz, {result.operand, {}, {}}, nil})
		}
		case .Not_Equal:
		{
			push_instruction(builder, {setne, {result.operand, {}, {}}, nil})
		}
		case .Less:
		{
			push_instruction(builder, {setl, {result.operand, {}, {}}, nil})
		}
		case .Greater:
		{
			push_instruction(builder, {setg, {result.operand, {}, {}}, nil})
		}
		case:
		{
			assert(false, "Unsupported comparison")
		}
	}
	return result
}

value_pointer_to :: proc(builder: ^Fn_Builder, value: ^Value) -> ^Value
{
	// TODO support registers
	// TODO support immediates
	assert(value.operand.type == .Memory_Indirect ||
	       value.operand.type == .RIP_Relative)
	result_descriptor := descriptor_pointer_to(value.descriptor)
	
	reg_a := value_register_for_descriptor(.A, result_descriptor)
	push_instruction(builder, {lea, {reg_a.operand, value.operand, {}}, nil})
	
	result := reserve_stack(builder, result_descriptor)
	move_value(builder, result, reg_a)
	
	return result
}

call_function_overload :: proc(builder: ^Fn_Builder, to_call: ^Value, args: ..^Value) -> ^Value
{
	assert(to_call.descriptor.type == .Function, "Value to call must be a function")
	descriptor := &to_call.descriptor.function
	assert(len(descriptor.arguments) == len(args), "Correct number of arguments passed when calling function value")
	
	fn_ensure_frozen(descriptor)
	
	for arg, i in args
	{
		// FIXME add proper type checks for arguments
		assert(same_value_type(&descriptor.arguments[i], arg), "Argument types match")
		move_value(builder, &descriptor.arguments[i], arg)
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
		push_instruction(builder, {lea, {reg_c.operand, descriptor.returns.operand, {}}, nil})
	}
	
	builder.max_call_parameters_stack_size = max(builder.max_call_parameters_stack_size, parameters_stack_size)
	
	if to_call.operand.type == .Label_32
	{
		push_instruction(builder, {call, {to_call.operand, {}, {}}, nil})
	}
	else
	{
		reg_a := value_register_for_descriptor(.A, to_call.descriptor)
		move_value(builder, reg_a, to_call)
		push_instruction(builder, {call, {reg_a.operand, {}, {}}, nil})
	}
	
	if descriptor.returns.descriptor.type != .Void && return_size <= size_of(i64)
	{
		result := reserve_stack(builder, descriptor.returns.descriptor)
		move_value(builder, result, descriptor.returns)
		return result
	}
	
	return descriptor.returns
}

call_function_value :: proc(builder: ^Fn_Builder, to_call: ^Value, args: ..^Value) -> ^Value
{
	assert(to_call.descriptor.type == .Function)
	overload_loop: for overload := to_call; overload != nil; overload = overload.descriptor.function.next_overload
	{
		for arg, i in args
		{
			if !same_value_type(&overload.descriptor.function.arguments[i], arg)
			{
				continue overload_loop
			}
		}
		return call_function_overload(builder, overload, ..args)
	}
	assert(false, "No matching overload found")
	return nil
}

Loop_Builder :: struct
{
	label_start: ^Label,
	label_end:   ^Label,
}

loop_start :: proc(builder: ^Fn_Builder) -> Loop_Builder
{
	label_start := make_label()
	push_instruction(builder, {maybe_label = label_start})
	return Loop_Builder{label_start, make_label()}
}

loop_end :: proc(builder: ^Fn_Builder, loop: Loop_Builder)
{
	push_instruction(builder, {jmp, {label32(loop.label_start), {}, {}}, nil})
	push_instruction(builder, {maybe_label = loop.label_end})
}

make_and :: proc(builder: ^Fn_Builder, a: ^Value, b: ^Value) -> ^Value
{
	result := reserve_stack(builder, &descriptor_i8)
	label := make_label()
	i := make_if(builder, a)
	{
		rhs := compare(builder, .Not_Equal, b, value_from_i8(0))
		move_value(builder, result, rhs)
		push_instruction(builder, {jmp, {label32(label), {}, {}}, nil})
	}
	end_if(builder, i)
	move_value(builder, result, value_from_i8(0))
	label_(builder, label)
	
	return result
}

make_or :: proc(builder: ^Fn_Builder, a: ^Value, b: ^Value) -> ^Value
{
	result := reserve_stack(builder, &descriptor_i8)
	label := make_label()
	i := make_if(builder, compare(builder, .Equal, a, value_from_i8(0)))
	{
		rhs := compare(builder, .Not_Equal, b, value_from_i8(0))
		move_value(builder, result, rhs)
		push_instruction(builder, {jmp, {label32(label), {}, {}}, nil})
	}
	end_if(builder, i)
	move_value(builder, result, value_from_i8(1))
	label_(builder, label)
	
	return result
}

//
//
//

pop_array :: proc(arr: ^[dynamic]$E, loc := #caller_location) -> E
{
	assert(len(arr) > 0, "Pop from empty array", loc)
	result := arr^[len(arr^) - 1]
	raw_arr := transmute(mem.Raw_Dynamic_Array)arr^
	raw_arr.len -= 1
	arr^ = transmute([dynamic]E)raw_arr
	return result
}

peek_array :: proc(arr: ^[dynamic]$E, loc := #caller_location) -> E
{
	assert(len(arr) > 0, "Peek at empty array", loc)
	return arr^[len(arr^) - 1]
}

Function_Context :: struct
{
	builder:     Fn_Builder,
	if_stack:    [dynamic]^Label,
	loop_stack:  [dynamic]Loop_Builder,
	match_stack: [dynamic]^Label,
	case_stack:  [dynamic]^Label,
}

get_builder_from_context :: proc() -> ^Fn_Builder
{
	return &(cast(^Function_Context)context.user_ptr).builder
}

get_if_stack_from_context :: proc() -> ^[dynamic]^Label
{
	return &(cast(^Function_Context)context.user_ptr).if_stack
}

get_loop_stack_from_context :: proc() -> ^[dynamic]Loop_Builder
{
	return &(cast(^Function_Context)context.user_ptr).loop_stack
}

get_match_stack_from_context :: proc() -> ^[dynamic]^Label
{
	return &(cast(^Function_Context)context.user_ptr).match_stack
}

get_case_stack_from_context :: proc() -> ^[dynamic]^Label
{
	return &(cast(^Function_Context)context.user_ptr).case_stack
}

//
//
//

Function :: proc() -> (^Value, ^Fn_Builder)
{
	fn_context := cast(^Function_Context)context.user_ptr
	
	result: ^Value
	result, fn_context.builder = fn_begin(&function_buffer)
	return result, &fn_context.builder
}

End_Function :: proc()
{
	builder := get_builder_from_context()
	
	fn_end(builder)
}

PointerTo :: proc(value: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return value_pointer_to(builder, value)
}

Return :: proc(to_return: ^Value)
{
	builder := get_builder_from_context()
	
	fn_return(builder, to_return)
}

Arg :: proc(descriptor: ^Descriptor) -> ^Value
{
	builder := get_builder_from_context()
	
	return fn_arg(builder, descriptor)
}

Arg_i8  :: proc() -> ^Value { return Arg(&descriptor_i8) }
Arg_i32 :: proc() -> ^Value { return Arg(&descriptor_i32) }
Arg_i64 :: proc() -> ^Value { return Arg(&descriptor_i64) }

Stack :: proc(descriptor: ^Descriptor, value: ^Value = nil) -> ^Value
{
	builder := get_builder_from_context()
	
	result := reserve_stack(builder, descriptor)
	if value != nil
	{
		move_value(builder, result, value)
	}
	return result
}

Stack_i8  :: proc(value: ^Value = nil) -> ^Value { return Stack(&descriptor_i8, value) }
Stack_i32 :: proc(value: ^Value = nil) -> ^Value { return Stack(&descriptor_i32, value) }
Stack_i64 :: proc(value: ^Value = nil) -> ^Value { return Stack(&descriptor_i64, value) }

Assign :: proc(dest: ^Value, source: ^Value)
{
	builder := get_builder_from_context()
	
	move_value(builder, dest, source)
}

Call :: proc(to_call: ^Value, args: ..^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return call_function_value(builder, to_call, ..args)
}

Plus :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return plus(builder, a, b)
}

Minus :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return minus(builder, a, b)
}

Multiply :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return multiply(builder, a, b)
}

Divide :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return divide(builder, a, b)
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

Label_ :: proc(label: ^Label)
{
	builder := get_builder_from_context()
	
	label_(builder, label)
}

Goto :: proc(label: ^Label)
{
	builder := get_builder_from_context()
	
	goto(builder, label)
}

If :: proc(value: ^Value)
{
	builder := get_builder_from_context()
	if_stack := get_if_stack_from_context()
	
	label := make_if(builder, value)
	append(if_stack, label)
}

End_If :: proc(loc := #caller_location)
{
	builder := get_builder_from_context()
	if_stack := get_if_stack_from_context()
	
	label := pop_array(if_stack, loc)
	label_(builder, label)
}

Loop :: proc()
{
	builder := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := loop_start(builder)
	append(loop_stack, loop)
}

End_Loop :: proc(loc := #caller_location)
{
	builder := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := pop_array(loop_stack, loc)
	loop_end(builder, loop)
}

Continue :: proc(loc := #caller_location)
{
	builder := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := peek_array(loop_stack, loc)
	goto(builder, loop.label_start)
}

Break :: proc(loc := #caller_location)
{
	builder := get_builder_from_context()
	loop_stack := get_loop_stack_from_context()
	
	loop := peek_array(loop_stack, loc)
	goto(builder, loop.label_end)
}

NotEq :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Not_Equal, a, b)
}

Eq :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Equal, a, b)
}

Less :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Less, a, b)
}

Greater :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return compare(builder, .Greater, a, b)
}

And :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return make_and(builder, a, b)
}

Or :: proc(a: ^Value, b: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return make_or(builder, a, b)
}

// Match :: make_label

// end_match :: proc(builder: ^Fn_Builder, label: ^Label)
// {
	
// }

// End_Match :: proc(label: ^Label)
// {
// 	builder := get_builder_from_context()
	
// 	end_match(builder, label)
// }
