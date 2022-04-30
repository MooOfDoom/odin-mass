package test

import spec ".."

main :: proc()
{
	spec.mass_spec()
	spec.function_spec()
	spec.source_spec()
	
	spec.print_test_results()
}