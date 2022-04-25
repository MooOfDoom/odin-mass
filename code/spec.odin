package main

import "core:fmt"
import "core:mem"

DEBUG_PRINT :: false

fn_reflect :: proc(builder: ^Function_Builder, descriptor: ^Descriptor) -> ^Value
{
	result := reserve_stack(builder, &descriptor_struct_reflection)
	// FIXME support all types
	assert(descriptor.type == .Struct)
	// FIXME support generic allocation of structs on the stack
	move_value(builder, result, value_from_i32(i32(len(descriptor.struct_.fields))))
	return result
}

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

struct_begin :: proc() -> Struct_Builder
{
	return Struct_Builder{}
}

struct_add_field :: proc(builder: ^Struct_Builder, descriptor: ^Descriptor, name: string) -> ^Descriptor_Struct_Field
{
	size := descriptor_byte_size(descriptor)
	builder.max_size = max(builder.max_size, size)
	builder.offset = align(builder.offset, size)
	builder_field := new_clone(Struct_Builder_Field \
	{
		struct_field =
		{
			name       = name,
			descriptor = descriptor,
			offset     = builder.offset,
		},
		next = builder.field_list,
	})
	builder.offset      += size
	builder.field_count += 1
	builder.field_list   = builder_field
	
	return &builder_field.struct_field
}

struct_end :: proc(builder: ^Struct_Builder) -> ^Descriptor
{
	assert(builder.field_count > 0, "Struct has at least one field")
	
	builder.offset = align(builder.offset, builder.max_size)
	
	result := new_clone(Descriptor \
	{
		type = .Struct,
		data = {struct_ =
		{
			fields = make([]Descriptor_Struct_Field, builder.field_count),
		}},
	})
	fields := result.struct_.fields
	
	index := builder.field_count - 1
	
	for field := builder.field_list; field != nil; field = field.next
	{
		fields[index] = field.struct_field
		index -= 1
	}
	
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

maybe_cast_to_tag :: proc(builder: ^Function_Builder, name: string, value: ^Value) -> ^Value
{
	assert(value.descriptor.type == .Pointer)
	descriptor := value.descriptor.pointer_to
	
	// FIXME
	assert(value.operand.type == .Register)
	tag := Value \
	{
		descriptor = &descriptor_i64,
		operand =
		{
			type      = .Memory_Indirect,
			byte_size = size_of(i64),
			data = {indirect =
			{
				reg          = value.operand.reg,
				displacement = 0,
			}},
		},
	}
	
	for struct_, i in &descriptor.tagged_union.structs
	{
		if struct_.name == name
		{
			constructor_descriptor := new_clone(Descriptor \
			{
				type = .Struct,
				data = {struct_ = struct_},
			})
			pointer_descriptor := descriptor_pointer_to(constructor_descriptor)
			result := new_clone(Value \
			{
				descriptor = pointer_descriptor,
				operand = rbx,
			})
			
			move_value(builder, result, value_from_i64(0))
			
			comparison := compare(builder, .Equal, &tag, value_from_i64(i64(i)))
			label := make_if(builder, comparison)
			{
				move_value(builder, result, value)
				sum := plus(builder, result, value_from_i64(size_of(i64)))
				move_value(builder, result, sum)
			}
			end_if(builder, label)
			
			return result
		}
	}
	assert(false, "Could not find specified name in tagged union")
	return nil
}

MaybeCastToTag :: proc(name: string, value: ^Value) -> ^Value
{
	builder := get_builder_from_context()
	
	return maybe_cast_to_tag(builder, name, value)
}

create_is_character_in_set_checker_fn :: proc(characters: string) -> fn_type_i32_to_i8
{
	assert(characters != "")
	checker := Function()
	{
		character := Arg_i32()
		for ch in characters
		{
			If(Eq(character, value_from_i32(i32(ch))))
			{
				Return(value_from_i8(1))
			}
			End_If()
		}
		Return(value_from_i8(0))
	}
	End_Function()
	program_end(&test_program)
	return value_as_function(checker, fn_type_i32_to_i8)
}

mass_spec :: proc()
{
	spec("mass")
	
	temp_buffer := make_buffer(1024 * 1024, PAGE_READWRITE)
	context.allocator = buffer_allocator(&temp_buffer)
	
	fn_context: Function_Context
	context.user_ptr = &fn_context
	
	before_each(proc()
	{
		test_program =
		{
			data_buffer      = make_buffer(128 * 1024, PAGE_READWRITE),
			import_libraries = make([dynamic]Import_Library, 0, 16),
			functions        = make([dynamic]Function_Builder, 0, 16),
		}
		
		// NOTE(Lothar): Need to clear the fn_context so that its dynamic arrays don't continue to point
		// into the freed temp buffer
		fn_context := cast(^Function_Context)context.user_ptr
		fn_context^ = {}
	})
	
	after_each(proc()
	{
		free_buffer(&test_program.data_buffer)
		free_all()
	})
	
	it("should have a way to create a function to check if a character is one of the provided set", proc()
	{
		is_whitespace := create_is_character_in_set_checker_fn(" \n\r\t")
		check(bool(is_whitespace(' ')))
		check(bool(is_whitespace('\n')))
		check(bool(is_whitespace('\r')))
		check(bool(is_whitespace('\t')))
		check(!bool(is_whitespace('a')))
		check(!bool(is_whitespace('2')))
		check(!bool(is_whitespace('-')))
	})
	
	it("should support returning structs larger than 64 bits on the stack", proc()
	{
		struct_builder := struct_begin()
		struct_add_field(&struct_builder, &descriptor_i64, "x")
		struct_add_field(&struct_builder, &descriptor_i64, "y")
		point_struct_descriptor := struct_end(&struct_builder)
		
		return_value: Value =
		{
			descriptor = point_struct_descriptor,
			operand =
			{
				type      = .Memory_Indirect,
				byte_size = 1, // NOTE(Lothar): Shouldn't matter, but must be 1, 2, 4, or 8 for lea
				data = {indirect =
				{
					reg          = rsp.reg,
					displacement = 0,
				}},
			},
		}
		
		c_test_fn_descriptor: Descriptor =
		{
			type = .Function,
			data = {function =
			{
				returns = &return_value,
			}},
		}
		
		c_test_fn_value: Value =
		{
			descriptor = &c_test_fn_descriptor,
			operand = imm64(rawptr(test)),
		}
		
		checker_value := Function()
		{
			test_result := Call(&c_test_fn_value)
			x := StructField(test_result, "x")
			Return(x)
		}
		End_Function()
		program_end(&test_program)
		
		checker := value_as_function(checker_value, fn_void_to_i64)
		check(checker() == 42)
	})
	
	it("should support RIP-relative addressing", proc()
	{
		global_a := value_global(&test_program, &descriptor_i32)
		{
			check(global_a.operand.type == .RIP_Relative)
			
			address := cast(^i32)rip_value_pointer(&test_program, global_a)
			address^ = 32
		}
		global_b := value_global(&test_program, &descriptor_i32)
		{
			check(global_b.operand.type == .RIP_Relative)
			
			address := cast(^i32)rip_value_pointer(&test_program, global_b)
			address^ = 10
		}
		
		return_42 := Function()
		{
			Return(Plus(global_a, global_b))
		}
		End_Function()
		program_end(&test_program)
		
		checker := value_as_function(return_42, fn_void_to_i32)
		check(checker() == 42)
	})
	
	it("should support sizeof operator on values", proc()
	{
		sizeof_i32 := SizeOf(value_from_i32(0))
		check(sizeof_i32.operand.type == .Immediate_32)
		check(sizeof_i32.operand.imm32 == 4)
	})
	
	it("should support sizeof operator on descriptors", proc()
	{
		sizeof_i32 := SizeOfDescriptor(&descriptor_i32)
		check(sizeof_i32.operand.type == .Immediate_32)
		check(sizeof_i32.operand.imm32 == 4)
	})
	
	it("should support reflection on structs", proc()
	{
		struct_builder := struct_begin()
		struct_add_field(&struct_builder, &descriptor_i32, "x")
		struct_add_field(&struct_builder, &descriptor_i32, "y")
		point_struct_descriptor := struct_end(&struct_builder)
		
		field_count := Function()
		{
			struct_ := Stack(&descriptor_struct_reflection, ReflectDescriptor(point_struct_descriptor))
			Return(StructField(struct_, "field_count"))
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(field_count, fn_void_to_i32)()
		check(result == 2)
	})
	
	it("should support tagged unions", proc()
	{
		some_fields := [?]Descriptor_Struct_Field \
		{
			{
				name       = "value",
				descriptor = &descriptor_i64,
				offset     = 0,
			},
		}
		
		constructors := [?]Descriptor_Struct \
		{
			{
				name = "None",
				fields = nil,
			},
			{
				name = "Some",
				fields = some_fields[:],
			},
		}
		
		option_i64_descriptor: Descriptor =
		{
			type = .Tagged_Union,
			data = {tagged_union =
			{
				structs = constructors[:],
			}},
		}
		
		with_default_value := Function()
		{
			option_value := Arg(descriptor_pointer_to(&option_i64_descriptor))
			default_value := Arg_i64()
			some := MaybeCastToTag("Some", option_value)
			If(some)
			{
				value := StructField(some, "value")
				Return(value)
			}
			End_If()
			Return(default_value)
		}
		End_Function()
		program_end(&test_program)
		
		with_default := value_as_function(with_default_value, fn_rawptr_i64_to_i64)
		test_none: struct {tag: i64, maybe_value: i64} = {}
		test_some: struct {tag: i64, maybe_value: i64} = {1, 21}
		check(with_default(&test_none, 42) == 42)
		check(with_default(&test_some, 42) == 21)
	})
	
	it("should say that the types are the same for integers of the same size", proc()
	{
		check(same_type(&descriptor_i32, &descriptor_i32))
	})
	
	it("should say that the types are not the same for integers of different sizes", proc()
	{
		check(!same_type(&descriptor_i64, &descriptor_i32))
	})
	
	it("should say that pointer and i64 are different types", proc()
	{
		check(!same_type(&descriptor_i64, descriptor_pointer_to(&descriptor_i64)))
	})
	
	it("should say that (^i64) is not the same as (^i32)", proc()
	{
		check(!same_type(descriptor_pointer_to(&descriptor_i64),
		                 descriptor_pointer_to(&descriptor_i32)))
	})
	
	it("should say that ([2]i64) is not the same as ([2]i32)", proc()
	{
		check(!same_type(descriptor_array_of(&descriptor_i64, 2),
		                 descriptor_array_of(&descriptor_i32, 2)))
	})
	
	it("should say that ([10]i64) is not the same as ([2]i64)", proc()
	{
		check(!same_type(descriptor_array_of(&descriptor_i64, 10),
		                 descriptor_array_of(&descriptor_i64, 2)))
	})
	
	it("should say that structs are different if their descriptors are different pointers)", proc()
	{
		struct_builder := struct_begin()
		struct_add_field(&struct_builder, &descriptor_i32, "x")
		a := struct_end(&struct_builder)
		
		struct_builder = struct_begin()
		struct_add_field(&struct_builder, &descriptor_i32, "x")
		b := struct_end(&struct_builder)
		
		check(same_type(a, a))
		check(!same_type(a, b))
	})
	
	it("should support structs", proc()
	{
		// Size :: struct { width: i32, height: i32 }
		
		struct_builder := struct_begin()
		
		width_field  := struct_add_field(&struct_builder, &descriptor_i32, "width")
		height_field := struct_add_field(&struct_builder, &descriptor_i32, "height")
		struct_add_field(&struct_builder, &descriptor_i32, "dummy")
		
		size_struct_descriptor := struct_end(&struct_builder)
		
		size_struct_pointer_descriptor := descriptor_pointer_to(size_struct_descriptor)
		
		area := Function()
		{
			size_struct := Arg(size_struct_pointer_descriptor)
			Return(Multiply(StructField(size_struct, "width"),
			                StructField(size_struct, "height")))
		}
		End_Function()
		program_end(&test_program)
		
		size: struct {width: i32, height: i32, dummy: i32} = {10, 42, 0}
		result: i32 = value_as_function(area, fn_rawptr_to_i32)(&size)
		check(result == 420)
		check(size_of(size) == struct_builder.offset)
	})
	
	it("should add 1 to all numbers in an array", proc()
	{
		array := [?]i32{1, 2, 3}
		
		array_descriptor: Descriptor =
		{
			type = .Fixed_Size_Array,
			data = {array =
			{
				item   = &descriptor_i32,
				length = len(array),
			}},
		}
		
		array_pointer_descriptor := descriptor_pointer_to(&array_descriptor)
		
		increment := Function()
		{
			builder := get_builder_from_context()
			
			arr := Arg(array_pointer_descriptor)
			
			index := Stack_i32(value_from_i32(0))
			
			temp := Stack(array_pointer_descriptor, arr)
			
			item_byte_size := descriptor_byte_size(array_pointer_descriptor.pointer_to.array.item)
			
			Loop()
			{
				// TODO check that the descriptor is indeed an array
				length := i32(array_pointer_descriptor.pointer_to.array.length)
				
				If(Greater(index, value_from_i32(length - 1)))
				{
					Break()
				}
				End_If()
				
				reg_a := value_register_for_descriptor(.A, array_pointer_descriptor)
				move_value(builder, reg_a, temp)
				
				pointer: Operand =
				{
					type = .Memory_Indirect,
					byte_size = item_byte_size,
					data = {indirect =
					{
						reg          = rax.reg,
						displacement = 0,
					}},
				}
				push_instruction(builder, {inc, {pointer, {}, {}}, nil, #location()})
				push_instruction(builder, {add, {temp.operand, imm32(i32(item_byte_size)), {}}, nil, #location()})
				
				push_instruction(builder, {inc, {index.operand, {}, {}}, nil, #location()})
				
				Continue()
			}
			End_Loop()
		}
		End_Function()
		program_end(&test_program)
		
		value_as_function(increment, fn_pi32_to_void)(&array[0])
		check(array[0] == 2)
		check(array[1] == 3)
		check(array[2] == 4)
	})
}

Point :: struct
{
	x: i64,
	y: i64,
}

test :: proc "c" () -> Point
{
	return Point{42, 84}
}

main :: proc()
{
	mass_spec()
	function_spec()
	source_spec()
	
	print_test_results()
}
