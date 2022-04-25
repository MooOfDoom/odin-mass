package main

import "core:fmt"
import "core:runtime"
import "core:sys/win32"

test_program: Program

make_identity :: proc(type: ^Descriptor) -> ^Value
{
	id := Function()
	{
		x := Arg(type)
		Return(x)
	}
	End_Function()
	
	return id
}

make_add_two :: proc(type: ^Descriptor) -> ^Value
{
	addtwo := Function()
	{
		x := Arg(type)
		Return(Plus(x, value_from_i64(2)))
	}
	End_Function()
	
	return addtwo
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

function_spec :: proc()
{
	spec("function")
	
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
			global_scope     = scope_make(),
		}
		
		scope_define(test_program.global_scope, "s32", &type_s32_value)
		scope_define(test_program.global_scope, "s64", &type_s64_value)
		
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
	
	it("should be able to parse a void -> s64 function", proc()
	{
		source := `foo :: () -> (s64) { 42 }`
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.type == .Module)
		
		// print_token_tree(root)
		
		state: Token_Matcher_State =
		{
			root        = root,
			child_index = 0,
		}
		match_function := token_match_function_definition(&state, &test_program)
		check(match_function != nil)
		
		check(match_function.name == "foo")
		
		program_end(&test_program)
		
		checker := value_as_function(match_function.value, fn_void_to_i64)
		check(checker() == 42)
	})
	
	it("should be able to parse a s64 -> s64 function", proc()
	{
		source := `foo :: (x : s64) -> (s64) { x }`
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.type == .Module)
		
		// print_token_tree(root)
		
		state: Token_Matcher_State = {root = root}
		match_function := token_match_function_definition(&state, &test_program)
		check(match_function != nil)
		
		check(match_function.name == "foo")
		
		program_end(&test_program)
		
		checker := value_as_function(match_function.value, fn_i64_to_i64)
		check(checker(42) == 42)
		check(checker(21) == 21)
	})
	
	it("should write out an executable that exits with status code 42", proc()
	{
		program := &test_program
		
		ExitProcess_value := odin_function_import(program, "kernel32.dll", `ExitProcess :: proc "std" (i32)`)
		
		my_exit := Function()
		{
			Call(ExitProcess_value, value_from_i32(42))
		}
		End_Function()
		
		main := Function()
		{
			program.entry_point = get_builder_from_context()
			Call(my_exit)
		}
		End_Function()
		
		write_executable("build\\test.exe", program)
	})
	
	it("should write out an executable that prints Hello, world!", proc()
	{
		program := &test_program
		
		GetStdHandle_value := odin_function_import(program, "kernel32.dll", `GetStdHandle :: proc "std" (i32) -> i64`)
		STD_OUTPUT_HANDLE_value := value_from_i32(-11)
		ExitProcess_value := odin_function_import(program, "kernel32.dll", `ExitProcess :: proc "std" (i32)`)
		WriteFile_value := odin_function_import(program, "kernel32.dll",
		                                        `WriteFile :: proc "std" (i64, rawptr, i32, ^i32, i64) -> i8`)
		
		main := Function()
		{
			program.entry_point = get_builder_from_context()
			handle            := Call(GetStdHandle_value, STD_OUTPUT_HANDLE_value)
			bytes_written     := Stack_i32(value_from_i32(0))
			bytes_written_ptr := PointerTo(bytes_written)
			message_bytes     := value_global_c_string(program, "Hello, world!")
			message_ptr       := PointerTo(message_bytes)
			Call(WriteFile_value,
			     handle,            // hFile
			     message_ptr,       // lpBuffer
			     value_from_i32(message_bytes.descriptor.array.length - 1), // nNumberOfBytesToWrite
			     bytes_written_ptr, // lpNumberOfBytesWritten
			     value_from_i64(0)) // lpOverlapped
			Call(ExitProcess_value, value_from_i32(0))
		}
		End_Function()
		
		write_executable("build\\hello_world.exe", program)
	})
	
	it("should support short-circuiting &&", proc()
	{
		checker_value := Function()
		{
			number    := Arg_i32()
			condition := Arg_i8()
			
			Return(And(Less(number, value_from_i32(42)),
			           condition))
		}
		End_Function()
		program_end(&test_program)
		
		checker := value_as_function(checker_value, fn_i32_i8_to_i8)
		
		check(checker(52, 1) == 0)
		check(checker(52, 0) == 0)
		check(checker(32, 1) == 1)
		check(checker(32, 0) == 0)
	})
	
	it("should support short-circuiting ||", proc()
	{
		checker_value := Function()
		{
			number    := Arg_i32()
			condition := Arg_i8()
			
			Return(Or(Less(number, value_from_i32(42)),
			          condition))
		}
		End_Function()
		program_end(&test_program)
		
		checker := value_as_function(checker_value, fn_i32_i8_to_i8)
		
		check(checker(52, 1) == 1)
		check(checker(52, 0) == 0)
		check(checker(32, 1) == 1)
		check(checker(32, 0) == 1)
	})
	
	it("should support multi-way case block", proc()
	{
		checker_value := Function()
		{
			number := Arg_i32()
			result := Stack_i32()
			
			Match()
			{
				Case(Eq(number, value_from_i32(42)))
				{
					Assign(result, number)
				}
				End_Case()
				Case(Less(number, value_from_i32(42)))
				{
					Assign(result, value_from_i32(0))
				}
				End_Case()
				CaseAny()
				{
					Assign(result, value_from_i32(100))
				}
				End_CaseAny()
			}
			End_Match()
			
			Return(result)
		}
		End_Function()
		program_end(&test_program)
		
		checker := value_as_function(checker_value, fn_i32_to_i32)
		
		check(checker(42) == 42)
		check(checker(32) == 0)
		check(checker(52) == 100)
	})
	
	it("should support ad-hoc polymorphism / overloading", proc()
	{
		sizeof_i32 := Function()
		{
			_ = Arg_i32()
			Return(value_from_i64(4))
		}
		End_Function()
		
		sizeof_i64 := Function()
		{
			_ = Arg_i64()
			Return(value_from_i64(8))
		}
		End_Function()
		
		sizeof_i32.descriptor.function.next_overload = sizeof_i64
		sizeof := sizeof_i32
		
		checker_value := Function()
		{
			x := Call(sizeof, value_from_i64(0))
			y := Call(sizeof, value_from_i32(0))
			Return(Plus(x, y))
		}
		End_Function()
		program_end(&test_program)
		
		// previous: u32
		// win32.virtual_protect(&test_program.function_buffer.memory[0], len(test_program.function_buffer.memory), win32.PAGE_EXECUTE, &previous)
		
		check(value_as_function(sizeof_i64, fn_i64_to_i64)(42) == 8)
		check(value_as_function(sizeof_i32, fn_i32_to_i64)(42) == 4)
		
		checker := value_as_function(checker_value, fn_void_to_i64)
		check(checker() == 12)
	})
	
	it("should support parametric polymorphism", proc()
	{
		id_i64 := make_identity(&descriptor_i64)
		id_i32 := make_identity(&descriptor_i32)
		addtwo_i64 := make_add_two(&descriptor_i64)
		checker := Function()
		{
			Call(id_i64, value_from_i64(0))
			Call(id_i32, value_from_i32(0))
			Call(addtwo_i64, value_from_i64(0))
		}
		End_Function()
		program_end(&test_program)
	})
	
	it("should say functions with the same signature have the same type)", proc()
	{
		a := Function()
		{
			_ = Arg_i32()
		}
		End_Function()
		
		b := Function()
		{
			_ = Arg_i32()
		}
		End_Function()
		program_end(&test_program)
		
		check(same_value_type(a, b))
	})
	
	it("should say functions with the same signature have the same type)", proc()
	{
		a := Function()
		{
			_ = Arg_i32()
		}
		End_Function()
		
		b := Function()
		{
			_ = Arg_i32()
			_ = Arg_i32()
		}
		End_Function()
		
		c := Function()
		{
			_ = Arg_i64()
		}
		End_Function()
		
		d := Function()
		{
			_ = Arg_i64()
			Return(value_from_i32(0))
		}
		End_Function()
		program_end(&test_program)
		
		check(!same_value_type(a, b))
		check(!same_value_type(a, c))
		check(!same_value_type(a, d))
		check(!same_value_type(b, c))
		check(!same_value_type(b, d))
		check(!same_value_type(c, d))
	})
	
	it("should create function that will return 42", proc()
	{
		the_answer := Function()
		{
			Return(value_from_i32(42))
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(the_answer, fn_void_to_i32)()
		check(result == 42)
	})
	
	it("should create function that returns i64 value that was passed", proc()
	{
		id_i64 := Function()
		{
			x := Arg_i64()
			Return(x)
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(id_i64, fn_i64_to_i64)(42)
		check(result == 42)
	})
	
	it("should create function increments i32 value passed to it", proc()
	{
		inc_i32 := Function()
		{
			// TODO add a check that all arguments are defined before stack variables
			x := Arg_i32()
			
			one := Stack_i32(value_from_i32(1))
			two := Stack_i32(value_from_i32(2))
			
			Return(Plus(x, Minus(two, one)))
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(inc_i32, fn_i32_to_i32)(42)
		check(result == 43)
	})
	
	it("should have a function that returns 0 if arg is zero, 1 otherwise", proc()
	{
		is_non_zero_value := Function()
		{
			x := Arg_i32()
			
			If(Eq(x, value_from_i32(0)))
			{
				Return(value_from_i32(0))
			}
			End_If()
			
			Return(value_from_i32(1))
		}
		End_Function()
		program_end(&test_program)
		
		is_non_zero := value_as_function(is_non_zero_value, fn_i32_to_i32)
		result := is_non_zero(0)
		check(result == 0)
		result = is_non_zero(42)
		check(result == 1)
	})
	
	it("should make function that multiplies by 2", proc()
	{
		twice := Function()
		{
			x := Arg_i64()
			to_return := Multiply(x, value_from_i64(2))
			Return(to_return)
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(twice, fn_i64_to_i64)(42)
		check(result == 84)
	})
	
	it("should make function that divides two numbers", proc()
	{
		divide_fn := Function()
		{
			arg0 := Arg_i32()
			arg1 := Arg_i32()
			to_return := Divide(arg0, arg1)
			Return(to_return)
		}
		End_Function()
		program_end(&test_program)
		
		result: i32 = value_as_function(divide_fn, fn_i32_i32_to_i32)(-42, 2)
		check(result == -21)
	})
	
	it("should create a function to call a no argument fn", proc()
	{
		the_answer := Function()
		{
			Return(value_from_i32(42))
		}
		End_Function()
		
		caller := Function()
		{
			fn := Arg(the_answer.descriptor)
			Return(Call(fn))
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(caller, fn__void_to_i32__to_i32)(
			value_as_function(the_answer, fn_void_to_i32),
		)
		check(result == 42)
	})
	
	it("should create a partially applied function", proc()
	{
		id_i64 := Function()
		{
			x := Arg_i64()
			Return(x)
		}
		End_Function()
		
		partial := Function()
		{
			Return(Call(id_i64, value_from_i64(42)))
		}
		End_Function()
		program_end(&test_program)
		
		the_answer := value_as_function(partial, fn_void_to_i64)
		result := the_answer()
		check(result == 42)
	})
	
	it("should return 3rd argument", proc()
	{
		third := Function()
		{
			_ = Arg_i64()
			_ = Arg_i64()
			arg2 := Arg_i64()
			Return(arg2)
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(third, fn_i64_i64_i64_to_i64)(1, 2, 3)
		check(result == 3)
	})
	
	it("should return 6th argument", proc()
	{
		args := Function()
		{
			_ = Arg_i64()
			_ = Arg_i64()
			_ = Arg_i64()
			_ = Arg_i64()
			_ = Arg_i32()
			arg5 := Arg_i64()
			Return(arg5)
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(args, fn_i64_i64_i64_i64_i64_i64_to_i64)(1, 2, 3, 4, 5, 6)
		check(result == 6)
	})
	
	it("should be able to call a function with more than 4 arguments", proc()
	{
		args := Function()
		{
			_ = Arg_i64()
			_ = Arg_i64()
			_ = Arg_i64()
			_ = Arg_i64()
			_ = Arg_i32()
			arg5 := Arg_i64()
			Return(arg5)
		}
		End_Function()
		
		caller := Function()
		{
			Return(Call(args,
			            value_from_i64(10),
			            value_from_i64(20),
			            value_from_i64(30),
			            value_from_i64(40),
			            value_from_i32(50),
			            value_from_i64(60)))
		}
		End_Function()
		program_end(&test_program)
		
		result := value_as_function(caller, fn_void_to_i64)()
		check(result == 60)
	})
	
	it("should parse odin function forward declarations", proc()
	{
		odin_function_descriptor(`proc "c" ()`)
		odin_function_descriptor(`proc "c" (int)`)
	})
	
	it("should be able to call imported function", proc()
	{
		program := &test_program
		GetStdHandle_value := odin_function_import(program,
		                                           "kernel32.dll",
		                                           `GetStdHandle :: proc "std" (i32) -> rawptr`)
		
		checker_value := Function()
		{
			Return(Call(GetStdHandle_value, value_from_i32(win32.STD_INPUT_HANDLE)))
		}
		End_Function()
		program_end(&test_program)
		
		check(value_as_function(checker_value, fn_void_to_i64)() == i64(uintptr(win32.get_std_handle(win32.STD_INPUT_HANDLE))))
	})
	
	it("should be able to call puts() say 'Hello, world!'", proc()
	{
		message: cstring = "Hello, world!"
		
		message_value: Value =
		{
			descriptor = descriptor_pointer_to(&descriptor_i8),
			operand    = imm64(rawptr(message)),
		}
		
		puts_value := odin_function_value(`puts :: proc "c" ( [^]byte )`, fn_opaque(puts))
		
		hello := Function()
		{
			Call(puts_value, &message_value)
		}
		End_Function()
		program_end(&test_program)
		
		value_as_function(hello, fn_void_to_void)()
	})
	
	it("should be able to call puts() say 'Hi!'", proc()
	{
		puts_value := odin_function_value(`puts :: proc "c" ( [^]byte )`, fn_opaque(puts))
		
		message_descriptor: Descriptor =
		{
			type = .Fixed_Size_Array,
			data = {array =
			{
				item   = &descriptor_i8,
				length = 4,
			}},
		}
		
		hi := [?]byte{'H', 'i', '!', 0}
		hi_i32 := transmute(i32)hi
		hello := Function()
		{
			message_value := Stack(&message_descriptor, value_from_i32(hi_i32))
			Call(puts_value, PointerTo(message_value))
		}
		End_Function()
		program_end(&test_program)
		
		value_as_function(hello, fn_void_to_void)()
	})
	
	it("should calculate Fibonacci numbers", proc()
	{
		fib := Function()
		{
			n := Arg_i64()
			If(Eq(n, value_from_i64(0)))
			{
				Return(value_from_i64(0))
			}
			End_If()
			If(Eq(n, value_from_i64(1)))
			{
				Return(value_from_i64(1))
			}
			End_If()
			
			minus_one := Minus(n, value_from_i64(1))
			minus_two := Minus(n, value_from_i64(2))
			
			f_minus_one := Call(fib, minus_one)
			f_minus_two := Call(fib, minus_two)
			
			Return(Plus(f_minus_one, f_minus_two))
		}
		End_Function()
		program_end(&test_program)
		
		f := value_as_function(fib, fn_i64_to_i64)
		check(f(0) == 0)
		check(f(1) == 1)
		check(f(2) == 1)
		check(f(3) == 2)
		check(f(4) == 3)
		check(f(5) == 5)
		check(f(6) == 8)
	})
}

puts :: proc "c" (str: [^]byte)
{
	context = runtime.default_context()
	
	fmt.printf("%v\n", cstring(str))
}