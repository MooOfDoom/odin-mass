package minimal

foreign import "system:kernel32.lib"

foreign kernel32
{
	@(link_name="ExitProcess") exit_process :: proc "std" (exit_code: u32) ---
}

main :: proc()
{
	exit_process(42)
}
