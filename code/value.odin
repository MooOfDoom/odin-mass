package main

import "core:fmt"
import "core:strings"

Operand_Type :: enum
{
	None,
	Register,
	Immediate_8,
	Immediate_32,
	Immediate_64,
	Memory_Indirect,
	RIP_Relative,
	Label_32,
	// External,
}

Operand_Memory_Indirect :: struct
{
	reg:          Register,
	displacement: i32,
}

Label_Location :: struct
{
	patch_target: ^i32,
	from_offset:  ^byte,
}

Label :: struct
{
	target:    rawptr,
	locations: [dynamic]Label_Location,
}

Operand :: struct
{
	type:      Operand_Type,
	byte_size: i32,
	// NOTE(Lothar): These should be in a raw union, but assignment doesn't work in Odin yet
		reg:      Register,
		imm8:     i8,
		imm32:    i32,
		imm64:    i64,
		label32:  ^Label,
		indirect: Operand_Memory_Indirect,
}

Descriptor_Type :: enum
{
	Void,
	Integer,
	Pointer,
	Fixed_Size_Array,
	Function,
	Struct,
	Tagged_Union,
}

Descriptor_Integer :: struct
{
	byte_size: i32,
}

Descriptor_Fixed_Size_Array :: struct
{
	item:   ^Descriptor,
	length: i32,
}

Descriptor_Function :: struct
{
	arguments:     [dynamic]Value,
	returns:       ^Value,
	frozen:        bool,
	next_overload: ^Value,
}

Descriptor_Struct_Field :: struct
{
	name:       string,
	descriptor: ^Descriptor,
	offset:     i32,
}

Descriptor_Struct :: struct
{
	name:   string,
	fields: []Descriptor_Struct_Field,
}

Descriptor_Tagged_Union :: struct
{
	structs: []Descriptor_Struct,
}

Descriptor :: struct
{
	type: Descriptor_Type,
	// NOTE(Lothar): These should be in a raw union, but assignment doesn't work in Odin yet
		integer:      Descriptor_Integer,
		pointer_to:   ^Descriptor,
		array:        Descriptor_Fixed_Size_Array,
		function:     Descriptor_Function,
		struct_:      Descriptor_Struct,
		tagged_union: Descriptor_Tagged_Union,
}

Value :: struct
{
	descriptor: ^Descriptor,
	operand:    Operand,
}

descriptor_void: Descriptor = {type = .Void}

descriptor_i8: Descriptor =
{
	type    = .Integer,
	integer = {byte_size = 1},
}
descriptor_i16: Descriptor =
{
	type    = .Integer,
	integer = {byte_size = 2},
}
descriptor_i32: Descriptor =
{
	type    = .Integer,
	integer = {byte_size = 4},
}
descriptor_i64: Descriptor =
{
	type    = .Integer,
	integer = {byte_size = 8},
}

// @Volatile @Reflection
Descriptor_Struct_Reflection :: struct
{
	field_count: i32,
}

// @Volatile @Reflection
struct_reflection_fields := [?]Descriptor_Struct_Field \
{
	{
		name       = "field_count",
		offset     = 0,
		descriptor = &descriptor_i32,
	},
}

descriptor_struct_reflection: Descriptor =
{
	type = .Struct,
	struct_ =
	{
		fields = struct_reflection_fields[:],
	},
}

void_value: Value =
{
	descriptor = &descriptor_void,
	operand    = {type = .None},
}

print_operand :: proc(operand: ^Operand)
{
	switch operand.type
	{
		case .None:
		{
			fmt.printf("_")
		}
		case .Register:
		{
			bits := operand.byte_size * 8
			fmt.printf("r%v", bits)
		}
		case .Immediate_8:
		{
			fmt.printf("imm8(0x%02x)", operand.imm8)
		}
		case .Immediate_32:
		{
			fmt.printf("imm32(0x%08x)", operand.imm32)
		}
		case .Immediate_64:
		{
			fmt.printf("imm64(0x%016x)", operand.imm64)
		}
		case .Memory_Indirect:
		{
			bits := operand.byte_size * 8
			fmt.printf("m%v", bits)
		}
		case .RIP_Relative:
		{
			fmt.printf("[rip + xxx]")
		}
		case .Label_32:
		{
			fmt.printf("Label")
		}
		case:
		{
			fmt.printf("<unknown>")
		}
	}
}

Stack_Patch :: struct
{
	location:  ^i32,
	byte_size: i32,
}

Fn_Builder :: struct
{
	stack_reserve: i32,
	max_call_parameters_stack_size: i32,
	
	buffer: ^Buffer,
	code_offset: int,
	
	epilog_label: ^Label,
	
	instructions:        [dynamic]Instruction,
	stack_displacements: [dynamic]Stack_Patch,
	
	result: ^Value,
}

// AL, AX, EAX, RAX
Register :: enum u8
{
	A   = 0b0000,
	C   = 0b0001,
	D   = 0b0010,
	B   = 0b0011,
	SP  = 0b0100,
	BP  = 0b0101,
	SI  = 0b0110,
	DI  = 0b0111,
	
	R8  = 0b1000,
	R9  = 0b1001,
	R10 = 0b1010,
	R11 = 0b1011,
	R12 = 0b1100,
	R13 = 0b1101,
	R14 = 0b1110,
	R15 = 0b1111,
}

al := Operand{type = .Register, byte_size = 1, reg = .A}
cl := Operand{type = .Register, byte_size = 1, reg = .C}
dl := Operand{type = .Register, byte_size = 1, reg = .D}
bl := Operand{type = .Register, byte_size = 1, reg = .B}

ax := Operand{type = .Register, byte_size = 2, reg = .A}
cx := Operand{type = .Register, byte_size = 2, reg = .C}
dx := Operand{type = .Register, byte_size = 2, reg = .D}
bx := Operand{type = .Register, byte_size = 2, reg = .B}
sp := Operand{type = .Register, byte_size = 2, reg = .SP}
bp := Operand{type = .Register, byte_size = 2, reg = .BP}
si := Operand{type = .Register, byte_size = 2, reg = .SI}
di := Operand{type = .Register, byte_size = 2, reg = .DI}

eax := Operand{type = .Register, byte_size = 4, reg = .A}
ecx := Operand{type = .Register, byte_size = 4, reg = .C}
edx := Operand{type = .Register, byte_size = 4, reg = .D}
ebx := Operand{type = .Register, byte_size = 4, reg = .B}
esp := Operand{type = .Register, byte_size = 4, reg = .SP}
ebp := Operand{type = .Register, byte_size = 4, reg = .BP}
esi := Operand{type = .Register, byte_size = 4, reg = .SI}
edi := Operand{type = .Register, byte_size = 4, reg = .DI}

r8d  := Operand{type = .Register, byte_size = 4, reg = .R8}
r9d  := Operand{type = .Register, byte_size = 4, reg = .R9}
r10d := Operand{type = .Register, byte_size = 4, reg = .R10}
r11d := Operand{type = .Register, byte_size = 4, reg = .R11}
r12d := Operand{type = .Register, byte_size = 4, reg = .R12}
r13d := Operand{type = .Register, byte_size = 4, reg = .R13}
r14d := Operand{type = .Register, byte_size = 4, reg = .R14}
r15d := Operand{type = .Register, byte_size = 4, reg = .R15}

rax := Operand{type = .Register, byte_size = 8, reg = .A}
rcx := Operand{type = .Register, byte_size = 8, reg = .C}
rdx := Operand{type = .Register, byte_size = 8, reg = .D}
rbx := Operand{type = .Register, byte_size = 8, reg = .B}
rsp := Operand{type = .Register, byte_size = 8, reg = .SP}
rbp := Operand{type = .Register, byte_size = 8, reg = .BP}
rsi := Operand{type = .Register, byte_size = 8, reg = .SI}
rdi := Operand{type = .Register, byte_size = 8, reg = .DI}

r8  := Operand{type = .Register, byte_size = 8, reg = .R8}
r9  := Operand{type = .Register, byte_size = 8, reg = .R9}
r10 := Operand{type = .Register, byte_size = 8, reg = .R10}
r11 := Operand{type = .Register, byte_size = 8, reg = .R11}
r12 := Operand{type = .Register, byte_size = 8, reg = .R12}
r13 := Operand{type = .Register, byte_size = 8, reg = .R13}
r14 := Operand{type = .Register, byte_size = 8, reg = .R14}
r15 := Operand{type = .Register, byte_size = 8, reg = .R15}

make_label :: proc(target: rawptr = nil) -> ^Label
{
	return new_clone(Label \
	{
		target    = target,
		locations = make([dynamic]Label_Location, 0, 32),
	})
}

label32 :: proc(label: ^Label) -> Operand
{
	return Operand{type = .Label_32, byte_size = 4, label32 = label}
}

imm8 :: proc(value: i8) -> Operand
{
	return Operand{type = .Immediate_8, byte_size = size_of(value), imm8 = value}
}

imm32 :: proc(value: i32) -> Operand
{
	return Operand{type = .Immediate_32, byte_size = size_of(value), imm32 = value}
}

imm64_i64 :: proc(value: i64) -> Operand
{
	return Operand{type = .Immediate_64, byte_size = size_of(value), imm64 = value}
}

imm64_rawptr :: proc(value: rawptr) -> Operand
{
	return Operand{type = .Immediate_64, byte_size = size_of(value), imm64 = i64(uintptr(value))}
}

imm64 :: proc
{
	imm64_i64,
	imm64_rawptr,
}

imm_auto_i32 :: proc(value: i32) -> Operand
{
	if value >= i32(min(i8)) && value <= i32(max(i8))
	{
		return imm8(i8(value))
	}
	return imm32(value)
}

imm_auto_i64 :: proc(value: i64) -> Operand
{
	if value >= i64(min(i8)) && value <= i64(max(i8))
	{
		return imm8(i8(value))
	}
	if value >= i64(min(i32)) && value <= i64(max(i32))
	{
		return imm32(i32(value))
	}
	return imm64(value)
}

imm_auto :: proc
{
	imm_auto_i32,
	imm_auto_i64,
}

stack :: proc(offset: i32, byte_size: i32) -> Operand
{
	return Operand{type = .Memory_Indirect, byte_size = byte_size, indirect = {reg = .SP, displacement = offset}}
}

value_from_i8 :: proc(integer: i8) -> ^Value
{
	return new_clone(Value \
	{
		descriptor = &descriptor_i8,
		operand    = imm8(integer),
	})
}

value_from_i32 :: proc(integer: i32) -> ^Value
{
	return new_clone(Value \
	{
		descriptor = &descriptor_i32,
		operand    = imm32(integer),
	})
}

value_from_i64 :: proc(integer: i64) -> ^Value
{
	return new_clone(Value \
	{
		descriptor = &descriptor_i64,
		operand    = imm64(integer),
	})
}

value_register_for_descriptor :: proc(reg: Register, descriptor: ^Descriptor) -> ^Value
{
	byte_size := descriptor_byte_size(descriptor)
	assert(byte_size == 1 || byte_size == 2 || byte_size == 4 || byte_size == 8, "Descriptor byte size fits in a register")
	return new_clone(Value \
	{
		descriptor = descriptor,
		operand =
		{
			type      = .Register,
			byte_size = byte_size,
			reg       = reg,
		},
	})
}

descriptor_pointer_to :: proc(descriptor: ^Descriptor) -> ^Descriptor
{
	return new_clone(Descriptor \
	{
		type       = .Pointer,
		pointer_to = descriptor,
	})
}

descriptor_array_of :: proc(descriptor: ^Descriptor, length: i32) -> ^Descriptor
{
	return new_clone(Descriptor \
	{
		type  = .Fixed_Size_Array,
		array =
		{
			item   = descriptor,
			length = length,
		},
	})
}

same_type :: proc(a: ^Descriptor, b: ^Descriptor) -> bool
{
	if a.type != b.type do return false
	switch a.type
	{
		case .Pointer:
		{
			if (a.pointer_to.type == .Fixed_Size_Array &&
			    same_type(a.pointer_to.array.item, b.pointer_to))
			{
				return true
			}
			if (b.pointer_to.type == .Fixed_Size_Array &&
			    same_type(b.pointer_to.array.item, a.pointer_to))
			{
				return true
			}
			return same_type(a.pointer_to, b.pointer_to)
		}
		case .Fixed_Size_Array:
		{
			return same_type(a.array.item, b.array.item) && a.array.length == b.array.length
		}
		case .Struct, .Tagged_Union:
		{
			return a == b
		}
		case .Function:
		{
			if !same_type(a.function.returns.descriptor, b.function.returns.descriptor) do return false
			if len(a.function.arguments) != len(b.function.arguments) do return false
			for arg_a, i in &a.function.arguments
			{
				arg_b := &b.function.arguments[i]
				if !same_type(arg_a.descriptor, arg_b.descriptor) do return false
			}
			return true
		}
		case .Void, .Integer:
		{
			return descriptor_byte_size(a) == descriptor_byte_size(b)
		}
	}
	return false
}

same_value_type :: proc(a: ^Value, b: ^Value) -> bool
{
	return same_type(a.descriptor, b.descriptor)
}

struct_byte_size :: proc(struct_: ^Descriptor_Struct) -> i32
{
	count := len(struct_.fields)
	alignment: i32
	raw_size:  i32
	for field, i in struct_.fields
	{
		field_size := descriptor_byte_size(field.descriptor)
		alignment = max(alignment, field_size)
		is_last_field := (i == count - 1)
		if is_last_field
		{
			raw_size = field.offset + field_size
		}
	}
	return align(raw_size, alignment)
}

descriptor_byte_size :: proc(descriptor: ^Descriptor) -> i32
{
	assert(descriptor != nil)
	switch descriptor.type
	{
		case .Void:
		{
			return 0
		}
		case .Tagged_Union:
		{
			count := len(descriptor.struct_.fields)
			tag_size: i32 = size_of(i64)
			body_size: i32
			for struct_, i in &descriptor.tagged_union.structs
			{
				struct_size := struct_byte_size(&struct_)
				body_size = max(body_size, struct_size)
			}
			return tag_size + body_size
		}
		case .Struct:
		{
			return struct_byte_size(&descriptor.struct_)
		}
		case .Integer:
		{
			return descriptor.integer.byte_size
		}
		case .Fixed_Size_Array:
		{
			return descriptor_byte_size(descriptor.array.item) * descriptor.array.length
		}
		case .Pointer, .Function:
		{
			return size_of(rawptr)
		}
		case:
		{
			assert(false, "Unknown Descriptor Type")
		}
	}
	return 0
}

value_byte_size :: proc(value: ^Value) -> ^Value
{
	return value_from_i32(descriptor_byte_size(value.descriptor))
}

value_as_function :: proc(value: ^Value, $T: typeid) -> T
{
	assert(value.operand.type == .Label_32, "Function value is Label")
	return T(value.operand.label32.target)
}

parse_odin_type :: proc(range: string) -> (^Descriptor, int)
{
	descriptor: ^Descriptor
	inner_descriptor := &descriptor
	
	type_start := 0
	type_end   := 0
	for index := 0; index < len(range); index += 1
	{
		ch := range[index]
		
		is_pointer := false
		if ch == ')' || ch == ',' || index == len(range) - 1
		{
			if ch == ')' || ch == ','
			{
				type_end = index
			}
			else
			{
				type_end = len(range)
			}
			type := strings.trim_space(range[type_start:type_end])
			if type == ""
			{
				// No type
			}
			else if type == "byte"
			{
				inner_descriptor^ = &descriptor_i8
			}
			else if type == "i8"
			{
				inner_descriptor^ = &descriptor_i8
			}
			else if type == "u8"
			{
				inner_descriptor^ = &descriptor_i8
			}
			else if type == "i16"
			{
				inner_descriptor^ = &descriptor_i16
			}
			else if type == "u16"
			{
				inner_descriptor^ = &descriptor_i16
			}
			else if type == "i32"
			{
				inner_descriptor^ = &descriptor_i32
			}
			else if type == "u32"
			{
				inner_descriptor^ = &descriptor_i32
			}
			else if type == "i64"
			{
				inner_descriptor^ = &descriptor_i64
			}
			else if type == "u64"
			{
				inner_descriptor^ = &descriptor_i64
			}
			else if type == "int"
			{
				inner_descriptor^ = &descriptor_i64
			}
			else if type == "uint"
			{
				inner_descriptor^ = &descriptor_i64
			}
			else if type == "rawptr"
			{
				inner_descriptor^ = &descriptor_i64
			}
			else if type == "cstring"
			{
				inner_descriptor^ = new(Descriptor)
				inner_descriptor^.type = .Pointer
				inner_descriptor^.pointer_to = &descriptor_i8
			}
			else
			{
				assert(false, "Unsupported type")
			}
			break
		}
		else if ch == '^'
		{
			is_pointer = true
			type_start = index + 1
		}
		else if (ch == '[' && index + 2 < len(range) &&
		         range[index + 1] == '^' &&
		         range[index + 2] == ']')
		{
			is_pointer = true
			index += 2
			type_start = index + 1
		}
		
		if is_pointer
		{
			inner_descriptor^ = new(Descriptor)
			inner_descriptor^.type = .Pointer
			inner_descriptor^.pointer_to = nil // TODO(Lothar): Check if this is necessary. Does new zero memory?
			inner_descriptor = &inner_descriptor^.pointer_to
		}
	}
	
	return descriptor, type_end
}

odin_function_return_value :: proc(forward_declaration: string) -> ^Value
{
	result: ^Value
	
	ret_type_idx := strings.index(forward_declaration, "->")
	if ret_type_idx == -1
	{
		result = &void_value
	}
	else
	{
		type := strings.trim_space(forward_declaration[ret_type_idx + 2:])
		descriptor, _ := parse_odin_type(type)
		return_byte_size := descriptor_byte_size(descriptor)
		assert(return_byte_size <= 8, "Return values larger than 8 bytes unsupported")
		result = value_register_for_descriptor(.A, descriptor)
	}
	
	return result
}

odin_function_value :: proc(forward_declaration: string, fn: fn_opaque) -> ^Value
{
	result := new_clone(Value \
	{
		descriptor = new_clone(Descriptor{type = .Function}),
		operand = imm64(fn),
	})
	
	result.descriptor.function.returns = odin_function_return_value(forward_declaration)
	
	start := strings.index_byte(forward_declaration, '(')
	assert(start != -1)
	end := strings.index_byte(forward_declaration, ')')
	assert(end != -1)
	arg_decls := forward_declaration[start + 1:end]
	arg_index := 0
	for arg_decls != ""
	{
		arg_desc, length := parse_odin_type(arg_decls)
		if length == 0
		{
			break
		}
		arg_decls = arg_decls[length:]
		if arg_desc != nil
		{
			append(&result.descriptor.function.arguments, Value \
			{
				descriptor = arg_desc,
				operand = {type = .Register, byte_size = descriptor_byte_size(arg_desc), reg = .C}, // FIXME should not use a hardcoded register here
			})
			arg_index += 1
		}
	}
	
	return result
}
