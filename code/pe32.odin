package main

import "core:fmt"
import "core:sys/win32"

@(private="file")
short_name :: proc(name: string) -> [IMAGE_SIZEOF_SHORT_NAME]byte
{
	result: [IMAGE_SIZEOF_SHORT_NAME]byte
	copy(result[:], name)
	return result
}

write_executable :: proc(program: ^Program)
{
	exe_buffer := make_buffer(1024 * 1024, win32.PAGE_READWRITE)
	
	dos_header := buffer_allocate(&exe_buffer, IMAGE_DOS_HEADER)
	dos_header^ =
	{
		e_magic  = IMAGE_DOS_SIGNATURE,
		e_lfanew = size_of(IMAGE_DOS_HEADER),
	}
	buffer_append(&exe_buffer, i32(IMAGE_NT_SIGNATURE))
	
	buffer_append(&exe_buffer, IMAGE_FILE_HEADER \
	{
		Machine              = IMAGE_FILE_MACHINE_AMD64,
		NumberOfSections     = 2,
		TimeDateStamp        = 0x5ef48e56, // FIXME generate ourselves
		SizeOfOptionalHeader = size_of(IMAGE_OPTIONAL_HEADER64),
		Characteristics      = IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE,
	})
	
	EXPORT_DIRECTORY_INDEX       :: 0
	IMPORT_DIRECTORY_INDEX       :: 1
	RESOURCE_DIRECTORY_INDEX     :: 2
	EXCEPTION_DIRECTORY_INDEX    :: 3
	SECURITY_DIRECTORY_INDEX     :: 4
	RELOCATION_DIRECTORY_INDEX   :: 5
	DEBUG_DIRECTORY_INDEX        :: 6
	ARCHITECTURE_DIRECTORY_INDEX :: 7
	GLOBAL_PTR_DIRECTORY_INDEX   :: 8
	TLS_DIRECTORY_INDEX          :: 9
	LOAD_CONFIG_DIRECTORY_INDEX  :: 10
	BOUND_IMPORT_DIRECTORY_INDEX :: 11
	IAT_DIRECTORY_INDEX          :: 12
	DELAY_IMPORT_DIRECTORY_INDEX :: 13
	CLR_DIRECTORY_INDEX          :: 14
	
	base_of_code: u32 = 0x2000 // FIXME use section alignment
	address_of_entry_relative_to_base_of_code: u32 = 0
	
	optional_header := buffer_allocate(&exe_buffer, IMAGE_OPTIONAL_HEADER64)
	optional_header^ =
	{
		Magic                       = IMAGE_NT_OPTIONAL_HDR64_MAGIC,
		SizeOfCode                  = 0x200,  // FIXME calculate based on the amount of machine code
		SizeOfInitializedData       = 0x200,  // FIXME calculate based on the amount of global data
		SizeOfUninitializedData     = 0,      // FIXME figure out difference between initialized and uninitialized
		AddressOfEntryPoint         = base_of_code + address_of_entry_relative_to_base_of_code,
		BaseOfCode                  = base_of_code, // FIXME resolve to the right section containing code
		ImageBase                   = 0x0000000140000000, // Does not matter as we are using dynamic base
		SectionAlignment            = 0x1000,
		FileAlignment               = 0x200,
		MajorOperatingSystemVersion = 6,      // FIXME figure out if can be not hard coded
		MinorOperatingSystemVersion = 0,
		MajorSubsystemVersion       = 6,      // FIXME figure out if can be not hard coded
		MinorSubsystemVersion       = 0,
		SizeOfImage                 = 0x3000, // FIXME calculate based on the sizes of the sections
		SizeOfHeaders               = 0,
		Subsystem                   = IMAGE_SUBSYSTEM_WINDOWS_CUI, // TODO allow user to specify this
		DllCharacteristics          = (IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA |
		                               IMAGE_DLLCHARACTERISTICS_NX_COMPAT       | // TODO figure out what NX is
		                               IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE    |
		                               IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE),
		SizeOfStackReserve          = 0x100000,
		SizeOfStackCommit           = 0x1000,
		SizeOfHeapReserve           = 0x100000,
		SizeOfHeapCommit            = 0x1000,
		NumberOfRvaAndSizes         = IMAGE_NUMBEROF_DIRECTORY_ENTRIES, // TODO think about shrinking this if possible
		DataDirectory               = {},
	}
	
	// .rdata section
	rdata_section_header := buffer_allocate(&exe_buffer, IMAGE_SECTION_HEADER)
	rdata_section_header^ =
	{
		Name             = short_name(".rdata"),
		Misc             = {VirtualSize = 0x14c}, // FIXME size of machine code in bytes
		VirtualAddress   = 0x1000,                // FIXME calculate this
		SizeOfRawData    = 0x200,                 // FIXME calculate this
		PointerToRawData = 0,
		Characteristics  = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ,
	}
	
	// .text section
	text_section_header := buffer_allocate(&exe_buffer, IMAGE_SECTION_HEADER)
	text_section_header^ =
	{
		Name             = short_name(".text"),
		Misc             = {VirtualSize = 0x10}, // FIXME size of machine code in bytes
		VirtualAddress   = optional_header.BaseOfCode,
		SizeOfRawData    = optional_header.SizeOfCode,
		PointerToRawData = 0,
		Characteristics  = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE,
	}
	
	// NULL header telling that the list is done
	_ = buffer_allocate(&exe_buffer, IMAGE_SECTION_HEADER)
	
	optional_header.SizeOfHeaders = u32(align(i32(exe_buffer.occupied), i32(optional_header.FileAlignment)))
	
	sections := [?]^IMAGE_SECTION_HEADER \
	{
		rdata_section_header,
		text_section_header,
	}
	section_offset := optional_header.SizeOfHeaders
	for section in sections
	{
		section.PointerToRawData = section_offset
		section_offset += section.SizeOfRawData
	}
	assert(rdata_section_header.PointerToRawData == 0x200)
	assert(text_section_header.PointerToRawData == 0x400)
	
	file_offset_to_rva :: proc(buffer: ^Buffer, section_header: ^IMAGE_SECTION_HEADER) -> u32
	{
		return u32(buffer.occupied) - section_header.PointerToRawData + section_header.VirtualAddress
	}
	
	// .rdata segment
	
	exe_buffer.occupied = int(rdata_section_header.PointerToRawData)
	
	// Function Names
	for lib in &program.import_libraries
	{
		for sym in &lib.symbols
		{
			sym.name_rva = file_offset_to_rva(&exe_buffer, rdata_section_header)
			buffer_append(&exe_buffer, u16(0))
			
			aligned_function_name_size := align(i32(len(sym.name) + 1), 2)
			copy(buffer_allocate_size(&exe_buffer, int(aligned_function_name_size)), sym.name)
		}
	}
	
	// IAT
	for lib in &program.import_libraries
	{
		lib.dll.iat_rva = file_offset_to_rva(&exe_buffer, rdata_section_header)
		for sym in &lib.symbols
		{
			sym.iat_rva = file_offset_to_rva(&exe_buffer, rdata_section_header)
			buffer_append(&exe_buffer, u64(sym.name_rva))
		}
		// End of IAT list
		buffer_append(&exe_buffer, u64(0))
	}
	
	optional_header.DataDirectory[IAT_DIRECTORY_INDEX] =
	{
		VirtualAddress = program.import_libraries[0].dll.iat_rva,
		Size           = file_offset_to_rva(&exe_buffer, rdata_section_header) - program.import_libraries[0].dll.iat_rva,
	}
	
	// Image thunks
	for lib in &program.import_libraries
	{
		lib.image_thunk_rva = file_offset_to_rva(&exe_buffer, rdata_section_header)
		for sym in &lib.symbols
		{
			buffer_append(&exe_buffer, u64(sym.name_rva))
		}
		// End of image thunk list
		buffer_append(&exe_buffer, u64(0))
	}
	
	// Library Names
	for lib in &program.import_libraries
	{
		lib.dll.name_rva = file_offset_to_rva(&exe_buffer, rdata_section_header)
		{
			aligned_name_size := align(i32(len(lib.dll.name) + 1), 2)
			copy(buffer_allocate_size(&exe_buffer, int(aligned_name_size)), lib.dll.name)
		}
	}
	
	// Import Directory
	import_directory_rva := file_offset_to_rva(&exe_buffer, rdata_section_header)
	for lib in &program.import_libraries
	{
		image_import_descriptor := buffer_allocate(&exe_buffer, IMAGE_IMPORT_DESCRIPTOR)
		image_import_descriptor^ =
		{
			OriginalFirstThunk = lib.image_thunk_rva,
			Name               = lib.dll.name_rva,
			FirstThunk         = lib.dll.iat_rva,
		}
	}
	
	// End of IMAGE_IMPORT_DESCRIPTOR list
	_ = buffer_allocate(&exe_buffer, IMAGE_IMPORT_DESCRIPTOR)
	
	optional_header.DataDirectory[IMPORT_DIRECTORY_INDEX] =
	{
		VirtualAddress = import_directory_rva,
		Size           = file_offset_to_rva(&exe_buffer, rdata_section_header) - import_directory_rva,
	}
	
	// .text segment
	exe_buffer.occupied = int(text_section_header.PointerToRawData)
	
	program.code_base_file_offset = exe_buffer.occupied
	program.code_base_rva         = i32(text_section_header.VirtualAddress)
	program.entry_point.buffer    = &exe_buffer
	fn_end(program.entry_point)
	program_end(program)
	
	// buffer_append(&exe_buffer, [?]byte \
	// {
	// 	0x48, 0x83, 0xec, 0x28,         // sub rsp, 0x28
	// 	0xb9, 0x2a, 0x00, 0x00, 0x00,   // mov ecx, 0x2a
	// })
	
	// buffer_append_u8(&exe_buffer, 0xff) // call
	// buffer_append_u8(&exe_buffer, 0x15)
	// {
	// 	ExitProcess_rip_relative_address := buffer_allocate(&exe_buffer, i32)
	// 	ExitProcess_call_rva             := file_offset_to_rva(&exe_buffer, text_section_header)
		
	// 	lib_loop: for lib in &program.import_libraries
	// 	{
	// 		if lib.dll.name != "kernel32.dll" do continue
			
	// 		for sym in &lib.symbols
	// 		{
	// 			if sym.name == "ExitProcess"
	// 			{
	// 				ExitProcess_rip_relative_address^ = i32(sym.iat_rva - ExitProcess_call_rva)
	// 				break lib_loop
	// 			}
	// 		}
	// 		assert(false, "ExitProcess was not in the kernel32.dll imports")
	// 	}
	// }
	// buffer_append_u8(&exe_buffer, 0xcc) // int 3
	
	exe_buffer.occupied = int(text_section_header.PointerToRawData + text_section_header.SizeOfRawData)
	
	////////
	
	file := win32.create_file_a("build\\test.exe",           // name of the write
	                            win32.FILE_GENERIC_WRITE,    // open for writing
	                            0,                           // do not share
	                            nil,                         // default security
	                            win32.CREATE_ALWAYS,         // create new file only
	                            win32.FILE_ATTRIBUTE_NORMAL, // normal file
	                            nil)                         // no attr.template
	
	assert(file != win32.INVALID_HANDLE, "Could not open exe file for writing")
	
	bytes_written: i32
	win32.write_file(file,                     // open file handle
	                 &exe_buffer.memory[0],    // start of data to write
	                 i32(exe_buffer.occupied), // number of bytes to write
	                 &bytes_written,           // number of bytes that were written
	                 nil)
}