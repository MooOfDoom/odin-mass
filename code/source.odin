package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode"

Token_Type :: enum
{
	Id = 1,
	Integer,
	Operator,
	String,
	Paren,
	Square,
	Curly,
	Module,
}

Tokenizer_State :: enum
{
	Default,
	Integer,
	Operator,
	Id,
}

Token :: struct
{
	parent: ^Token,
	type:   Token_Type,
	source: string,
	using data: struct #raw_union
	{
		children: [dynamic]^Token,
	},
}

update_token_source :: proc(token: ^Token, source: string, byte_index: int)
{
	// TODO(Lothar): This is very awkward. Find a better way to do this!
	length := int(uintptr(raw_data(source))) + byte_index - int(uintptr(raw_data(token.source)))
	(cast(^mem.Raw_String)&token.source).len = length
}

tokenize :: proc(source: string) -> ^Token
{
	root := new_clone(Token \
	{
		parent = nil,
		type   = .Module,
		source = source,
		data   = {children = make([dynamic]^Token, 0, 32)},
	})
	
	state := Tokenizer_State.Default
	current_token: ^Token
	parent := root
	
	for ch, i in source
	{
		// fmt.println(state, i, "'", ch, "'")
		
		if ch == ')'
		{
			assert(parent != nil, "Found ')' without parent")
			assert(parent.type == .Paren, "Found ')' with mismatched parent")
			if current_token != nil
			{
				update_token_source(current_token, source, i)
				append(&parent.children, current_token)
				current_token = nil
			}
			update_token_source(parent, source, i + 1)
			append(&parent.parent.children, parent)
			parent = parent.parent
			state = .Default
			continue
		}
		
		switch state
		{
			case .Default:
			{
				if unicode.is_space(ch) do continue
				if unicode.is_digit(ch)
				{
					current_token = new_clone(Token \
					{
						type   = .Integer,
						parent = parent,
						source = source[i:i+1],
					})
					state = .Integer
				}
				else if unicode.is_alpha(ch)
				{
					current_token = new_clone(Token \
					{
						type   = .Id,
						parent = parent,
						source = source[i:i+1],
					})
					state = .Id
				}
				else if ch == '+'
				{
					current_token = new_clone(Token \
					{
						type   = .Operator,
						parent = parent,
						source = source[i:i+1],
					})
					state = .Operator
				}
				else if ch == '('
				{
					parent = new_clone(Token \
					{
						type   = .Paren,
						parent = parent,
						source = source[i:i+1],
						data = {children = make([dynamic]^Token, 0, 4)},
					})
				}
				else
				{
					assert(false, "Unable to tokenize input")
				}
			}
			case .Integer:
			{
				if unicode.is_space(ch)
				{
					update_token_source(current_token, source, i)
					append(&parent.children, current_token)
					current_token = nil
					state = .Default
				}
				else if unicode.is_digit(ch)
				{
					// nothing to do
				}
				else
				{
					assert(false, "Unable to tokenize input")
				}
			}
			case .Id:
			{
				if unicode.is_space(ch)
				{
					update_token_source(current_token, source, i)
					append(&parent.children, current_token)
					current_token = nil
					state = .Default
				}
				else if unicode.is_alpha(ch) || unicode.is_digit(ch)
				{
					// nothing to do
				}
				else
				{
					assert(false, "Unable to tokenize input")
				}
			}
			case .Operator:
			{
				if unicode.is_space(ch)
				{
					update_token_source(current_token, source, i)
					append(&parent.children, current_token)
					current_token = nil
					state = .Default
				}
				else
				{
					assert(false, "Unable to tokenize input")
				}
			}
		}
	}
	
	assert(parent == root)
	// current_token can be null in case of an empty input
	if current_token != nil
	{
		update_token_source(current_token, source, len(source))
		append(&root.children, current_token)
	}
	
	return root
}