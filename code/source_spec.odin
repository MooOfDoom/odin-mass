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
		root := tokenize(source)
		check(root != nil)
		check(root.parent == nil)
		check(root.type == .Module)
		check(len(root.children) == 0)
	})
	
	it("should be able to tokenize a sum of integers", proc()
	{
		source := "12 + foo123"
		root := tokenize(source)
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
		root := tokenize(source)
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
	
	it("should be able to tokenize complex expressions", proc()
	{
		source := "(42 + (foo + 123 + 1423))"
		root := tokenize(source)
		check(root != nil)
		check(root.type == .Module)
		check(len(root.children) == 1)
		check(root.source == source)
		
		paren := root.children[0]
		check(paren.type == .Paren)
		check(len(paren.children) == 3)
		
		nexted_paren := paren.children[2]
		check(nexted_paren.type == .Paren)
		check(len(nexted_paren.children) == 5)
	})
}