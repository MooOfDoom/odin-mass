package main

import "core:fmt"
import "core:sys/win32"
import "core:time"

PE32_FILE_ALIGNMENT    :: 0x200
PE32_SECTION_ALIGNMENT :: 0x1000

PE32_MIN_WINDOWS_VERSION_VISTA :: 6

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

Encoded_Rdata_Section :: struct
{
	buffer:                Buffer,
	iat_rva:               u32,
	iat_size:              u32,
	import_directory_rva:  u32,
	import_directory_size: u32,
}

encode_rdata_section :: proc(program: ^Program, header: ^IMAGE_SECTION_HEADER) -> Encoded_Rdata_Section
{
	get_rva :: proc(buffer: ^Buffer, header: ^IMAGE_SECTION_HEADER) -> u32
	{
		return u32(buffer.occupied) + header.VirtualAddress
	}
	
	program.data_base_rva = i64(header.VirtualAddress)
	
	expected_encoded_size: int
	for lib in &program.import_libraries
	{
		// Aligned to 2 bytes c string of library name
		expected_encoded_size += align(len(lib.name) + 1, 2)
		for sym in &lib.symbols
		{
			{
				// Ordinal Hint, value not required
				expected_encoded_size += size_of(u16)
				// Aligned to 2 bytes c string of symbol name
				expected_encoded_size += align(len(sym.name) + 1, 2)
			}
			{
				// IAT placeholder for symbol pointer
				expected_encoded_size += size_of(u64)
			}
			{
				// Image Thunk
				expected_encoded_size += size_of(u64)
			}
		}
		// IAT zero termination
		expected_encoded_size += size_of(u64)
		// Image Thunk zero termination
		expected_encoded_size += size_of(u64)
		{
			// Import Directory
			expected_encoded_size += size_of(IMAGE_IMPORT_DESCRIPTOR)
		}
	}
	// Import Directory zero termination
	expected_encoded_size += size_of(IMAGE_IMPORT_DESCRIPTOR)
	
	global_data_size := align(program.data_buffer.occupied, 16)
	expected_encoded_size += global_data_size
	
	result: Encoded_Rdata_Section =
	{
		buffer = make_buffer(expected_encoded_size, win32.PAGE_READWRITE),
	}
	
	buffer := &result.buffer
	
	global_data := buffer_allocate_size(buffer, global_data_size)
	copy(global_data, program.data_buffer.memory[:program.data_buffer.occupied])
	
	// Function Names
	for lib in &program.import_libraries
	{
		for sym in &lib.symbols
		{
			sym.name_rva = get_rva(buffer, header)
			buffer_append(buffer, u16(0)) // Ordinal Hint, value not required
			
			aligned_function_name_size := align(len(sym.name) + 1, 2)
			copy(buffer_allocate_size(buffer, aligned_function_name_size), sym.name)
		}
	}
	
	// IAT
	result.iat_rva = get_rva(buffer, header)
	for lib in &program.import_libraries
	{
		lib.iat_rva = get_rva(buffer, header)
		for sym in &lib.symbols
		{
			sym.offset_in_data = get_rva(buffer, header) - header.VirtualAddress
			buffer_append(buffer, u64(sym.name_rva))
		}
		// End of IAT list
		buffer_append(buffer, u64(0))
	}
	result.iat_size = get_rva(buffer, header) - result.iat_rva
	
	// Image thunks
	for lib in &program.import_libraries
	{
		lib.image_thunk_rva = get_rva(buffer, header)
		for sym in &lib.symbols
		{
			buffer_append(buffer, u64(sym.name_rva))
		}
		// End of image thunk list
		buffer_append(buffer, u64(0))
	}
	
	// Library Names
	for lib in &program.import_libraries
	{
		lib.name_rva = get_rva(buffer, header)
		{
			aligned_name_size := align(len(lib.name) + 1, 2)
			copy(buffer_allocate_size(buffer, aligned_name_size), lib.name)
		}
	}
	
	// Import Directory
	result.import_directory_rva = get_rva(buffer, header)
	for lib in &program.import_libraries
	{
		image_import_descriptor := buffer_allocate(buffer, IMAGE_IMPORT_DESCRIPTOR)
		image_import_descriptor^ =
		{
			OriginalFirstThunk = lib.image_thunk_rva,
			Name               = lib.name_rva,
			FirstThunk         = lib.iat_rva,
		}
	}
	
	// End of IMAGE_IMPORT_DESCRIPTOR list
	_ = buffer_allocate(buffer, IMAGE_IMPORT_DESCRIPTOR)
	
	assert(buffer.occupied == expected_encoded_size, "Size of encoded rdata not what was expected")
	
	result.import_directory_size = get_rva(buffer, header) - result.import_directory_rva
	
	header.Misc.VirtualSize = u32(buffer.occupied)
	header.SizeOfRawData = align(u32(buffer.occupied), PE32_FILE_ALIGNMENT)
	
	return result
}

Encoded_Text_Section :: struct
{
	buffer:          Buffer,
	entry_point_rva: u32,
}

encode_text_section :: proc(program: ^Program, header: ^IMAGE_SECTION_HEADER) -> Encoded_Text_Section
{
	get_rva :: proc(buffer: ^Buffer, header: ^IMAGE_SECTION_HEADER) -> u32
	{
		return u32(buffer.occupied) + header.VirtualAddress
	}
	
	max_code_size := estimate_max_code_size_in_bytes(program)
	max_code_size = align(max_code_size, PE32_FILE_ALIGNMENT)
	
	result: Encoded_Text_Section =
	{
		buffer = make_buffer(max_code_size, win32.PAGE_READWRITE),
	}
	
	buffer := &result.buffer
	
	program.code_base_rva = i64(header.VirtualAddress)
	
	for function in &program.functions
	{
		if &function == program.entry_point
		{
			result.entry_point_rva = get_rva(buffer, header)
		}
		fn_encode(buffer, &function)
	}
	
	assert(fits_into_u32(buffer.occupied), "Text section too large")
	header.Misc.VirtualSize = u32(buffer.occupied)
	header.SizeOfRawData = align(u32(buffer.occupied), PE32_FILE_ALIGNMENT)
	
	return result
}

write_executable :: proc(file_path: cstring, program: ^Program)
{
	short_name :: proc(name: string) -> [IMAGE_SIZEOF_SHORT_NAME]byte
	{
		result: [IMAGE_SIZEOF_SHORT_NAME]byte
		copy(result[:], name)
		return result
	}
	
	// Sections
	sections := [?]IMAGE_SECTION_HEADER \
	{
		{
			Name             = short_name(".rdata"),
			Characteristics  = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ,
		},
		{
			Name             = short_name(".text"),
			Characteristics  = IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ | IMAGE_SCN_MEM_EXECUTE,
		},
		{},
	}
	
	file_size_of_headers: u32 = (size_of(IMAGE_DOS_HEADER)        +
	                             size_of(i32)                     + // IMAGE_NT_SIGNATURE
	                             size_of(IMAGE_FILE_HEADER)       +
	                             size_of(IMAGE_OPTIONAL_HEADER64) +
	                             size_of(sections))
	
	file_size_of_headers = align(file_size_of_headers, PE32_FILE_ALIGNMENT)
	virtual_size_of_headers := align(file_size_of_headers, PE32_SECTION_ALIGNMENT)
	
	// Prepare .rdata section
	rdata_section_header := &sections[0]
	rdata_section_header.PointerToRawData = file_size_of_headers
	rdata_section_header.VirtualAddress   = virtual_size_of_headers
	encoded_rdata_section := encode_rdata_section(program, rdata_section_header)
	rdata_section_buffer  := encoded_rdata_section.buffer
	
	// Prepare .text section
	text_section_header  := &sections[1]
	text_section_header.PointerToRawData =
		rdata_section_header.PointerToRawData + rdata_section_header.SizeOfRawData
	text_section_header.VirtualAddress   =
		rdata_section_header.VirtualAddress + align(rdata_section_header.SizeOfRawData, PE32_SECTION_ALIGNMENT)
	encoded_text_section := encode_text_section(program, text_section_header)
	text_section_buffer  := encoded_text_section.buffer
	
	// Calculate total size of image in memory once loaded
	virtual_size_of_image :=
		text_section_header.VirtualAddress + align(text_section_header.SizeOfRawData, PE32_SECTION_ALIGNMENT)
	
	exe_buffer := make_buffer(int(file_size_of_headers               +
	                              rdata_section_header.SizeOfRawData +
	                              text_section_header.SizeOfRawData),
	                          win32.PAGE_READWRITE)
	
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
	
	optional_header := buffer_allocate(&exe_buffer, IMAGE_OPTIONAL_HEADER64)
	optional_header^ =
	{
		Magic                       = IMAGE_NT_OPTIONAL_HDR64_MAGIC,
		SizeOfCode                  = text_section_header.SizeOfRawData,
		SizeOfInitializedData       = rdata_section_header.SizeOfRawData,
		AddressOfEntryPoint         = encoded_text_section.entry_point_rva,
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
		DataDirectory               =
		{
			IAT_DIRECTORY_INDEX =
			{
				VirtualAddress = encoded_rdata_section.iat_rva,
				Size           = encoded_rdata_section.iat_size,
			},
			IMPORT_DIRECTORY_INDEX =
			{
				VirtualAddress = encoded_rdata_section.import_directory_rva,
				Size           = encoded_rdata_section.import_directory_size,
			},
		},
	}
	
	// Write out sections
	buffer_append(&exe_buffer, sections)
	
	file_offset_to_rva :: proc(buffer: ^Buffer, section_header: ^IMAGE_SECTION_HEADER) -> u32
	{
		return u32(buffer.occupied) - section_header.PointerToRawData + section_header.VirtualAddress
	}
	
	// .rdata segment
	exe_buffer.occupied = int(rdata_section_header.PointerToRawData)
	copy(buffer_allocate_size(&exe_buffer, rdata_section_buffer.occupied), rdata_section_buffer.memory[:rdata_section_buffer.occupied])
	exe_buffer.occupied = int(rdata_section_header.PointerToRawData + rdata_section_header.SizeOfRawData)
	
	// .text segment
	exe_buffer.occupied = int(text_section_header.PointerToRawData)
	copy(buffer_allocate_size(&exe_buffer, text_section_buffer.occupied), text_section_buffer.memory[:text_section_buffer.occupied])
	exe_buffer.occupied = int(text_section_header.PointerToRawData + text_section_header.SizeOfRawData)
	
	////////
	
	file := win32.create_file_a(file_path        ,           // name of the write
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
	
	win32.close_handle(file)
	
	free_buffer(&rdata_section_buffer)
	free_buffer(&text_section_buffer)
	free_buffer(&exe_buffer)
}