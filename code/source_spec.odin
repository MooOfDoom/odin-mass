package main

import "core:fmt"

source_spec :: proc()
{
	spec("source")
	
	temp_buffer := make_buffer(1024 * 1024, PAGE_READWRITE)
	context.allocator = buffer_allocator(&temp_buffer)
	
	after_each(proc()
	{
		free_all()
	})
	
	it("should be able to tokenize an empty string", proc()
	{
		source := ""
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.parent == nil)
		check(root.type == .Module)
		check(len(root.children) == 0)
	})
	
	it("should be able to tokenize a comment", proc()
	{
		source := "// foo\n"
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.parent == nil)
		check(root.type == .Module)
		check(len(root.children) == 0)
	})
	
	it("should be able to tokenize a sum of integers", proc()
	{
		source := "12 + foo123"
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.type == .Module)
		check(len(root.children) == 3)
		check(root.source == source)
		
		a_num := root.children[0]
		check(a_num.type == .Integer)
		check(a_num.source == "12")
		
		plus := root.children[1]
		check(plus.type == .Operator)
		check(plus.source == "+")
		
		b_num := root.children[2]
		check(b_num.type == .Id)
		check(b_num.source == "foo123")
	})
	
	it("should be able to tokenize groups", proc()
	{
		source := "(x)"
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.type == .Module)
		check(len(root.children) == 1)
		check(root.source == source)
		
		paren := root.children[0]
		check(paren.type == .Paren)
		check(len(paren.children) == 1)
		check(paren.source == "(x)")
		
		id := paren.children[0]
		check(id.type == .Id)
		check(id.source == "x")
	})
	
	it("should be able to tokenize strings", proc()
	{
		source := `"foo 123"`
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.type == .Module)
		check(len(root.children) == 1)
		check(root.source == source)
		
		str := root.children[0]
		check(str.type == .String)
		check(str.source == source)
	})
	
	it("should be able to tokenize nested groups with different braces", proc()
	{
		source := "{[]}"
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.type == .Module)
		check(len(root.children) == 1)
		check(root.source == source)
		
		curly := root.children[0]
		check(curly.type == .Curly)
		check(len(curly.children) == 1)
		check(curly.source == "{[]}")
		
		square := curly.children[0]
		check(square.type == .Square)
		check(len(square.children) == 0)
		check(square.source == "[]")
	})
	
	it("should be able to tokenize complex expressions", proc()
	{
		source :=
`foo :: (x: s8) -> {
	return x + 3;
}`
		result := tokenize("_test_.mass", source)
		check(result.type == .Success)
		root := result.root
		check(root != nil)
		check(root.type == .Module)
		check(root.source == source)
	})
	
	it("should report a failure when encountering a brace that is not closed", proc()
	{
		source := "(foo"
		result := tokenize("_test_.mass", source)
		check(result.type == .Error)
		check(len(result.errors) == 1)
		error := result.errors[0]
		check(error.location.filename == "_test_.mass")
		check(error.location.line == 1)
		check(error.location.column == 4)
		check(error.message == "Unexpected end of file. Expected a closing brace.")
		
		print_message_with_location(error.message, &error.location)
	})
}