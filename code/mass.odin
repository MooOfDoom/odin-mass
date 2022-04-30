package main

DEBUG_PRINT :: true

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/win32"

report_error :: proc(error: string) -> i32
{
	fmt.printf("Error: %v\n", error)
	return -1
}

wmain :: proc(args: []string) -> i32
{
	if len(args) != 2
	{
		fmt.println("Mass Compiler")
		fmt.println("Usage:")
		fmt.println(" mass source_code.mass")
		return 0
	}
	
	file_path := args[1]
	file_handle := win32.create_file_w(win32.utf8_to_wstring(file_path),
	                                   win32.FILE_GENERIC_READ,
	                                   win32.FILE_SHARE_READ,
	                                   nil,
	                                   win32.OPEN_EXISTING,
	                                   win32.FILE_ATTRIBUTE_NORMAL,
	                                   nil)
	if file_handle == nil do return report_error("Could not open specified file")
	
	buffer_size: i64
	win32.get_file_size_ex(file_handle, &buffer_size)
	buffer := make_buffer(int(buffer_size), PAGE_READWRITE)
	bytes_read: i32
	is_success := win32.read_file(file_handle, &buffer.memory[0], u32(buffer_size), &bytes_read, nil)
	win32.close_handle(file_handle)
	file_handle = nil
	if !is_success do return report_error("Could not read specified file")
	buffer.occupied = int(bytes_read)
	
	source := string(buffer.memory)
	
	temp_buffer := make_buffer(1024 * 1024, PAGE_READWRITE)
	context.allocator = buffer_allocator(&temp_buffer)
	
	fn_context: Function_Context
	context.user_ptr = &fn_context
	
	program := &Program \
	{
		data_buffer      = make_buffer(128 * 1024, PAGE_READWRITE),
		import_libraries = make([dynamic]Import_Library, 0, 16),
		functions        = make([dynamic]Function_Builder, 0, 16),
		global_scope     = scope_make(),
	}
		
	scope_define_value(program.global_scope, "s32", &type_s32_value)
	scope_define_value(program.global_scope, "s64", &type_s64_value)
	
	result := tokenize(file_path, source)
	if result.type != .Success
	{
		for error in &result.errors
		{
			print_message_with_location(error.message, &error.location)
		}
		return -1
	}
	
	token_match_module(result.root, program)
	
	program.entry_point = scope_lookup_force(program.global_scope, "main")
	
	write_executable("build\\test_cli.exe", program)
	
	return 0
}

main :: proc()
{
	result := wmain(os.args)
	win32.exit_process(u32(result))
}