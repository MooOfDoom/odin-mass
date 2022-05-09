package main

DEBUG_PRINT :: false

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/win32"

report_error :: proc(error: string) -> i32
{
	fmt.printf("Error: %v\n", error)
	return -1
}

Mass_Cli_Mode :: enum
{
	Compile,
	Run,
}

mass_cli_print_usage :: proc() -> i32
{
	fmt.println("Mass Compiler")
	fmt.println("Usage:")
	fmt.println("  mass [--run] source_code.mass")
	return -1
}

wmain :: proc(args: []string) -> i32
{
	if len(args) < 2
	{
		return mass_cli_print_usage()
	}
	
	mode: Mass_Cli_Mode = .Compile
	file_path: string
	for arg in args[1:]
	{
		if arg == "--run"
		{
			mode = .Run
		}
		else
		{
			if file_path != ""
			{
				return mass_cli_print_usage()
			}
			else
			{
				file_path = arg
			}
		}
	}
	
	temp_buffer := make_buffer(1024 * 1024, PAGE_READWRITE)
	context.allocator = buffer_allocator(&temp_buffer)
	
	fn_context: Function_Context
	context.user_ptr = &fn_context
	
	program := program_init(&Program{})
	program_import_file(program, file_path)
	
	program.entry_point = scope_lookup_force(program.global_scope, "main")
	
	switch mode
	{
		case .Compile:
		{
			// TODO generate correct file name
			write_executable("build\\test_cli.exe", program)
		}
		case .Run:
		{
			program_end(program)
			value_as_function(program.entry_point, fn_void_to_void)()
		}
	}
	
	return 0
}

main :: proc()
{
	result := wmain(os.args)
	win32.exit_process(u32(result))
}