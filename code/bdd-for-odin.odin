package main

import "core:fmt"
import "core:os"
import "core:runtime"
import "core:strings"

BDD_State :: struct
{
	failed_check:      bool,
	failed_checks:     [dynamic]runtime.Source_Code_Location,
	test_count:        int,
	failed_test_count: int,
	before_each_proc:  proc(),
	after_each_proc:   proc(),
}

GLOBAL_bdd_state: BDD_State

spec :: proc(name: string)
{
	fmt.println(name)
	GLOBAL_bdd_state =
	{
		test_count        = GLOBAL_bdd_state.test_count,
		failed_test_count = GLOBAL_bdd_state.failed_test_count,
	}
}

before_each :: proc(before_each_proc: proc())
{
	GLOBAL_bdd_state.before_each_proc = before_each_proc
}

after_each :: proc(after_each_proc: proc())
{
	GLOBAL_bdd_state.after_each_proc = after_each_proc
}

it :: proc(requirement: string, test: proc())
{
	if GLOBAL_bdd_state.before_each_proc != nil
	{
		GLOBAL_bdd_state.before_each_proc()
	}
	GLOBAL_bdd_state.failed_check = false
	test()
	if GLOBAL_bdd_state.after_each_proc != nil
	{
		GLOBAL_bdd_state.after_each_proc()
	}
	GLOBAL_bdd_state.test_count += 1
	fmt.printf("  %v ", requirement)
	if GLOBAL_bdd_state.failed_check
	{
		fmt.printf("(FAIL)\n")
		for loc in GLOBAL_bdd_state.failed_checks
		{
			fmt.printf("    Check failed: ")
			src, ok := os.read_entire_file(loc.file_path)
			if ok
			{
				defer delete(src)
				lines := strings.split(string(src), "\n")
				defer delete(lines)
				line := lines[loc.line - 1]
				expr := line[loc.column + 5:len(line) - 2]
				fmt.printf("%v\n", expr)
			}
			fmt.printf("      at %v:%v\n", loc.file_path, loc.line)
		}
		GLOBAL_bdd_state.failed_test_count += 1
	}
	else
	{
		fmt.printf("(OK)\n")
	}
	clear(&GLOBAL_bdd_state.failed_checks)
}

check :: proc(expression: bool, location := #caller_location)
{
	if !expression
	{
		GLOBAL_bdd_state.failed_check = true
		append(&GLOBAL_bdd_state.failed_checks, location)
	}
}

print_test_results :: proc()
{
	decoration := GLOBAL_bdd_state.failed_test_count > 0 ? "!!!" : "---"
	fmt.printf("\n%v %v tests run, %v failed. %v\n\n",
	           decoration, GLOBAL_bdd_state.test_count, GLOBAL_bdd_state.failed_test_count, decoration)
}
