package main

import "core:sys/win32"

IMAGE_DOS_SIGNATURE    :: 0x5A4D      // MZ
IMAGE_OS2_SIGNATURE    :: 0x454E      // NE
IMAGE_OS2_SIGNATURE_LE :: 0x454C      // LE
IMAGE_VXD_SIGNATURE    :: 0x454C      // LE
IMAGE_NT_SIGNATURE     :: 0x00004550  // PE00

IMAGE_DOS_HEADER :: struct
{
	e_magic:    u16,
	e_cblp:     u16,
	e_cp:       u16,
	e_crlc:     u16,
	e_cparhdr:  u16,
	e_minalloc: u16,
	e_maxalloc: u16,
	e_ss:       u16,
	e_sp:       u16,
	e_csum:     u16,
	e_ip:       u16,
	e_cs:       u16,
	e_lfarlc:   u16,
	e_ovno:     u16,
	e_res:      [4]u16,
	e_oemid:    u16,
	e_oeminfo:  u16,
	e_res2:     [10]u16,
	e_lfanew:   i32,
}

IMAGE_SIZEOF_FILE_HEADER           :: 20

IMAGE_FILE_RELOCS_STRIPPED         :: 0x0001  // Relocation info stripped from file.
IMAGE_FILE_EXECUTABLE_IMAGE        :: 0x0002  // File is executable  (i.e. no unresolved external references).
IMAGE_FILE_LINE_NUMS_STRIPPED      :: 0x0004  // Line nunbers stripped from file.
IMAGE_FILE_LOCAL_SYMS_STRIPPED     :: 0x0008  // Local symbols stripped from file.
IMAGE_FILE_AGGRESIVE_WS_TRIM       :: 0x0010  // Aggressively trim working set
IMAGE_FILE_LARGE_ADDRESS_AWARE     :: 0x0020  // App can handle >2gb addresses
IMAGE_FILE_BYTES_REVERSED_LO       :: 0x0080  // Bytes of machine word are reversed.
IMAGE_FILE_32BIT_MACHINE           :: 0x0100  // 32 bit word machine.
IMAGE_FILE_DEBUG_STRIPPED          :: 0x0200  // Debugging info stripped from file in .DBG file
IMAGE_FILE_REMOVABLE_RUN_FROM_SWAP :: 0x0400  // If Image is on removable media, copy and run from the swap file.
IMAGE_FILE_NET_RUN_FROM_SWAP       :: 0x0800  // If Image is on Net, copy and run from the swap file.
IMAGE_FILE_SYSTEM                  :: 0x1000  // System File.
IMAGE_FILE_DLL                     :: 0x2000  // File is a DLL.
IMAGE_FILE_UP_SYSTEM_ONLY          :: 0x4000  // File should only be run on a UP machine
IMAGE_FILE_BYTES_REVERSED_HI       :: 0x8000  // Bytes of machine word are reversed.

IMAGE_FILE_MACHINE_UNKNOWN         :: 0
IMAGE_FILE_MACHINE_TARGET_HOST     :: 0x0001  // Useful for indicating we want to interact with the host and not a WoW guest.
IMAGE_FILE_MACHINE_I386            :: 0x014c  // Intel 386.
IMAGE_FILE_MACHINE_R3000           :: 0x0162  // MIPS little-endian, 0x160 big-endian
IMAGE_FILE_MACHINE_R4000           :: 0x0166  // MIPS little-endian
IMAGE_FILE_MACHINE_R10000          :: 0x0168  // MIPS little-endian
IMAGE_FILE_MACHINE_WCEMIPSV2       :: 0x0169  // MIPS little-endian WCE v2
IMAGE_FILE_MACHINE_ALPHA           :: 0x0184  // Alpha_AXP
IMAGE_FILE_MACHINE_SH3             :: 0x01a2  // SH3 little-endian
IMAGE_FILE_MACHINE_SH3DSP          :: 0x01a3
IMAGE_FILE_MACHINE_SH3E            :: 0x01a4  // SH3E little-endian
IMAGE_FILE_MACHINE_SH4             :: 0x01a6  // SH4 little-endian
IMAGE_FILE_MACHINE_SH5             :: 0x01a8  // SH5
IMAGE_FILE_MACHINE_ARM             :: 0x01c0  // ARM Little-Endian
IMAGE_FILE_MACHINE_THUMB           :: 0x01c2  // ARM Thumb/Thumb-2 Little-Endian
IMAGE_FILE_MACHINE_ARMNT           :: 0x01c4  // ARM Thumb-2 Little-Endian
IMAGE_FILE_MACHINE_AM33            :: 0x01d3
IMAGE_FILE_MACHINE_POWERPC         :: 0x01F0  // IBM PowerPC Little-Endian
IMAGE_FILE_MACHINE_POWERPCFP       :: 0x01f1
IMAGE_FILE_MACHINE_IA64            :: 0x0200  // Intel 64
IMAGE_FILE_MACHINE_MIPS16          :: 0x0266  // MIPS
IMAGE_FILE_MACHINE_ALPHA64         :: 0x0284  // ALPHA64
IMAGE_FILE_MACHINE_MIPSFPU         :: 0x0366  // MIPS
IMAGE_FILE_MACHINE_MIPSFPU16       :: 0x0466  // MIPS
IMAGE_FILE_MACHINE_AXP64           :: IMAGE_FILE_MACHINE_ALPHA64
IMAGE_FILE_MACHINE_TRICORE         :: 0x0520  // Infineon
IMAGE_FILE_MACHINE_CEF             :: 0x0CEF
IMAGE_FILE_MACHINE_EBC             :: 0x0EBC  // EFI Byte Code
IMAGE_FILE_MACHINE_AMD64           :: 0x8664  // AMD64 (K8)
IMAGE_FILE_MACHINE_M32R            :: 0x9041  // M32R little-endian
IMAGE_FILE_MACHINE_ARM64           :: 0xAA64  // ARM64 Little-Endian
IMAGE_FILE_MACHINE_CEE             :: 0xC0EE

IMAGE_FILE_HEADER :: struct
{
	Machine:              u16,
	NumberOfSections:     u16,
	TimeDateStamp:        u32,
	PointerToSymbolTable: u32,
	NumberOfSymbols:      u32,
	SizeOfOptionalHeader: u16,
	Characteristics:      u16,
}

IMAGE_DATA_DIRECTORY :: struct
{
	VirtualAddress: u32,
	Size:           u32,
}

IMAGE_NUMBEROF_DIRECTORY_ENTRIES :: 16

IMAGE_OPTIONAL_HEADER64 :: struct
{
	Magic:                       u16,
	MajorLinkerVersion:          u8,
	MinorLinkerVersion:          u8,
	SizeOfCode:                  u32,
	SizeOfInitializedData:       u32,
	SizeOfUninitializedData:     u32,
	AddressOfEntryPoint:         u32,
	BaseOfCode:                  u32,
	ImageBase:                   u64,
	SectionAlignment:            u32,
	FileAlignment:               u32,
	MajorOperatingSystemVersion: u16,
	MinorOperatingSystemVersion: u16,
	MajorImageVersion:           u16,
	MinorImageVersion:           u16,
	MajorSubsystemVersion:       u16,
	MinorSubsystemVersion:       u16,
	Win32VersionValue:           u32,
	SizeOfImage:                 u32,
	SizeOfHeaders:               u32,
	CheckSum:                    u32,
	Subsystem:                   u16,
	DllCharacteristics:          u16,
	SizeOfStackReserve:          u64,
	SizeOfStackCommit:           u64,
	SizeOfHeapReserve:           u64,
	SizeOfHeapCommit:            u64,
	LoaderFlags:                 u32,
	NumberOfRvaAndSizes:         u32,
	DataDirectory:               [IMAGE_NUMBEROF_DIRECTORY_ENTRIES]IMAGE_DATA_DIRECTORY,
}

DOS_PROGRAM_BYTES := [?]byte \
{
	0x0E, 0x1F, 0xBA, 0x0E, 0x00, 0xB4, 0x09, 0xCD, 0x21, 0xB8, 0x01, 0x4C, 0xCD, 0x21, 0x54, 0x68,
	0x69, 0x73, 0x20, 0x70, 0x72, 0x6F, 0x67, 0x72, 0x61, 0x6D, 0x20, 0x63, 0x61, 0x6E, 0x6E, 0x6F,
	0x74, 0x20, 0x62, 0x65, 0x20, 0x72, 0x75, 0x6E, 0x20, 0x69, 0x6E, 0x20, 0x44, 0x4F, 0x53, 0x20,
	0x6D, 0x6F, 0x64, 0x65, 0x2E, 0x0D, 0x0D, 0x0A, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x55, 0x58, 0x04, 0xC7, 0x11, 0x39, 0x6A, 0x94, 0x11, 0x39, 0x6A, 0x94, 0x11, 0x39, 0x6A, 0x94,
	0x4A, 0x51, 0x6B, 0x95, 0x12, 0x39, 0x6A, 0x94, 0x11, 0x39, 0x6B, 0x94, 0x10, 0x39, 0x6A, 0x94,
	0x97, 0x49, 0x6E, 0x95, 0x10, 0x39, 0x6A, 0x94, 0x97, 0x49, 0x68, 0x95, 0x10, 0x39, 0x6A, 0x94,
	0x52, 0x69, 0x63, 0x68, 0x11, 0x39, 0x6A, 0x94, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
}

write_executable :: proc()
{
	exe_buffer := make_buffer(1024 * 1024, win32.PAGE_READWRITE)
	buffer_append(&exe_buffer, IMAGE_DOS_HEADER \
	{
		e_magic    = IMAGE_DOS_SIGNATURE,
		e_cblp     = 0x90,   // Bytes on last page of file. What does that do??
		e_cp       = 0x03,   // Pages in file. What does that do??
		e_cparhdr  = 0x04,   // Size of header in paragraphs. What does that do??
		e_minalloc = 0,
		e_maxalloc = 0xffff,
		e_sp       = 0xb8,   // Initial SP value
		e_lfarlc   = 0x40,   // File address of relocation table
		e_lfanew   = 0xc8,
	})
	
	buffer_append(&exe_buffer, DOS_PROGRAM_BYTES)
	buffer_append(&exe_buffer, i32(IMAGE_NT_SIGNATURE))
	
	buffer_append(&exe_buffer, IMAGE_FILE_HEADER \
	{
		Machine              = IMAGE_FILE_MACHINE_AMD64,
		NumberOfSections     = 3,
		TimeDateStamp        = 0x5ef48e56,
		SizeOfOptionalHeader = size_of(IMAGE_OPTIONAL_HEADER64),
		Characteristics      = IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE,
	})
	
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