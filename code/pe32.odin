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

write_executable :: proc()
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
	
	IMPORT_DIRECTORY_INDEX :: 1
	IAT_DIRECTORY_INDEX    :: 12
	
	optional_header := buffer_allocate(&exe_buffer, IMAGE_OPTIONAL_HEADER64)
	optional_header^ =
	{
		Magic                       = IMAGE_NT_OPTIONAL_HDR64_MAGIC,
		SizeOfCode                  = 0x200,  // FIXME calculate based on the amount of machine code
		SizeOfInitializedData       = 0x400,  // FIXME calculate based on the amount of global data
		SizeOfUninitializedData     = 0,      // FIXME figure out difference between initialized and uninitialized
		AddressOfEntryPoint         = 0x1000, // FIXME resolve to the entry point in the machine code
		BaseOfCode                  = 0x1000, // FIXME resolve to the right section containing code
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
		DataDirectory               =
		{
			{}, // Export
			{}, // Import
			{}, // Resource
			{}, // Exception
			
			{}, // Security
			{}, // Relocation
			{}, // Debug
			{}, // Architecture
			
			{}, // Global PTR
			{}, // TLS
			{}, // Load Config
			{}, // Bound Import
			
			{}, // IAT (Import Address Table)
			{}, // Delay Import
			{}, // CLR
			{}, // Reserved
		},
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
	
	// .rdata section
	rdata_section_header := buffer_allocate(&exe_buffer, IMAGE_SECTION_HEADER)
	rdata_section_header^ =
	{
		Name             = short_name(".rdata"),
		Misc             = {VirtualSize = 0x14c}, // FIXME size of machine code in bytes
		VirtualAddress   = 0x2000,                // FIXME calculate this
		SizeOfRawData    = 0x200,                 // FIXME calculate this
		PointerToRawData = 0,
		Characteristics  = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ,
	}
	
	// NULL header telling that the list is done
	_ = buffer_allocate(&exe_buffer, IMAGE_SECTION_HEADER)
	
	optional_header.SizeOfHeaders = u32(align(i32(exe_buffer.occupied), i32(optional_header.FileAlignment)))
	
	sections := [?]^IMAGE_SECTION_HEADER \
	{
		text_section_header,
		rdata_section_header,
	}
	section_offset := optional_header.SizeOfHeaders
	for section in sections
	{
		section.PointerToRawData = section_offset
		section_offset += section.SizeOfRawData
	}
	
	// .text segment
	exe_buffer.occupied = int(text_section_header.PointerToRawData)
	
	buffer_append(&exe_buffer, [?]byte \
	{
		0x48, 0x83, 0xec, 0x28,             // sub rsp 0x28
		0xb9, 0x2a, 0x00, 0x00, 0x00,       // mov ecx 0x2a
		0xff, 0x15, 0xf1, 0x0f, 0x00, 0x00, // call ExitProcess
		0xcc,                               // int 3
	})
	
	// .rdata segment
	
	functions := [?]string{"ExitProcess"}
	
	Import :: struct
	{
		library_name: string,
		functions:    []string,
		// FIXME add patch locations
	}
	
	kernel32: Import =
	{
		library_name = "kernel32.dll",
		functions    = functions[:],
	}
	
	file_offset_to_rva :: proc(buffer: ^Buffer, section_header: ^IMAGE_SECTION_HEADER) -> u32
	{
		return u32(buffer.occupied) - section_header.PointerToRawData + section_header.VirtualAddress
	}
	
	exe_buffer.occupied = int(rdata_section_header.PointerToRawData)
	
	// IAT
	iat_rva := file_offset_to_rva(&exe_buffer, rdata_section_header)
	ExitProcess_IAT_entry := buffer_allocate(&exe_buffer, i64)
	_ = buffer_allocate(&exe_buffer, i64)
	optional_header.DataDirectory[IAT_DIRECTORY_INDEX] =
	{
		VirtualAddress = iat_rva,
		Size           = u32(exe_buffer.occupied) - rdata_section_header.PointerToRawData,
	}
	
	// Names
	kernel32_name_rva := file_offset_to_rva(&exe_buffer, rdata_section_header)
	{
		library_name := "KERNEL32.dll"
		aligned_name_size := align(i32(len(library_name) + 1), 2)
		copy(buffer_allocate_size(&exe_buffer, int(aligned_name_size)), library_name)
	}
	
	ExitProcess_name_rva := file_offset_to_rva(&exe_buffer, rdata_section_header)
	ExitProcess_IAT_entry^ = i64(ExitProcess_name_rva)
	{
		buffer_append(&exe_buffer, u16(0)) // Ordinal Hint, value not required
		function_name := "ExitProcess"
		
		aligned_function_name_size := align(i32(len(function_name) + 1), 2)
		copy(buffer_allocate_size(&exe_buffer, int(aligned_function_name_size)), function_name)
	}
	
	// INT
	int_rva := file_offset_to_rva(&exe_buffer, rdata_section_header)
	ExitProcess_INT_entry := buffer_allocate(&exe_buffer, i64)
	ExitProcess_INT_entry^ = i64(ExitProcess_name_rva)
	_ = buffer_allocate(&exe_buffer, i64)
	
	// Import Directory
	import_rva := file_offset_to_rva(&exe_buffer, rdata_section_header)
	image_import_descriptor := buffer_allocate(&exe_buffer, IMAGE_IMPORT_DESCRIPTOR)
	image_import_descriptor^ =
	{
		OriginalFirstThunk = int_rva,
		Name               = kernel32_name_rva,
		FirstThunk         = iat_rva,
	}
	
	_ = buffer_allocate(&exe_buffer, IMAGE_IMPORT_DESCRIPTOR) // Null terminator
	
	optional_header.DataDirectory[IMPORT_DIRECTORY_INDEX] =
	{
		VirtualAddress = import_rva,
		Size           = file_offset_to_rva(&exe_buffer, rdata_section_header) - import_rva,
	}
	
	exe_buffer.occupied = int(rdata_section_header.PointerToRawData + rdata_section_header.SizeOfRawData)
	
	////////
	
	file := win32.create_file_a("build\\test.exe",           // name of the write
	                            win32.FILE_GENERIC_WRITE,    // open for writing
	                            0,                           // do not share
	                            nil,                         // default security
	                            win32.CREATE_ALWAYS,         // create new file only
	                            win32.FILE_ATTRIBUTE_NORMAL, // normal file
	                            nil)                         // no attr.template
	
	assert(file != win32.INVALID_HANDLE)
	
	bytes_written: i32
	win32.write_file(file,                     // open file handle
	                 &exe_buffer.memory[0],    // start of data to write
	                 i32(exe_buffer.occupied), // number of bytes to write
	                 &bytes_written,           // number of bytes that were written
	                 nil)
}