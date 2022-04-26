package main

import "core:fmt"
import "core:mem"
import "core:strconv"
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
	Value,
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
		value:    ^Value,
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

Source_Location :: struct
{
	filename: string,
	line:     int,
	column:   int,
}

Tokenizer_Error :: struct
{
	message:  string,
	location: Source_Location,
}

Tokenizer_Result_Type :: enum
{
	Error,
	Success,
}

Tokenizer_Result :: struct
{
	type: Tokenizer_Result_Type,
	using data: struct #raw_union
	{
		root:   ^Token,
		errors: [dynamic]Tokenizer_Error,
	},
}

print_message_with_location :: proc(message: string, location: ^Source_Location)
{
	fmt.printf("%v(%v:%v): %v\n", location.filename, location.line, location.column, message)
}

print_token_tree :: proc(token: ^Token, indent: int = 0)
{
	for i in 0 ..< indent
	{
		fmt.printf("\t")
	}
	fmt.printf("%v: `%v`\n", token.type, token.source)
	for child in token.children
	{
		print_token_tree(child, indent + 1)
	}
}

tokenize :: proc(filename: string, source: string) -> Tokenizer_Result
{
	start_token :: proc(type: Token_Type, parent: ^Token, source: string, i: int) -> ^Token
	{
		return new_clone(Token \
		{
			type   = type,
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
	
	push_error :: proc(errors: ^[dynamic]Tokenizer_Error, message: string, filename: string, line: int, column: int)
	{
		append(errors, Tokenizer_Error \
		{
			message = message,
			location =
			{
				filename = filename,
				line     = line,
				column   = column,
			},
		})
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
	
	errors := make([dynamic]Tokenizer_Error, 0, 16)
	
	// fmt.println(source)
	
	line   := 1
	column := 0
	next_i := 0
	source_loop: for i := 0; i < len(source); i = next_i
	{
		ch, ch_size := utf8.decode_rune_in_string(source[i:])
		next_i = i + ch_size
		peek, peek_size := utf8.decode_rune_in_string(source[next_i:])
		
		// fmt.println(state, i, "'", ch, "'")
		
		if ch == '\r'
		{
			if peek == '\n'
			{
				continue
			}
			ch = '\n'
		}
		
		if ch == '\n'
		{
			line  += 1
			column = 1
		}
		else
		{
			column += 1
		}
		
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
						if parent == nil || parent.type != type
						{
							push_error(&errors, "Encountered a closing brace without a matching open one", filename, line, column)
							break source_loop
						}
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
						push_error(&errors, "Unexpected input", filename, line, column)
						break source_loop
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
					if !code_point_is_operator(ch)
					{
						end_token(&current_token, parent, source, i, &state)
						continue retry
					}
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
	
	if(parent != root)
	{
		push_error(&errors, "Unexpected end of file. Expected a closing brace.", filename, line, column)
	}
	// current_token can be null in case of an empty input
	if current_token != nil
	{
		if state == .String
		{
			push_error(&errors, "Unexpected end of file. Expected a \".", filename, line, column)
		}
		else
		{
			update_token_source(current_token, source, len(source))
			append(&root.children, current_token)
		}
	}
	
	if len(errors) > 0
	{
		return Tokenizer_Result{type = .Error, data = {errors = errors}}
	}
	return Tokenizer_Result{type = .Success, data = {root = root}}
}

Token_Matcher_State :: struct
{
	root:        ^Token,
	child_index: int,
}

token_peek :: proc(state: ^Token_Matcher_State, peek_index: int) -> ^Token
{
	index := state.child_index + peek_index
	if index >= len(state.root.children) do return nil
	return state.root.children[index]
}

token_peek_match :: proc(state: ^Token_Matcher_State, peek_index: int, pattern_token: ^Token) -> ^Token
{
	source_token := token_peek(state, peek_index)
	if source_token == nil                                                       do return nil
	if pattern_token.type != nil && pattern_token.type != source_token.type      do return nil
	if pattern_token.source != "" && pattern_token.source != source_token.source do return nil
	return source_token
}

program_lookup_type :: proc(program: ^Program, type_name: string) -> ^Descriptor
{
	type_value := scope_lookup(program.global_scope, type_name)
	assert(type_value != nil, "Type not found in global scope")
	assert(type_value.descriptor.type == .Type, "Type was not actually a type")
	descriptor := type_value.descriptor.type_descriptor
	assert(descriptor != nil, "Type somehow did not have a type_descriptor!")
	return descriptor
}

Token_Match_Arg :: struct
{
	arg_name:  string,
	type_name: string,
}

@(private="file")
Maybe_Token_Match :: proc(state: ^Token_Matcher_State, peek_index: ^int, pattern_token: ^Token) -> ^Token
{
	result := token_peek_match(state, peek_index^, pattern_token)
	if result != nil do peek_index^ += 1
	return result
}

@(private="file")
Token_Match :: proc(state: ^Token_Matcher_State, peek_index: ^int, pattern_token: ^Token) -> ^Token
{
	result := token_peek_match(state, peek_index^, pattern_token)
	peek_index^ += 1
	return result
}

@(private="file")
Token_Match_Operator :: proc(state: ^Token_Matcher_State, peek_index: ^int, op: string) -> ^Token
{
	return Token_Match(state, peek_index, &Token{type = .Operator, source = op})
}

token_match_argument :: proc(state: ^Token_Matcher_State, program: ^Program) -> ^Token_Match_Arg
{
	peek_index := 0
	
	arg_id   := Token_Match(state, &peek_index, &Token{type = .Id}); if arg_id   == nil do return nil
	colon    := Token_Match_Operator(state, &peek_index, ":");       if colon    == nil do return nil
	arg_type := Token_Match(state, &peek_index, &Token{type = .Id}); if arg_type == nil do return nil
	comma    := Maybe_Token_Match(state, &peek_index, &Token{type = .Operator, source = ","})
	state.child_index += peek_index
	
	return new_clone(Token_Match_Arg \
	{
		arg_name  = arg_id.source,
		type_name = arg_type.source,
	})
}

token_match_expression :: proc(state: ^Token_Matcher_State, program: ^Program,
                               function_scope: ^Scope) -> ^Value
{
	// plus := token_peek_match(state, 1, &Token{type = .Operator, source = "+"})
	
	if len(state.root.children) == 0 do return nil
	
	// [Int_Token{42}] -> [Value_Token{Value{42}}]
	retry: for
	{
		for expr, i in &state.root.children
		{
			if expr.type == .Integer
			{
				value, ok := strconv.parse_int(expr.source)
				assert(ok, "Could not parse expression as int")
				expr = new_clone(Token \
				{
					type   = .Value,
					parent = expr.parent,
					source = expr.source,
					data   = {value = value_from_i64(i64(value))},
				})
				continue retry
			}
			else if expr.type == .Id
			{
				var := scope_lookup(function_scope, expr.source)
				assert(var != nil, "Variable not found in function scope")
				expr = new_clone(Token \
				{
					type   = .Value,
					parent = expr.parent,
					source = expr.source,
					data   = {value = var},
				})
				continue retry
			}
		}
		break
	}
	
	retry2: for
	{
		for expr, i in &state.root.children
		{
			if i > 0 && i + 1 < len(state.root.children) && expr.type == .Operator && expr.source == "+"
			{
				lhs := state.root.children[i - 1]
				assert(lhs.type == .Value)
				rhs := state.root.children[i + 1]
				assert(rhs.type == .Value)
				
				result := Plus(lhs.value, rhs.value)
				result_token := new_clone(Token \
				{
					type   = .Value,
					parent = expr.parent,
					source = expr.source,
					data   = {value = result},
				})
				state.root.children[i - 1] = result_token
				remove_range(&state.root.children, i, i + 2)
				continue retry2
			}
		}
		break
	}
	
	// Patterns in precedence order
	// _+_
	// Integer | Id
	
	// x + y
	
	assert(len(state.root.children) == 1, "Expression could not be reduced to one value")
	result := state.root.children[0]
	assert(result.type == .Value, "Expression result was not a value")
	return result.value
}

Token_Match_Function :: struct
{
	name:  string,
	value: ^Value,
}

token_match_function_definition :: proc(state: ^Token_Matcher_State, program: ^Program) -> ^Token_Match_Function
{
	peek_index := 0
	
	id           := Token_Match(state, &peek_index, &Token{type = .Id});    if id           == nil do return nil
	colon_colon  := Token_Match_Operator(state, &peek_index, "::");         if colon_colon  == nil do return nil
	args         := Token_Match(state, &peek_index, &Token{type = .Paren}); if args         == nil do return nil
	arrow        := Token_Match_Operator(state, &peek_index, "->");         if arrow        == nil do return nil
	return_types := Token_Match(state, &peek_index, &Token{type = .Paren}); if return_types == nil do return nil
	body         := Token_Match(state, &peek_index, &Token{type = .Curly}); if body         == nil do return nil
	
	function_scope := scope_make(program.global_scope)
	
	value := Function(program)
	{
		builder := get_builder_from_context()
		
		if len(args.children) != 0
		{
			args_state: Token_Matcher_State = {root = args}
			for
			{
				prev_child_index := args_state.child_index
				arg := token_match_argument(&args_state, program)
				if arg != nil
				{
					arg_value := Arg(program_lookup_type(program, arg.type_name))
					scope_define(function_scope, arg.arg_name, arg_value)
				}
				if prev_child_index == args_state.child_index do break
			}
			assert(args_state.child_index == len(args.children), "Error while parsing args")
		}
		switch len(return_types.children)
		{
			case 0:
			{
				value.descriptor.function.returns = &void_value
			}
			case 1:
			{
				return_type_token := return_types.children[0]
				assert(return_type_token.type == .Id, "Return type was not identifier")
				
				fn_return_descriptor(builder, program_lookup_type(program, return_type_token.source))
			}
			case 2:
			{
				assert(false, "Multiple return types are not supported at the moment")
			}
		}
		fn_freeze(builder)
		
		body_state: Token_Matcher_State = {root = body}
		body_result := token_match_expression(&body_state, program, function_scope)
		
		if body_result != nil
		{
			Return(body_result)
		}
	}
	End_Function()
	
	return new_clone(Token_Match_Function \
	{
		name  = id.source,
		value = value,
	})
}
