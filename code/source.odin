package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

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
	String,
	Single_Line_Comment,
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

code_point_is_operator :: proc(code_point: rune) -> bool
{
	switch code_point
	{
		case '+', '-', '=', '!', '@', '%', '^', '&',
		     '*', '/', ':', ';', ',', '?', '|', '~',
		     '>', '<':
		{
			return true
		}
		case:
		{
			return false
		}
	}
}

tokenize :: proc(source: string) -> ^Token
{
	start_token :: proc(type: Token_Type, parent: ^Token, source: string, i: int) -> ^Token
	{
		return new_clone(Token \
		{
			type = type,
			parent = parent,
			source = source[i:i+1],
		})
	}
	
	update_token_source :: proc(token: ^Token, source: string, byte_index: int)
	{
		// TODO(Lothar): This is a bit awkward. Find a better way to do this!
		length := mem.ptr_sub(mem.ptr_offset(raw_data(source), byte_index), raw_data(token.source))
		(cast(^mem.Raw_String)&token.source).len = length
	}
	
	end_token :: proc(token: ^^Token, parent: ^Token, source: string, i: int, state: ^Tokenizer_State)
	{
		update_token_source(token^, source, i)
		append(&parent.children, token^)
		token^ = nil
		state^ = .Default
	}
	
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
	
	// fmt.println(source)
	
	next_i := 0
	source_loop: for i := 0; i < len(source); i = next_i
	{
		ch, ch_size := utf8.decode_rune_in_string(source[i:])
		next_i = i + ch_size
		peek, peek_size := utf8.decode_rune_in_string(source[next_i:])
		
		// fmt.println(state, i, "'", ch, "'")
		
		retry: for
		{
			switch state
			{
				case .Default:
				{
					if unicode.is_space(ch) do continue source_loop
					if unicode.is_digit(ch)
					{
						current_token = start_token(.Integer, parent, source, i)
						state = .Integer
					}
					else if unicode.is_alpha(ch)
					{
						current_token = start_token(.Id, parent, source, i)
						state = .Id
					}
					else if ch == '/' && peek == '/'
					{
						state = .Single_Line_Comment
					}
					else if code_point_is_operator(ch)
					{
						current_token = start_token(.Operator, parent, source, i)
						state = .Operator
					}
					else if ch == '"'
					{
						current_token = start_token(.String, parent, source, i)
						state = .String
					}
					else if ch == '(' || ch == '{' || ch == '['
					{
						type: Token_Type =
							ch == '(' ? .Paren :
							ch == '{' ? .Curly :
							.Square
						parent = start_token(type, parent, source, i)
						parent.children = make([dynamic]^Token, 0, 4)
					}
					else if ch == ')' || ch == '}' || ch == ']'
					{
						type: Token_Type =
							ch == ')' ? .Paren :
							ch == '}' ? .Curly :
							.Square
						assert(parent != nil, "Found closing bracket without parent")
						assert(parent.type == type, "Found closing bracket with mismatched parent")
						if current_token != nil
						{
							end_token(&current_token, parent, source, i, &state)
						}
						current_token = parent
						parent        = current_token.parent
						end_token(&current_token, parent, source, i + ch_size, &state)
					}
					else
					{
						assert(false, "Unable to tokenize input")
					}
				}
				case .Integer:
				{
					if !unicode.is_digit(ch)
					{
						end_token(&current_token, parent, source, i, &state)
						continue retry
					}
				}
				case .Id:
				{
					if !(unicode.is_alpha(ch) || unicode.is_digit(ch))
					{
						end_token(&current_token, parent, source, i, &state)
						continue retry
					}
				}
				case .Operator:
				{
					end_token(&current_token, parent, source, i, &state)
					continue retry
				}
				case .String:
				{
					if ch == '"'
					{
						end_token(&current_token, parent, source, i + ch_size, &state)
					}
				}
				case .Single_Line_Comment:
				{
					if ch == '\r'
					{
						state = .Default
						if peek == '\n'
						{
							next_i += peek_size
						}
					}
					if ch == '\n'
					{
						state = .Default
					}
				}
			}
			break
		}
	}
	
	assert(parent == root, "Unexpected EOF while tokenizing")
	// current_token can be null in case of an empty input
	if current_token != nil
	{
		assert(state != .String, "Strings need to be terminated with a '\"'")
		update_token_source(current_token, source, len(source))
		append(&root.children, current_token)
	}
	
	return root
}