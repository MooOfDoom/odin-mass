package main

import "core:fmt"
import "core:sys/win32"
import "core:time"

PE32_FILE_ALIGNMENT    :: 0x200
PE32_SECTION_ALIGNMENT :: 0x1000

PE32_MIN_WINDOWS_VERSION_VISTA :: 6

@(private="file")
short_name :: proc(name: string) -> [IMAGE_SIZEOF_SHORT_NAME]byte
{
	result: [IMAGE_SIZEOF_SHORT_NAME]byte
	copy(result[:], name)
	return result
}

write_executable :: proc(program: ^Program)
{
	max_code_size := estimate_max_code_size_in_bytes(program)
	max_code_size = align(max_code_size, PE32_FILE_ALIGNMENT)
	
	assert(fits_into_i32(max_code_size))
	max_code_size_u32 := u32(max_code_size)
	
	// Sections
	sections := [?]IMAGE_SECTION_HEADER \
	{
		{
			Name             = short_name(".rdata"),
			Misc             = {VirtualSize = 0x64}, // FIXME size of data in bytes
			VirtualAddress   = 0,
			SizeOfRawData    = 0x200,                // FIXME calculate this
			PointerToRawData = 0,
			Characteristics  = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ,
		},
		{
			Name             = short_name(".text"),
			Misc             = {VirtualSize = 0x10}, // FIXME size of machine code in bytes
			VirtualAddress   = 0,
			SizeOfRawData    = max_code_size_u32,
			PointerToRawData = 0,
			Characteristics  = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE,
		},
		{},
	}
	
	rdata_section_header := &sections[0]
	text_section_header  := &sections[1]
	
	file_size_of_headers: u32 = (size_of(IMAGE_DOS_HEADER)        +
	                             size_of(u32)                     + // IMAGE_NT_SIGNATURE
	                             size_of(IMAGE_FILE_HEADER)       +
	                             size_of(IMAGE_OPTIONAL_HEADER64) +
	                             size_of(sections))
	
	file_size_of_headers = align(file_size_of_headers, PE32_FILE_ALIGNMENT)
	
	virtual_size_of_image: u32
	
	{
		// Update offsets for sections
		section_offset         := file_size_of_headers
		virtual_section_offset := align(file_size_of_headers, PE32_SECTION_ALIGNMENT)
		non_null_sections := sections[:len(sections) - 1]
		for section in &non_null_sections
		{
			section.PointerToRawData = section_offset
			section_offset += section.SizeOfRawData
			
			section.VirtualAddress = virtual_section_offset
			virtual_section_offset += align(section.SizeOfRawData, PE32_SECTION_ALIGNMENT)
		}
		virtual_size_of_image = virtual_section_offset
	}
	
	// TODO this should be dynamically sized or correctly estimated
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
		NumberOfSections     = u16(len(sections) - 1),
		TimeDateStamp        = u32(time.time_to_unix(time.now())),
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
		SizeOfCode                  = text_section_header.SizeOfRawData,
		SizeOfInitializedData       = rdata_section_header.SizeOfRawData,
		AddressOfEntryPoint         = 0,
		BaseOfCode                  = text_section_header.VirtualAddress,
		ImageBase                   = 0x0000000140000000, // Does not matter as we are using dynamic base
		SectionAlignment            = PE32_SECTION_ALIGNMENT,
		FileAlignment               = PE32_FILE_ALIGNMENT,
		MajorOperatingSystemVersion = PE32_MIN_WINDOWS_VERSION_VISTA,
		MinorOperatingSystemVersion = 0,
		MajorSubsystemVersion       = PE32_MIN_WINDOWS_VERSION_VISTA,
		MinorSubsystemVersion       = 0,
		SizeOfImage                 = virtual_size_of_image,
		SizeOfHeaders               = file_size_of_headers,
		Subsystem                   = IMAGE_SUBSYSTEM_WINDOWS_CUI, // TODO allow user to specify this
		DllCharacteristics          = (IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA |
		                               IMAGE_DLLCHARACTERISTICS_NX_COMPAT       |
		                               IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE    |
		                               IMAGE_DLLCHARACTERISTICS_TERMINAL_SERVER_AWARE),
		SizeOfStackReserve          = 0x100000,
		SizeOfStackCommit           = 0x1000,
		SizeOfHeapReserve           = 0x100000,
		SizeOfHeapCommit            = 0x1000,
		NumberOfRvaAndSizes         = IMAGE_NUMBEROF_DIRECTORY_ENTRIES, // TODO think about shrinking this if possible
		DataDirectory               = {},
	}
	
	// Write out sections
	buffer_append(&exe_buffer, sections)
	
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
			buffer_append(&exe_buffer, u16(0)) // Ordinal Hint, value not required
			
			aligned_function_name_size := align(len(sym.name) + 1, 2)
			copy(buffer_allocate_size(&exe_buffer, aligned_function_name_size), sym.name)
		}
	}
	
	// IAT
	
	optional_header.DataDirectory[IAT_DIRECTORY_INDEX].VirtualAddress =
		file_offset_to_rva(&exe_buffer, rdata_section_header)
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
	optional_header.DataDirectory[IAT_DIRECTORY_INDEX].Size =
		file_offset_to_rva(&exe_buffer, rdata_section_header) - optional_header.DataDirectory[IAT_DIRECTORY_INDEX].VirtualAddress
	
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
			aligned_name_size := align(len(lib.dll.name) + 1, 2)
			copy(buffer_allocate_size(&exe_buffer, aligned_name_size), lib.dll.name)
		}
	}
	
	// Import Directory
	optional_header.DataDirectory[IMPORT_DIRECTORY_INDEX].VirtualAddress =
		file_offset_to_rva(&exe_buffer, rdata_section_header)
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
	
	optional_header.DataDirectory[IMPORT_DIRECTORY_INDEX].Size =
		file_offset_to_rva(&exe_buffer, rdata_section_header) - optional_header.DataDirectory[IMPORT_DIRECTORY_INDEX].VirtualAddress
	
	actual_size_of_rdata := u32(exe_buffer.occupied) - rdata_section_header.PointerToRawData
	fmt.printf("%x\n", actual_size_of_rdata)
	assert(actual_size_of_rdata == rdata_section_header.Misc.VirtualSize, "rdata declared size does not match actual size")
	
	// .text segment
	exe_buffer.occupied = int(text_section_header.PointerToRawData)
	
	program.code_base_file_offset = exe_buffer.occupied
	program.code_base_rva         = i32(text_section_header.VirtualAddress)
	
	for function in &program.functions
	{
		if &function == program.entry_point
		{
			optional_header.AddressOfEntryPoint = file_offset_to_rva(&exe_buffer, text_section_header)
		}
		fn_encode(&exe_buffer, &function)
	}
	
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