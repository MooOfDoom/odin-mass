package main

import "core:fmt"
import "core:runtime"
import "core:sys/win32"

function_buffer: Buffer

make_identity :: proc(type: ^Descriptor) -> ^Value
{
	id, f := Function()
	{
		x := Arg(type)
		Return(x)
	}
	End_Function()
	
	return id
}

make_add_two :: proc(type: ^Descriptor) -> ^Value
{
	addtwo, f := Function()
	{
		x := Arg(type)
		Return(Plus(x, value_from_i64(2)))
	}
	End_Function()
	
	return addtwo
}

function_spec :: proc()
{
	spec("function")
	
	temp_buffer := make_buffer(1024 * 1024, win32.PAGE_READWRITE)
	context.allocator = buffer_allocator(&temp_buffer)
	
	fn_context: Function_Context
	context.user_ptr = &fn_context
	// a: [dynamic]int
	
	// append(&a, 1, 2, 3, 4, 5)
	// fmt.println(len(a))
	// x := dynamic_pop(&a)
	// fmt.println(x)
	// fmt.println(len(a))
	// append(&a, 6, 7,8, 9)
	// fmt.println(a)
	
	before_each(proc()
	{
		function_buffer = make_buffer(128 * 1024, win32.PAGE_EXECUTE_READWRITE)
		free_all()
	})
	
	after_each(proc()
	{
		free_buffer(&function_buffer)
	})
	
	it("should support short-circuiting &&", proc()
	{
		checker_value, f := Function()
		{
			number    := Arg_i32()
			condition := Arg_i8()
			
			Return(And(Less(number, value_from_i32(42)),
			           condition))
		}
		End_Function()
		
		checker := value_as_function(checker_value, fn_i32_i8_to_i8)
		
		check(checker(52, 1) == 0)
		check(checker(52, 0) == 0)
		check(checker(32, 1) == 1)
		check(checker(32, 0) == 0)
	})
	
	it("should support short-circuiting ||", proc()
	{
		checker_value, f := Function()
		{
			number    := Arg_i32()
			condition := Arg_i8()
			
			Return(Or(Less(number, value_from_i32(42)),
			          condition))
		}
		End_Function()
		
		checker := value_as_function(checker_value, fn_i32_i8_to_i8)
		
		check(checker(52, 1) == 1)
		check(checker(52, 0) == 0)
		check(checker(32, 1) == 1)
		check(checker(32, 0) == 1)
	})
	
	it("should support multi-way case block", proc()
	{
		checker_value, f := Function()
		{
			number := Arg_i32()
			result := Stack_i32()
			end_label := make_label()
			
			If(Eq(number, value_from_i32(42)))
			{
				Assign(result, number)
				Goto(end_label)
			}
			End_If()
			
			If(Less(number, value_from_i32(42)))
			{
				Assign(result, value_from_i32(0))
				Goto(end_label)
			}
			End_If()
			
			Assign(result, value_from_i32(100))
			
			Label_(end_label)
			Return(result)
			
			// m := Match()
			// {
			// 	c := Case(Eq(number, value_from_i32(42)))
			// 	{
			// 		Return(number)
			// 	}
			// 	End_Case(c)
			// 	c = Case(Less(number, value_from_i32(42))
			// 	{
			// 		Return(value_from_i32(0))
			// 	}
			// 	End_Case(c)
			// 	c = CaseAny()
			// 	{
			// 		Return(value_from_i32(100))
			// 	}
			// 	End_Case(c)
			// }
			// End_Match(m)
		}
		End_Function()
		
		checker := value_as_function(checker_value, fn_i32_to_i32)
		
		check(checker(42) == 42)
		check(checker(32) == 0)
		check(checker(52) == 100)
	})
	
	it("should support ad-hoc polymorphism / overloading", proc()
	{
		sizeof_i32, f := Function()
		{
			_ = Arg_i32()
			Return(value_from_i64(4))
		}
		End_Function()
		
		sizeof_i64, g := Function()
		{
			_ = Arg_i64()
			Return(value_from_i64(8))
		}
		End_Function()
		
		sizeof_i32.descriptor.function.next_overload = sizeof_i64
		sizeof := sizeof_i32
		
		checker_value, h := Function()
		{
			x := Call(sizeof, value_from_i64(0))
			y := Call(sizeof, value_from_i32(0))
			Return(Plus(x, y))
		}
		End_Function()
		
		previous: u32
		win32.virtual_protect(&function_buffer.memory[0], len(function_buffer.memory), win32.PAGE_EXECUTE, &previous)
		
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
		checker, f := Function()
		{
			Call(id_i64, value_from_i64(0))
			Call(id_i32, value_from_i32(0))
			Call(addtwo_i64, value_from_i64(0))
		}
		End_Function()
	})
	
	it("should say functions with the same signature have the same type)", proc()
	{
		a, f := Function()
		{
			_ = Arg_i32()
		}
		End_Function()
		
		b, g := Function()
		{
			_ = Arg_i32()
		}
		End_Function()
		
		check(same_value_type(a, b))
	})
	
	it("should say functions with the same signature have the same type)", proc()
	{
		a, f := Function()
		{
			_ = Arg_i32()
		}
		End_Function()
		
		b, g := Function()
		{
			_ = Arg_i32()
			_ = Arg_i32()
		}
		End_Function()
		
		c, h := Function()
		{
			_ = Arg_i64()
		}
		End_Function()
		
		d, i := Function()
		{
			_ = Arg_i64()
			Return(value_from_i32(0))
		}
		End_Function()
		
		check(!same_value_type(a, b))
		check(!same_value_type(a, c))
		check(!same_value_type(a, d))
		check(!same_value_type(b, c))
		check(!same_value_type(b, d))
		check(!same_value_type(c, d))
	})
	
	it("should create function that will return 42", proc()
	{
		the_answer, f := Function()
		{
			Return(value_from_i32(42))
		}
		End_Function()
		
		result := value_as_function(the_answer, fn_void_to_i32)()
		check(result == 42)
	})
	
	it("should create function that returns i64 value that was passed", proc()
	{
		id_i64, f := Function()
		{
			x := Arg_i64()
			Return(x)
		}
		End_Function()
		
		result := value_as_function(id_i64, fn_i64_to_i64)(42)
		check(result == 42)
	})
	
	it("should create function increments i32 value passed to it", proc()
	{
		inc_i32, f := Function()
		{
			// TODO add a check that all arguments are defined before stack variables
			x := Arg_i32()
			
			one := Stack_i32(value_from_i32(1))
			two := Stack_i32(value_from_i32(2))
			
			Return(Plus(x, Minus(two, one)))
		}
		End_Function()
		
		result := value_as_function(inc_i32, fn_i32_to_i32)(42)
		check(result == 43)
	})
	
	it("should have a function that returns 0 if arg is zero, 1 otherwise", proc()
	{
		is_non_zero_value, f := Function()
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
		
		is_non_zero := value_as_function(is_non_zero_value, fn_i32_to_i32)
		result := is_non_zero(0)
		check(result == 0)
		result = is_non_zero(42)
		check(result == 1)
	})
	
	it("should make function that multiplies by 2", proc()
	{
		twice, f := Function()
		{
			x := Arg_i64()
			to_return := Multiply(x, value_from_i64(2))
			Return(to_return)
		}
		End_Function()
		
		result := value_as_function(twice, fn_i64_to_i64)(42)
		check(result == 84)
	})
	
	it("should make function that divides two numbers", proc()
	{
		divide_fn, f := Function()
		{
			arg0 := Arg_i32()
			arg1 := Arg_i32()
			to_return := Divide(arg0, arg1)
			Return(to_return)
		}
		End_Function()
		
		result: i32 = value_as_function(divide_fn, fn_i32_i32_to_i32)(-42, 2)
		check(result == -21)
	})
	
	it("should create a function to call a no argument fn", proc()
	{
		the_answer, f := Function()
		{
			Return(value_from_i32(42))
		}
		End_Function()
		
		caller, g := Function()
		{
			fn := Arg(the_answer.descriptor)
			Return(Call(fn))
		}
		End_Function()
		
		result := value_as_function(caller, fn__void_to_i32__to_i32)(
			value_as_function(the_answer, fn_void_to_i32),
		)
		check(result == 42)
	})
	
	it("should create a partially applied function", proc()
	{
		id_i64, f := Function()
		{
			x := Arg_i64()
			Return(x)
		}
		End_Function()
		
		partial, g := Function()
		{
			Return(Call(id_i64, value_from_i64(42)))
		}
		End_Function()
		
		the_answer := value_as_function(partial, fn_void_to_i64)
		result := the_answer()
		check(result == 42)
	})
	
	it("should return 3rd argument", proc()
	{
		third, f := Function()
		{
			_ = Arg_i64()
			_ = Arg_i64()
			arg2 := Arg_i64()
			Return(arg2)
		}
		End_Function()
		
		result := value_as_function(third, fn_i64_i64_i64_to_i64)(1, 2, 3)
		check(result == 3)
	})
	
	it("should return 6th argument", proc()
	{
		args, f := Function()
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
		
		result := value_as_function(args, fn_i64_i64_i64_i64_i64_i64_to_i64)(1, 2, 3, 4, 5, 6)
		check(result == 6)
	})
	
	it("should be able to call a function with more than 4 arguments", proc()
	{
		args, f := Function()
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
		
		caller, g := Function()
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
		
		result := value_as_function(caller, fn_void_to_i64)()
		check(result == 60)
	})
	
	it("should parse odin function forward declarations", proc()
	{
		odin_function_value(`proc "c" ()`, nil)
		odin_function_value(`proc "c" (int)`, nil)
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
		
		hello, f := Function()
		{
			Call(puts_value, &message_value)
		}
		End_Function()
		
		value_as_function(hello, fn_void_to_void)()
	})
	
	it("should be able to call puts() say 'Hi!'", proc()
	{
		puts_value := odin_function_value(`puts :: proc "c" ( [^]byte )`, fn_opaque(puts))
		
		message_descriptor: Descriptor =
		{
			type = .Fixed_Size_Array,
			array =
			{
				item   = &descriptor_i8,
				length = 4,
			},
		}
		
		hi := [?]byte{'H', 'i', '!', 0}
		hi_i32 := transmute(i32)hi
		hello, f := Function()
		{
			message_value := Stack(&message_descriptor, value_from_i32(hi_i32))
			Call(puts_value, PointerTo(message_value))
		}
		End_Function()
		
		value_as_function(hello, fn_void_to_void)()
	})
	
	it("should calculate Fibonacci numbers", proc()
	{
		fib, g := Function()
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