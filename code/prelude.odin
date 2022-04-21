package main

import "core:fmt"
import "core:intrinsics"
import "core:mem"
import "core:runtime"
import "core:strings"
import "core:sys/win32"

fn_opaque                         :: distinct rawptr
fn_void_to_void                   :: #type proc "c" ()
fn_void_to_i32                    :: #type proc "c" () -> i32
fn_void_to_i64                    :: #type proc "c" () -> i64
fn_pi32_to_void                   :: #type proc "c" (^i32)
fn_type_i32_to_i8                 :: #type proc "c" (i32) -> i8
fn_i32_to_i32                     :: #type proc "c" (i32) -> i32
fn_i32_to_i64                     :: #type proc "c" (i32) -> i64
fn_i64_to_i64                     :: #type proc "c" (i64) -> i64
fn_i32_i8_to_i8                   :: #type proc "c" (i32, i8) -> i8
fn_i32_i32_to_i32                 :: #type proc "c" (i32, i32) -> i32
fn_i64_i64_to_i64                 :: #type proc "c" (i64, i64) -> i64
fn__void_to_i32__to_i32           :: #type proc "c" (fn_void_to_i32) -> i32
fn_i64_i64_i64_to_i64             :: #type proc "c" (i64, i64, i64) -> i64
fn_i64_i64_i64_i64_i64_to_i64     :: #type proc "c" (i64, i64, i64, i64, i64) -> i64
fn_i64_i64_i64_i64_i64_i64_to_i64 :: #type proc "c" (i64, i64, i64, i64, i64, i64) -> i64
fn_rawptr_to_i32                  :: #type proc "c" (rawptr) -> i32
fn_rawptr_i64_to_i64              :: #type proc "c" (rawptr, i64) -> i64

align :: proc(number: $T, alignment: T) -> T
	where intrinsics.type_is_integer(T)
{
	return ((number + alignment - 1) / alignment) * alignment
}

Buffer :: struct
{
	memory:   []byte,
	occupied: int,
}

buffer_allocator :: proc(buffer: ^Buffer) -> mem.Allocator
{
	return mem.Allocator \
	{
		procedure = buffer_allocator_proc,
		data      = buffer,
	}
}

buffer_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                              size: int, alignment: int,
                              old_memory: rawptr, old_size: int,
                              location := #caller_location) -> ([]byte, mem.Allocator_Error)
{
	buffer := cast(^Buffer)allocator_data
	
	switch mode
	{
		case .Alloc:
		{
			if size < 0
			{
				return nil, .Invalid_Argument
			}
			
			#no_bounds_check end := &buffer.memory[buffer.occupied]
			aligned_end := mem.align_forward(end, uintptr(alignment))
			extra := uintptr(aligned_end) - uintptr(end)
			total_size := size + int(extra)
			
			if buffer.occupied + total_size > len(buffer.memory)
			{
				return nil, .Out_Of_Memory
			}
			
			buffer.occupied += total_size
			mem.zero(aligned_end, size)
			
			return mem.byte_slice(aligned_end, size), nil
		}
		case .Free:
		{
			return nil, .Mode_Not_Implemented
		}
		case .Free_All:
		{
			buffer.occupied = 0
			return nil, nil
		}
		case .Resize:
		{
			if size < 0
			{
				return nil, .Invalid_Argument
			}
			
			if old_memory == nil
			{
				return mem.alloc_bytes(size, alignment, buffer_allocator(buffer), location)
			}
			
			aligned_old_mem := mem.align_forward(old_memory, uintptr(alignment))
			
			#no_bounds_check buffer_end := &buffer.memory[buffer.occupied]
			old_end := &(cast([^]byte)old_memory)[old_size]
			if buffer_end == old_end
			{
				// The old allocation is at the end of the buffer
				extra := uintptr(aligned_old_mem) - uintptr(rawptr(old_memory))
				new_total_size := size + int(extra)
				old_buffer_occupied := int(uintptr(old_memory) - uintptr(&buffer.memory[0]))
				
				if size == 0
				{
					buffer.occupied = old_buffer_occupied
					return nil, nil
				}
				
				if old_buffer_occupied + new_total_size > len(buffer.memory)
				{
					return nil, .Out_Of_Memory
				}
				
				buffer.occupied = old_buffer_occupied + new_total_size
				if aligned_old_mem != old_memory
				{
					copy(mem.byte_slice(aligned_old_mem, size), mem.byte_slice(old_memory, old_size))
				}
				return mem.byte_slice(aligned_old_mem, size), nil
			}
			
			if size == 0
			{
				return nil, nil
			}
			
			if aligned_old_mem != old_memory || size > old_size
			{
				new_mem, err := mem.alloc_bytes(size, alignment, buffer_allocator(buffer), location)
				if err != nil
				{
					return nil, nil
				}
				runtime.copy(new_mem, mem.byte_slice(old_memory, old_size))
				return new_mem, nil
			}
			return mem.byte_slice(old_memory, size), nil
		}
		case .Query_Features:
		{
			set := cast(^mem.Allocator_Mode_Set)old_memory
			if set != nil
			{
				set^ = {.Alloc, .Free_All, .Resize, .Query_Features}
			}
			return nil, nil
		}
		case .Query_Info:
		{
			return nil, .Mode_Not_Implemented
		}
	}
	return nil, nil
}

win32_allocate_memory :: proc(size: int, permission_flags: u32) -> []byte
{
	return mem.byte_slice(win32.virtual_alloc(nil, uint(size), win32.MEM_COMMIT | win32.MEM_RESERVE, permission_flags),
	                      size)
}

win32_free_memory :: proc(ptr: rawptr) 
{
	win32.virtual_free(ptr, 0, win32.MEM_RELEASE)
}

make_buffer :: proc(capacity: int, permission_flags: u32) -> Buffer
{
	return Buffer{
		memory = win32_allocate_memory(capacity, permission_flags),
		occupied = 0,
	}
}

free_buffer :: proc(buffer: ^Buffer)
{
	if buffer.memory != nil
	{
		win32_free_memory(&buffer.memory[0])
		buffer.memory = nil
	}
	buffer.occupied = 0
}

buffer_allocate :: proc(buffer: ^Buffer, $T: typeid) -> ^T
{
	assert(buffer.occupied + size_of(T) <= len(buffer.memory))
	result := &buffer.memory[buffer.occupied]
	buffer.occupied += size_of(T)
	return cast(^T)result
}

buffer_allocate_size :: proc(buffer: ^Buffer, size: int) -> []byte
{
	assert(buffer.occupied + size <= len(buffer.memory))
	result := mem.byte_slice(&buffer.memory[buffer.occupied], size)
	buffer.occupied += size
	return result
}

buffer_append :: proc(buffer: ^Buffer, value: $T)
{
	first_non_occupied_address := &buffer.memory[buffer.occupied]
	target := cast(^T)first_non_occupied_address
	target^ = value
	buffer.occupied += size_of(value)
}

buffer_append_i8 :: proc(buffer: ^Buffer, value: i8)
{
	buffer.memory[buffer.occupied] = u8(value)
	buffer.occupied += size_of(value)
}

buffer_append_u8 :: proc(buffer: ^Buffer, value: u8)
{
	buffer.memory[buffer.occupied] = value
	buffer.occupied += size_of(value)
}

print_buffer :: proc(buffer: []byte)
{
	sb := strings.make_builder(context.temp_allocator)
	for i in 0 ..< len(buffer)
	{
		fmt.sbprintf(&sb, "%2x", buffer[i])
		if i < len(buffer) - 1
		{
			fmt.sbprintf(&sb, " ")
		}
	}
	fmt.printf("%v\n", strings.to_string(sb))
}
