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
	Lazy_Function_Definition,
}

Lazy_Function_Definition :: struct
{
	args:         ^Token,
	return_types: ^Token,
	body:         ^Token,
	program:      ^Program,
}

Token :: struct
{
	parent: ^Token,
	type:   Token_Type,
	source: string,
	using data: struct #raw_union
	{
		children:                  [dynamic]^Token,
		value:                     ^Value,
		lazy_function_definition : Lazy_Function_Definition,
	},
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

Scope_Entry_Type :: enum
{
	Value = 1,
	Lazy,
}

Scope_Entry :: struct
{
	type: Scope_Entry_Type,
	using data: struct #raw_union
	{
		value: ^Value,
		token: ^Token,
	},
}

Scope :: struct
{
	parent: ^Scope,
	items:  map[string]Scope_Entry,
}

scope_make :: proc(parent: ^Scope = nil) -> ^Scope
{
	return new_clone(Scope \
	{
		parent = parent,
		items  = make(map[string]Scope_Entry),
	})
}

scope_lookup :: proc(scope: ^Scope, name: string) -> Scope_Entry
{
	scope := scope
	
	for scope != nil
	{
		result := scope.items[name]
		if result.type != nil do return result
		scope = scope.parent
	}
	return Scope_Entry{}
}

scope_lookup_force :: proc(scope: ^Scope, name: string, loc := #caller_location) -> ^Value
{
	entry := scope_lookup(scope, name)
	assert(entry.type != nil, "Name not found in scope", loc)
	
	switch entry.type
	{
		case .Value:
		{
			return entry.value
		}
		case .Lazy:
		{
			return token_force_value(entry.token, scope, loc)
		}
	}
	return nil
}

scope_define_value :: proc(scope: ^Scope, name: string, value: ^Value)
{
	// TODO think about what should happen when trying to redefine existing thing
	scope.items[name] = Scope_Entry \
	{
		type = .Value,
		data = {value = value},
	}
}

scope_define_lazy :: proc(scope: ^Scope, name: string, token: ^Token)
{
	// TODO think about what should happen when trying to redefine existing thing
	scope.items[name] = Scope_Entry \
	{
		type = .Lazy,
		data = {token = token},
	}
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

combine_token_sources :: proc(tokens: ..^Token) -> string
{
	if len(tokens) == 0 do return ""
	
	start := max(uintptr)
	end := min(uintptr)
	
	for token in tokens
	{
		start = min(start, uintptr(raw_data(token.source)))
		end = max(start, uintptr(raw_data(token.source)) + uintptr(len(token.source)))
	}
	
	return transmute(string)mem.Raw_String{data = cast(^byte)start, len = int(end - start)}
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
	value := scope_lookup_force(program.global_scope, type_name)
	assert(value.descriptor.type == .Type, "Type was not actually a type")
	descriptor := value.descriptor.type_descriptor
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

token_force_value :: proc(token: ^Token, scope: ^Scope, loc := #caller_location) -> ^Value
{
	result_value: ^Value
	if token.type == .Integer
	{
		value, ok := strconv.parse_int(token.source)
		assert(ok, "Could not parse expression as int", loc)
		// FIXME We should be able to size immediates automatically
		result_value = value_from_signed_immediate(value)
	}
	else if token.type == .Id
	{
		result_value = scope_lookup_force(scope, token.source, loc)
	}
	else if token.type == .Value
	{
		return token.value
	}
	else if token.type == .Lazy_Function_Definition
	{
		return token_force_lazy_function_definition(&token.lazy_function_definition)
	}
	else
	{
		assert(false, "Not implemented", loc)
	}
	assert(result_value != nil, "Token could not be forced into value", loc)
	return result_value
}

token_match_call_arguments :: proc(token: ^Token, scope: ^Scope, builder: ^Function_Builder) -> [dynamic]^Value
{
	result := make([dynamic]^Value, 0, 16)
	if len(token.children) == 0
	{
		// Nothing to do
	}
	else if len(token.children) == 1
	{
		value := token_force_value(token.children[0], scope)
		append(&result, value)
	}
	else
	{
		// FIXME implement this
		assert(false, "Not implemented")
	}
	return result
}

token_value_make :: proc(parent: ^Token, result: ^Value, source_tokens: ..^Token) -> ^Token
{
	return new_clone(Token \
	{
		type   = .Value,
		parent = parent,
		source = combine_token_sources(..source_tokens),
		data   = {value = result},
	})
}

token_match_expression :: proc(token: ^Token, scope: ^Scope, builder: ^Function_Builder) -> ^Value
{
	assert(token.type == .Paren || token.type == .Curly, "Root token was not the right type to match expressions")
	
	if len(token.children) == 0 do return nil
	
	// Match Function Calls
	state := &Token_Matcher_State{root = token}
	for did_replace := true; did_replace;
	{
		did_replace = false
		for i in 0 ..< len(token.children)
		{
			state.child_index = i
			args_token := token_peek_match(state, 1, &Token{type = .Paren})
			if args_token == nil do continue
			maybe_target := token_peek(state, 0)
			if maybe_target.type != .Id && maybe_target.type != .Paren do continue
			
			target := token_force_value(maybe_target, scope)
			
			args := token_match_call_arguments(args_token, scope, builder)
			
			result := call_function_value(builder, target, ..args[:])
			result_token := token_value_make(token, result, ..token.children[i:i + 2])
			token.children[i] = result_token
			ordered_remove(&token.children, i + 1)
			did_replace = true
		}
	}
	
	state = &Token_Matcher_State{root = token}
	for did_replace := true; did_replace;
	{
		did_replace = false
		for i in 0 ..< len(token.children)
		{
			state.child_index = i
			plus_token := token_peek_match(state, 1, &Token{type = .Operator, source = "+"})
			if plus_token == nil do continue
			
			lhs := token_force_value(token_peek(state, 0), scope)
			rhs := token_force_value(token_peek(state, 2), scope)
			
			result := plus(builder, lhs, rhs)
			result_token := token_value_make(token, result, ..token.children[i:i + 3])
			token.children[i] = result_token
			remove_range(&token.children, i + 1, i + 3)
			did_replace = true
		}
	}
	
	assert(len(token.children) == 1, "Expression could not be reduced to one value")
	return token_force_value(token.children[0], scope)
}

token_force_lazy_function_definition :: proc(lazy_function_definition: ^Lazy_Function_Definition) -> ^Value
{
	args           := lazy_function_definition.args
	return_types   := lazy_function_definition.return_types
	body           := lazy_function_definition.body
	program        := lazy_function_definition.program
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
					scope_define_value(function_scope, arg.arg_name, arg_value)
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
				
				fn_return_descriptor(builder, program_lookup_type(program, return_type_token.source), .Explicit)
			}
			case 2:
			{
				assert(false, "Multiple return types are not supported at the moment")
			}
		}
		fn_freeze(builder)
		
		// FIXME figure out a better way to distinguish imports
		if body.type == .Value && body.value.descriptor == nil
		{
			body.value.descriptor = builder.result.descriptor
			End_Function()
			return body.value
		}
		else
		{
			body_result := token_match_expression(body, function_scope, builder)
			if body_result != nil
			{
				fn_return(builder, body_result, .Implicit)
			}
		}
	}
	End_Function()
	
	return value
}

token_string_to_string :: proc(token: ^Token) -> string
{
	assert(len(token.source) >= 2, "String does not have quotation marks")
	return token.source[1:len(token.source) - 1]
}

token_import_match_arguments :: proc(paren: ^Token, program: ^Program) -> ^Token
{
	assert(paren.type == .Paren, "Import arguments were not in parentheses")
	state := &Token_Matcher_State{root = paren}
	
	library_name_string := token_peek_match(state, 0, &Token{type = .String})
	assert(library_name_string != nil, "Import arguments missing the library name")
	comma := token_peek_match(state, 1, &Token{type = .Operator, source = ","})
	assert(comma != nil, "Import arguments missing comma")
	symbol_name_string := token_peek_match(state, 2, &Token{type = .String})
	assert(symbol_name_string != nil, "Import arguments missing symbol name")
	
	library_name := token_string_to_string(library_name_string)
	symbol_name  := token_string_to_string(symbol_name_string)
	
	result := new_clone(Value \
	{
		descriptor = nil,
		operand = import_symbol(program, library_name, symbol_name),
	})
	
	return token_value_make(paren, result, library_name_string, comma, symbol_name_string)
}

token_match_module :: proc(token: ^Token, program: ^Program)
{
	assert(token.type == .Module, "Token was not a module")
	if len(token.children) == 0 do return
	
	state := &Token_Matcher_State{root = token}
	
	// Matching symbol imports
	for did_replace := true; did_replace;
	{
		did_replace = false
		for i := 0; i < len(token.children); i += 1
		{
			state.child_index = i
			
			import_ := token_peek_match(state, 0, &Token{type = .Id, source = "import"})
			if import_ == nil do continue
			args := token_peek_match(state, 1, &Token{type = .Paren})
			if args == nil do continue
			
			result_token := token_import_match_arguments(args, program)
			
			token.children[i] = result_token
			ordered_remove(&token.children, i + 1)
			did_replace = true
		}
	}
	
	for did_replace := true; did_replace;
	{
		did_replace = false
		for i in 0 ..< len(token.children)
		{
			state.child_index = i
			
			arrow := token_peek_match(state, 1, &Token{type = .Operator, source = "->"})
			if arrow == nil do continue
			
			args         := token_peek_match(state, 0, &Token{type = .Paren})
			return_types := token_peek_match(state, 2, &Token{type = .Paren})
			body         := token_peek(state, 3)
			// TODO show proper error to the user
			assert(args != nil, "Function definition is missing args")
			assert(return_types != nil, "Function definition is missing return type")
			assert(body != nil, "Function definition is missing body")
			
			result_token := new_clone(Token \
			{
				type   = .Lazy_Function_Definition,
				parent = token,
				source = combine_token_sources(args, arrow, return_types, body),
				data   = {lazy_function_definition =
				{
					args         = args,
					return_types = return_types,
					body         = body,
					program      = program,
				}},
			})
			
			token.children[i] = result_token
			remove_range(&token.children, i + 1, i + 4)
			did_replace = true
		}
	}
	
	for did_replace := true; did_replace;
	{
		did_replace = false
		for i := 0; i < len(token.children); i += 1
		{
			state.child_index = i
			
			define := token_peek_match(state, 1, &Token{type = .Operator, source = "::"})
			if define == nil do continue
			
			name := token_peek_match(state, 0, &Token{type = .Id})
			value := token_peek(state, 2)
			assert(value != nil, "Missing definition of global value")
			scope_define_lazy(program.global_scope, name.source, value)
			
			remove_range(&token.children, i, i + 3)
			did_replace = true
			i -= 1 // Don't advance
		}
	}
	
	assert(len(token.children) == 0, "Unable to parse entire module")
}
