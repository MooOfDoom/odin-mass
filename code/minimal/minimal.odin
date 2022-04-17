package minimal

foreign import "system:kernel32.lib"

foreign kernel32
{
	ExitProcess :: proc "std" (exit_code: u32) ---
}

main :: proc()
{
	ExitProcess(42)
}
