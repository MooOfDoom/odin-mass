package main

import "core:fmt"
import "core:intrinsics"
import "core:mem"
import "core:strings"

Operand_Type :: enum
{
	None,
	Register,
	Immediate_8,
	Immediate_32,
	Immediate_64,
	Memory_Indirect,
	Sib,
	RIP_Relative,
	RIP_Relative_Import,
	Label_32,
}

Operand_Memory_Indirect :: struct
{
	reg:          Register,
	displacement: i32,
}
Operand_Sib :: struct
{
	scale:        u8,
	index:        Register,
	base:         Register,
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

Import_Symbol :: struct
{
	name:           string,
	name_rva:       u32,
	offset_in_data: u32,
}

Import_Library :: struct
{
	name:            string,
	name_rva:        u32,
	iat_rva:         u32,
	symbols:         [dynamic]Import_Symbol,
	image_thunk_rva: u32,
}

Operand_RIP_Relative_Import :: struct
{
	library_name: string,
	symbol_name:  string,
}

Operand :: struct
{
	type:      Operand_Type,
	byte_size: i32,
	using data: struct #raw_union
	{
		reg:                Register,
		imm8:               i8,
		imm32:              i32,
		imm64:              i64,
		label32:            ^Label,
		indirect:           Operand_Memory_Indirect,
		sib:                Operand_Sib,
		rip_offset_in_data: int,
		import_:            Operand_RIP_Relative_Import,
	},
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
	Type,
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
	arguments:     [dynamic]^Value,
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
	fields: [dynamic]Descriptor_Struct_Field,
}

Descriptor_Tagged_Union :: struct
{
	structs: []Descriptor_Struct,
}

Descriptor :: struct
{
	type: Descriptor_Type,
	using data: struct #raw_union
	{
		integer:         Descriptor_Integer,
		pointer_to:      ^Descriptor,
		array:           Descriptor_Fixed_Size_Array,
		function:        Descriptor_Function,
		struct_:         Descriptor_Struct,
		tagged_union:    Descriptor_Tagged_Union,
		type_descriptor: ^Descriptor,
	},
}

Value :: struct
{
	descriptor: ^Descriptor,
	operand:    Operand,
}

descriptor_void: Descriptor = {type = .Void}

descriptor_i8: Descriptor =
{
	type = .Integer,
	data = {integer = {byte_size = 1}},
}
descriptor_i16: Descriptor =
{
	type = .Integer,
	data = {integer = {byte_size = 2}},
}
descriptor_i32: Descriptor =
{
	type = .Integer,
	data = {integer = {byte_size = 4}},
}
descriptor_i64: Descriptor =
{
	type = .Integer,
	data = {integer = {byte_size = 8}},
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
	data = {struct_ =
	{
		fields = slice_as_dynamic(struct_reflection_fields[:]),
	}},
}

void_value: Value =
{
	descriptor = &descriptor_void,
	operand    = {type = .None},
}

type_s8_descriptor: Descriptor =
{
	type = .Type,
	data = {type_descriptor = &descriptor_i8},
}

type_s32_descriptor: Descriptor =
{
	type = .Type,
	data = {type_descriptor = &descriptor_i32},
}

type_s64_descriptor: Descriptor =
{
	type = .Type,
	data = {type_descriptor = &descriptor_i64},
}

type_s8_value: Value =
{
	descriptor = &type_s8_descriptor,
	operand = {type = .None},
}

type_s32_value: Value =
{
	descriptor = &type_s32_descriptor,
	operand = {type = .None},
}

type_s64_value: Value =
{
	descriptor = &type_s64_descriptor,
	operand = {type = .None},
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
		case .Memory_Indirect, .Sib:
		{
			bits := operand.byte_size * 8
			fmt.printf("m%v", bits)
		}
		case .RIP_Relative:
		{
			fmt.printf("[.rdata + 0x%x]", operand.rip_offset_in_data)
		}
		case .RIP_Relative_Import:
		{
			fmt.printf("rip_import(%v:%s)", operand.import_.library_name, operand.import_.symbol_name)
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

Function_Builder :: struct
{
	stack_reserve: i32,
	max_call_parameters_stack_size: i32,
	
	prolog_label: ^Label,
	epilog_label: ^Label,
	
	instructions: [dynamic]Instruction,
	program:      ^Program,
	result:       ^Value,
}

Program :: struct
{
	data_buffer:      Buffer,
	import_libraries: [dynamic]Import_Library,
	entry_point:      ^Value,
	functions:        [dynamic]Function_Builder,
	code_base_rva:    i64,
	data_base_rva:    i64,
	global_scope:     ^Scope,
}

Jit_Program :: struct
{
	code_buffer: Buffer,
	data_buffer: Buffer,
}

// AL, AX, EAX, RAX
Register :: enum u8
{
	A       = 0b0000,
	C       = 0b0001,
	D       = 0b0010,
	B       = 0b0011,
	
	AH      = 0b0100,
	SP      = 0b0100,
	R_M_SIB = 0b0100,
	
	CH      = 0b0101,
	BP      = 0b0101,
	
	DH      = 0b0110,
	SI      = 0b0110,
	
	BH      = 0b0111,
	DI      = 0b0111,
	
	R8      = 0b1000,
	R9      = 0b1001,
	R10     = 0b1010,
	R11     = 0b1011,
	R12     = 0b1100,
	R13     = 0b1101,
	R14     = 0b1110,
	R15     = 0b1111,
}

al := Operand{type = .Register, byte_size = 1, data = {reg = .A}}
cl := Operand{type = .Register, byte_size = 1, data = {reg = .C}}
dl := Operand{type = .Register, byte_size = 1, data = {reg = .D}}
bl := Operand{type = .Register, byte_size = 1, data = {reg = .B}}

ax := Operand{type = .Register, byte_size = 2, data = {reg = .A}}
cx := Operand{type = .Register, byte_size = 2, data = {reg = .C}}
dx := Operand{type = .Register, byte_size = 2, data = {reg = .D}}
bx := Operand{type = .Register, byte_size = 2, data = {reg = .B}}
sp := Operand{type = .Register, byte_size = 2, data = {reg = .SP}}
bp := Operand{type = .Register, byte_size = 2, data = {reg = .BP}}
si := Operand{type = .Register, byte_size = 2, data = {reg = .SI}}
di := Operand{type = .Register, byte_size = 2, data = {reg = .DI}}

eax := Operand{type = .Register, byte_size = 4, data = {reg = .A}}
ecx := Operand{type = .Register, byte_size = 4, data = {reg = .C}}
edx := Operand{type = .Register, byte_size = 4, data = {reg = .D}}
ebx := Operand{type = .Register, byte_size = 4, data = {reg = .B}}
esp := Operand{type = .Register, byte_size = 4, data = {reg = .SP}}
ebp := Operand{type = .Register, byte_size = 4, data = {reg = .BP}}
esi := Operand{type = .Register, byte_size = 4, data = {reg = .SI}}
edi := Operand{type = .Register, byte_size = 4, data = {reg = .DI}}

r8d  := Operand{type = .Register, byte_size = 4, data = {reg = .R8}}
r9d  := Operand{type = .Register, byte_size = 4, data = {reg = .R9}}
r10d := Operand{type = .Register, byte_size = 4, data = {reg = .R10}}
r11d := Operand{type = .Register, byte_size = 4, data = {reg = .R11}}
r12d := Operand{type = .Register, byte_size = 4, data = {reg = .R12}}
r13d := Operand{type = .Register, byte_size = 4, data = {reg = .R13}}
r14d := Operand{type = .Register, byte_size = 4, data = {reg = .R14}}
r15d := Operand{type = .Register, byte_size = 4, data = {reg = .R15}}

rax := Operand{type = .Register, byte_size = 8, data = {reg = .A}}
rcx := Operand{type = .Register, byte_size = 8, data = {reg = .C}}
rdx := Operand{type = .Register, byte_size = 8, data = {reg = .D}}
rbx := Operand{type = .Register, byte_size = 8, data = {reg = .B}}
rsp := Operand{type = .Register, byte_size = 8, data = {reg = .SP}}
rbp := Operand{type = .Register, byte_size = 8, data = {reg = .BP}}
rsi := Operand{type = .Register, byte_size = 8, data = {reg = .SI}}
rdi := Operand{type = .Register, byte_size = 8, data = {reg = .DI}}

r8  := Operand{type = .Register, byte_size = 8, data = {reg = .R8}}
r9  := Operand{type = .Register, byte_size = 8, data = {reg = .R9}}
r10 := Operand{type = .Register, byte_size = 8, data = {reg = .R10}}
r11 := Operand{type = .Register, byte_size = 8, data = {reg = .R11}}
r12 := Operand{type = .Register, byte_size = 8, data = {reg = .R12}}
r13 := Operand{type = .Register, byte_size = 8, data = {reg = .R13}}
r14 := Operand{type = .Register, byte_size = 8, data = {reg = .R14}}
r15 := Operand{type = .Register, byte_size = 8, data = {reg = .R15}}

make_label :: proc(target: rawptr = nil) -> ^Label
{
	return new_clone(Label \
	{
		target    = target,
		locations = make([dynamic]Label_Location, 0, 16),
	})
}

label32 :: proc(label: ^Label) -> Operand
{
	return Operand{type = .Label_32, byte_size = 4, data = {label32 = label}}
}

imm8 :: proc(value: i8) -> Operand
{
	return Operand{type = .Immediate_8, byte_size = size_of(value), data = {imm8 = value}}
}

imm32 :: proc(value: i32) -> Operand
{
	return Operand{type = .Immediate_32, byte_size = size_of(value), data = {imm32 = value}}
}

imm64_i64 :: proc(value: i64) -> Operand
{
	return Operand{type = .Immediate_64, byte_size = size_of(value), data = {imm64 = value}}
}

imm64_rawptr :: proc(value: rawptr) -> Operand
{
	return Operand{type = .Immediate_64, byte_size = size_of(value), data = {imm64 = i64(uintptr(value))}}
}

imm64 :: proc
{
	imm64_i64,
	imm64_rawptr,
}

fits_into_i8 :: proc(value: $T) -> bool
	where intrinsics.type_is_integer(T)
{
	return value >= T(min(i8)) && value <= T(max(i8))
}

fits_into_u8 :: proc(value: $T) -> bool
	where intrinsics.type_is_integer(T)
{
	return value >= T(min(u8)) && value <= T(max(u8))
}

fits_into_i16 :: proc(value: $T) -> bool
	where intrinsics.type_is_integer(T)
{
	return value >= T(min(i16)) && value <= T(max(i16))
}

fits_into_u16 :: proc(value: $T) -> bool
	where intrinsics.type_is_integer(T)
{
	return value >= T(min(u16)) && value <= T(max(u16))
}

fits_into_i32 :: proc(value: $T) -> bool
	where intrinsics.type_is_integer(T)
{
	return value >= T(min(i32)) && value <= T(max(i32))
}

fits_into_u32 :: proc(value: $T) -> bool
	where intrinsics.type_is_integer(T)
{
	return value >= T(min(u32)) && value <= T(max(u32))
}

imm_auto :: proc(value: $T) -> Operand
	where intrinsics.type_is_integer(T)
{
	if fits_into_i8(value)
	{
		return imm8(i8(value))
	}
	if fits_into_i32(value)
	{
		return imm32(i32(value))
	}
	return imm64(i64(value))
}

stack :: proc(offset: i32, byte_size: i32) -> Operand
{
	return Operand{type = .Memory_Indirect, byte_size = byte_size, data = {indirect = {reg = .SP, displacement = offset}}}
}

descriptor_struct_make :: proc() -> ^Descriptor
{
	return new_clone(Descriptor \
	{
		type = .Struct,
		data = {struct_ =
		{
			fields = make([dynamic]Descriptor_Struct_Field, 0, 16),
		}},
	})
}

descriptor_struct_add_field :: proc(struct_descriptor: ^Descriptor, field_descriptor: ^Descriptor, field_name: string)
{
	offset: i32
	for field in &struct_descriptor.struct_.fields
	{
		size := descriptor_byte_size(field.descriptor)
		offset = align(offset, size)
		offset += size
	}
	
	size := descriptor_byte_size(field_descriptor)
	offset = align(offset, size)
	append(&struct_descriptor.struct_.fields, Descriptor_Struct_Field \
	{
		name = field_name,
		descriptor = field_descriptor,
		offset = offset,
	})
}

operand_immediate_as_i64 :: proc(operand: ^Operand) -> i64
{
	if operand.type == .Immediate_8  do return i64(operand.imm8)
	if operand.type == .Immediate_32 do return i64(operand.imm32)
	if operand.type == .Immediate_64 do return operand.imm64
	assert(false, "Expected an immediate operand")
	return 0
}

operand_is_memory :: proc(operand: ^Operand) -> bool
{
	return (operand.type == .Memory_Indirect ||
	        operand.type == .RIP_Relative ||
	        operand.type == .Sib)
}

operand_is_immediate :: proc(operand: ^Operand) -> bool
{
	return (operand.type == .Immediate_8  ||
	        operand.type == .Immediate_32 ||
	        operand.type == .Immediate_64)
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

value_from_signed_immediate :: proc(value: $T) -> ^Value
	where intrinsics.type_is_integer(T)
{
	if fits_into_i8(value)
	{
		return value_from_i8(i8(value))
	}
	// FIXME add value_from_i16
	if fits_into_i32(value)
	{
		return value_from_i32(i32(value))
	}
	return value_from_i64(i64(value))
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
			data      = {reg = reg},
		},
	})
}

rip_value_pointer :: proc(program: ^Program, value: ^Value) -> [^]byte
{
	assert(value.operand.type == .RIP_Relative)
	return &program.data_buffer.memory[value.operand.rip_offset_in_data]
}

value_global :: proc(program: ^Program, descriptor: ^Descriptor) -> ^Value
{
	byte_size := descriptor_byte_size(descriptor)
	alignment := descriptor_alignment(descriptor)
	program.data_buffer.occupied = align(program.data_buffer.occupied, int(alignment))
	address := &program.data_buffer.memory[program.data_buffer.occupied]
	program.data_buffer.occupied += int(byte_size)
	
	result := new_clone(Value \
	{
		descriptor = descriptor,
		operand =
		{
			type      = .RIP_Relative,
			byte_size = byte_size,
			data      = {rip_offset_in_data = program.data_buffer.occupied - int(byte_size)},
		},
	})
	return result
}

value_global_c_string :: proc(program: ^Program, str: string) -> ^Value
{
	length := i32(len(str) + 1)
	result := value_global(program, new_clone(Descriptor \
	{
		type = .Fixed_Size_Array,
		data = {array =
		{
			item = &descriptor_i8,
			length = length,
		}},
	}))
	
	address := program.data_buffer.memory[result.operand.rip_offset_in_data:result.operand.rip_offset_in_data + int(length)]
	copy(address, str)
	address[length - 1] = 0
	
	return result
}

descriptor_pointer_to :: proc(descriptor: ^Descriptor) -> ^Descriptor
{
	return new_clone(Descriptor \
	{
		type = .Pointer,
		data = {pointer_to = descriptor},
	})
}

descriptor_array_of :: proc(descriptor: ^Descriptor, length: i32) -> ^Descriptor
{
	return new_clone(Descriptor \
	{
		type = .Fixed_Size_Array,
		data = {array =
		{
			item   = descriptor,
			length = length,
		}},
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
			if (a.pointer_to.type == .Void ||
			    b.pointer_to.type == .Void)
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
			for arg_a, i in a.function.arguments
			{
				arg_b := b.function.arguments[i]
				if !same_type(arg_a.descriptor, arg_b.descriptor) do return false
			}
			return true
		}
		case .Void, .Integer:
		{
			return descriptor_byte_size(a) == descriptor_byte_size(b)
		}
		case .Type:
		case:
		{
			assert(false, "Unsupported descriptor type")
			return false
		}
	}
	return false
}

descriptor_alignment :: proc(descriptor: ^Descriptor) -> i32
{
	if descriptor.type == .Fixed_Size_Array
	{
		return descriptor_alignment(descriptor.array.item)
	}
	return descriptor_byte_size(descriptor)
}

same_value_type :: proc(a: ^Value, b: ^Value) -> bool
{
	return same_type(a.descriptor, b.descriptor)
}

same_value_type_or_can_implicitly_move_cast :: proc(target: ^Value, source: ^Value) -> bool
{
	if same_value_type(target, source) do return true
	if target.descriptor.type != source.descriptor.type do return false
	if target.descriptor.type == .Integer
	{
		if descriptor_byte_size(target.descriptor) > descriptor_byte_size(source.descriptor)
		{
			return true
		}
	}
	return false
}

struct_byte_size :: proc(struct_: ^Descriptor_Struct) -> i32
{
	count := len(struct_.fields)
	alignment: i32
	raw_size:  i32
	for field, i in struct_.fields
	{
		field_alignment := descriptor_alignment(field.descriptor)
		alignment = max(alignment, field_alignment)
		is_last_field := (i == count - 1)
		field_size_with_alignment := max(field_alignment, descriptor_byte_size(field.descriptor))
		if is_last_field
		{
			raw_size = field.offset + field_size_with_alignment
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
		case .Type:
		case:
		{
			fmt.println(descriptor)
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
	assert(value.operand.label32.target != nil, "Function label has target")
	return T(value.operand.label32.target)
}

function_push_argument :: proc(function: ^Descriptor_Function, arg_descriptor: ^Descriptor) -> ^Value
{
	byte_size := descriptor_byte_size(arg_descriptor)
	assert(byte_size <= 8, "Arg byte size <= 8")
	switch len(function.arguments)
	{
		case 0:
		{
			result := value_register_for_descriptor(.C, arg_descriptor)
			append(&function.arguments, result)
			return result
		}
		case 1:
		{
			result := value_register_for_descriptor(.D, arg_descriptor)
			append(&function.arguments, result)
			return result
		}
		case 2:
		{
			result := value_register_for_descriptor(.R8, arg_descriptor)
			append(&function.arguments, result)
			return result
		}
		case 3:
		{
			result := value_register_for_descriptor(.R9, arg_descriptor)
			append(&function.arguments, result)
			return result
		}
		case:
		{
			// @Volatile @StackPatch
			offset  := i32(len(function.arguments) * size_of(i64))
			operand := stack(offset, byte_size)
			
			result := new_clone(Value \
			{
				descriptor = arg_descriptor,
				operand    = operand,
			})
			append(&function.arguments, result)
			return result
		}
	}
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
				inner_descriptor^ = new(Descriptor)
				inner_descriptor^.type = .Pointer
				inner_descriptor^.pointer_to = &descriptor_void
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
	
	type_end = min(type_end + 1, len(range))
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

odin_function_descriptor :: proc(forward_declaration: string) -> ^Descriptor
{
	result := new_clone(Descriptor{type = .Function})
	
	result.function.arguments = make([dynamic]^Value, 0, 16)
	result.function.returns = odin_function_return_value(forward_declaration)
	
	start := strings.index_byte(forward_declaration, '(')
	assert(start != -1)
	end := strings.index_byte(forward_declaration, ')')
	assert(end != -1)
	arg_decls := forward_declaration[start + 1:end]
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
			function_push_argument(&result.function, arg_desc)
		}
	}
	
	// fmt.println(forward_declaration)
	// fmt.println(result.function.arguments)
	
	return result
}

odin_function_value :: proc(forward_declaration: string, fn: fn_opaque) -> ^Value
{
	return new_clone(Value \
	{
		descriptor = odin_function_descriptor(forward_declaration),
		operand = imm64(fn),
	})
}

program_init :: proc(program: ^Program) -> ^Program
{
	program^ =
	{
		data_buffer      = make_buffer(128 * 1024, PAGE_READWRITE),
		import_libraries = make([dynamic]Import_Library, 0, 16),
		functions        = make([dynamic]Function_Builder, 0, 16),
		global_scope     = scope_make(),
	}
	
	scope_define_value(program.global_scope, "s8", &type_s8_value)
	scope_define_value(program.global_scope, "s32", &type_s32_value)
	scope_define_value(program.global_scope, "s64", &type_s64_value)
	return program
}

program_deinit :: proc(program: ^Program)
{
	free_buffer(&program.data_buffer)
	program^ = {}
}

ascii_strings_match_case_insensitive :: proc(a: string, b: string) -> bool
{
	if len(a) != len(b) do return false
	
	for i in 0 ..< len(a)
	{
		assert(a[i] <= 0x7f && b[i] <= 0x7f)
		lower_a := a[i] | 0x20
		lower_b := b[i] | 0x20
		if lower_a >= 'a' && lower_a <= 'z'
		{
			if lower_a != lower_b do return false
		}
		else if a[i] != b[i]
		{
			return false
		}
	}
	return true
}

program_find_import_library :: proc(program: ^Program, library_name: string) -> ^Import_Library
{
	for lib in &program.import_libraries
	{
		if ascii_strings_match_case_insensitive(lib.name, library_name)
		{
			return &lib
		}
	}
	return nil
}

import_library_find_symbol :: proc(library: ^Import_Library, symbol_name: string) -> ^Import_Symbol
{
	for sym in &library.symbols
	{
		if sym.name == symbol_name
		{
			return &sym
		}
	}
	return nil
}

program_find_import :: proc(program: ^Program, library_name: string, symbol_name: string) -> ^Import_Symbol
{
	lib := program_find_import_library(program, library_name)
	if lib == nil do return nil
	return import_library_find_symbol(lib, symbol_name)
}

import_symbol :: proc(program: ^Program, library_name: string, symbol_name: string) -> Operand
{
	library := program_find_import_library(program, library_name)
	
	if library == nil
	{
		append(&program.import_libraries, Import_Library \
		{
			name            = library_name,
			name_rva        = 0xcccccccc,
			iat_rva         = 0xcccccccc,
			image_thunk_rva = 0xcccccccc,
			symbols         = make([dynamic]Import_Symbol, 0, 16),
		})
		library = &program.import_libraries[len(program.import_libraries) - 1]
	}
	
	symbol := import_library_find_symbol(library, symbol_name)
	
	if symbol == nil
	{
		append(&library.symbols, Import_Symbol \
		{
			name           = symbol_name,
			name_rva       = 0xcccccccc,
			offset_in_data = 0,
		})
	}
	
	return Operand \
	{
		type = .RIP_Relative_Import,
		byte_size = size_of(rawptr), // Size of the pointer
		data = {import_ =
		{
			library_name = library_name,
			symbol_name  = symbol_name,
		}},
	}
}

odin_function_import :: proc(program: ^Program, library_name: string, forward_declaration: string) -> ^Value
{
	symbol_name_end := strings.index_byte(forward_declaration, ':')
	assert(symbol_name_end != -1)
	symbol_name := strings.trim_space(forward_declaration[:symbol_name_end])
	
	return new_clone(Value \
	{
		descriptor = odin_function_descriptor(forward_declaration),
		operand = import_symbol(program, library_name, symbol_name),
	})
}

estimate_max_code_size_in_bytes :: proc(program: ^Program) -> int
{
	total_instruction_count: int
	for builder in &program.functions
	{
		// NOTE(Lothar): @Volatile Plus 2 because fn_encode adds 16 bytes worth of instructions
		total_instruction_count += len(builder.instructions) + 2 
	}
	// TODO this should be architecture-dependent
	max_bytes_per_instruction :: 15
	return total_instruction_count * max_bytes_per_instruction
}
