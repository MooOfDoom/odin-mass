package main

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:runtime"
import "core:sys/win32"
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
		value:  ^Value,
		tokens: [dynamic]^Token,
	},
}

Macro :: struct
{
	pattern:       [dynamic]^Token,
	replacement:   [dynamic]^Token,
	pattern_names: [dynamic]string,
}

Scope :: struct
{
	parent: ^Scope,
	items:  map[string]Scope_Entry,
	macros: [dynamic]^Macro,
}

scope_make :: proc(parent: ^Scope = nil) -> ^Scope
{
	return new_clone(Scope \
	{
		parent = parent,
		items  = make(map[string]Scope_Entry),
	})
}

scope_lookup :: proc(scope: ^Scope, name: string) -> ^Scope_Entry
{
	scope := scope
	
	for scope != nil
	{
		result := &scope.items[name]
		if result != nil do return result
		scope = scope.parent
	}
	return nil
}

scope_lookup_force :: proc(scope: ^Scope, name: string, builder: ^Function_Builder = nil, loc := #caller_location) -> ^Value
{
	scope := scope
	
	entry: ^Scope_Entry
	for scope != nil
	{
		entry = &scope.items[name]
		if entry != nil do break
		scope = scope.parent
	}
	assert(entry != nil, fmt.tprintf("Name %q not found in scope", name), loc)
	result: ^Value
	switch entry.type
	{
		case .Value:
		{
			result = entry.value
			break
		}
		case .Lazy:
		{
			tokens := entry.tokens
			for token in &tokens
			{
				if result == nil
				{
					result = token_force_value(token, scope, builder, loc)
				}
				else
				{
					assert(result.descriptor.type == .Function, "Lazy scope entry wasn't function")
					overload := token_force_value(token, scope, builder, loc)
					overload.descriptor.function.next_overload = result
					result = overload
				}
			}
			assert(result != nil, "Could not force lazy definition into value")
			// NOTE(Lothar): No guarantees that the looked up entry is still valid after token_force_value,
			// so look it up again
			scope.items[name] =
			{
				type = .Value,
				data = {value = result},
			}
		}
	}
	// For functions we need to gather up overloads from all parent scopes
	if result.descriptor.type == .Function
	{
		last := result
		for parent_scope := scope.parent; parent_scope != nil; parent_scope = parent_scope.parent
		{
			if &parent_scope.items[name] == nil do continue
			overload := scope_lookup_force(parent_scope, name, builder, loc)
			assert(overload.descriptor.type == .Function, "Name did not correspond to function in parent scope")
			for last.descriptor.function.next_overload != nil
			{
				last = last.descriptor.function.next_overload
			}
			last.descriptor.function.next_overload = overload
		}
	}
	assert(result != nil, "Could not force lookup")
	return result
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
	// For overloads we only check current scope and allow multiple overloads
	// in multiple nested scopes
	entry := &scope.items[name]
	if entry == nil
	{
		tokens := make([dynamic]^Token, 0, 16)
		append(&tokens, token)
		scope.items[name] = Scope_Entry \
		{
			type = .Lazy,
			data = {tokens = tokens},
		}
	}
	else
	{
		assert(entry.type == .Lazy, "Tried to redefine non-lazy symbol with lazy symbol")
		append(&entry.tokens, token)
	}
	// TODO think about what should happen when trying to redefine existing thing
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
		// NOTE(Lothar): Due to the way we skip \r in case of \r\n, we may inadvertantly include \r in the source.
		// This avoids this explicitly
		if source[i - 1] == '\r'
		{
			update_token_source(token^, source, i - 1)
		}
		else
		{
			update_token_source(token^, source, i)
		}
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
					else if unicode.is_alpha(ch) || ch == '_'
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
					if !(unicode.is_alpha(ch) || unicode.is_digit(ch) || ch == '_')
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
	tokens:      ^[dynamic]^Token,
	start_index: int,
}

token_peek :: proc(state: ^Token_Matcher_State, peek_index: int) -> ^Token
{
	index := state.start_index + peek_index
	if index >= len(state.tokens) do return nil
	return state.tokens[index]
}

token_match :: proc(source: ^Token, pattern: ^Token) -> bool
{
	if pattern.type   != nil && pattern.type   != source.type   do return false
	if pattern.source != ""  && pattern.source != source.source do return false
	return true
}

token_peek_match :: proc(state: ^Token_Matcher_State, peek_index: int, pattern_token: ^Token) -> ^Token
{
	source_token := token_peek(state, peek_index)
	if source_token == nil                       do return nil
	if !token_match(source_token, pattern_token) do return nil
	return source_token
}

token_split :: proc(tokens: ^[dynamic]^Token, separator: ^Token) -> [dynamic]Token_Matcher_State
{
	result := make([dynamic]Token_Matcher_State, 0, 16)
	
	sequence := new_clone(make([dynamic]^Token, 0, 16))
	for token, i in tokens
	{
		if token_match(token, separator)
		{
			append(&result, Token_Matcher_State{tokens = sequence})
			sequence = new_clone(make([dynamic]^Token, 0, 16))
		}
		else
		{
			append(sequence, token)
		}
	}
	append(&result, Token_Matcher_State{tokens = sequence})
	return result
}

scope_lookup_type :: proc(scope: ^Scope, type_name: string) -> ^Descriptor
{
	value := scope_lookup_force(scope, type_name)
	assert(value.descriptor.type == .Type, "Type was not actually a type")
	descriptor := value.descriptor.type_descriptor
	assert(descriptor != nil, "Type somehow did not have a type_descriptor!")
	return descriptor
}

Token_Match_Arg :: struct
{
	arg_name:        string,
	type_descriptor: ^Descriptor,
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

@(private="file")
Token_Match_End :: proc(state: ^Token_Matcher_State, peek_index: int)
{
	assert(peek_index == len(state.tokens), "Did not match the right number of tokens")
}

token_force_type :: proc(scope: ^Scope, token: ^Token) -> ^Descriptor
{
	descriptor: ^Descriptor
	#partial switch token.type
	{
		case .Id:
		{
			descriptor = scope_lookup_type(scope, token.source)
		}
		case .Square:
		{
			assert(len(token.children) == 1, "Pointer type did not have exactly one child")
			child := token.children[0]
			descriptor = new_clone(Descriptor \
			{
				type = .Pointer,
				data = {pointer_to = scope_lookup_type(scope, child.source)},
			})
		}
		case:
		{
			assert(false, "Not implemented")
		}
	}
	return descriptor
}

token_pattern_callback :: #type proc([dynamic]^Token, ^Scope, ^Function_Builder) -> [dynamic]^Token

token_match_pattern :: proc(state: ^Token_Matcher_State, pattern: [dynamic]^Token) -> [dynamic]^Token
{
	pattern_length := len(pattern)
	assert(pattern_length > 0, "Empty pattern passed to token_match_pattern");
	for pattern_token, i in pattern
	{
		token := token_peek_match(state, i, pattern_token); if token == nil do return nil
	}
	match := make([dynamic]^Token, 0, pattern_length)
	for _, i in pattern
	{
		token := token_peek(state, i)
		append(&match, token)
	}
	return match
}

token_replace_length_with_tokens :: proc(state: ^Token_Matcher_State, pattern_length: int, replacement: [dynamic]^Token)
{
	replacement_length := len(replacement)
	// FIXME support replacing with more tokens
	assert(replacement_length <= pattern_length, "FIXME support replacing with more tokens")
	from := state.start_index + replacement_length
	deletion_length := pattern_length - replacement_length
	remove_range(state.tokens, from, from + deletion_length)
	
	for token, i in replacement
	{
		state.tokens[state.start_index + i] = token
	}
}

token_rewrite_pattern :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder,
                              pattern: [dynamic]^Token, callback: token_pattern_callback) -> bool
{
	match := token_match_pattern(state, pattern)
	if match == nil do return false
	replacement := callback(match, scope, builder)
	token_replace_length_with_tokens(state, len(pattern), replacement)
	// delete(match)
	return true
}

token_clone_token_array_deep :: proc(match: [dynamic]^Token) -> [dynamic]^Token
{
	result := make([dynamic]^Token, 0, len(match), match.allocator)
	for token in match
	{
		copy := new_clone(token^)
		switch token.type
		{
			case .Integer, .Operator, .String, .Id:
			{
				// Nothing to do
			}
			case .Square, .Paren, .Curly, .Module:
			{
				copy.children = token_clone_token_array_deep(token.children)
			}
			case .Value, .Lazy_Function_Definition:
			{
				assert(false, "Not reached")
			}
		}
		append(&result, copy)
	}
	return result
}

token_apply_macro_replacements :: proc(map_: map[string]^Token, source: [dynamic]^Token) -> [dynamic]^Token
{
	result := make([dynamic]^Token, 0, len(source), source.allocator)
	for token in source
	{
		copy := new_clone(token^)
		switch token.type
		{
			case .Id:
			{
				name := token.source
				replacement_ptr := &map_[name]
				if replacement_ptr != nil
				{
					copy^ = replacement_ptr^^
				}
			}
			case .Integer, .Operator, .String:
			{
				// Nothing to do
			}
			case .Square, .Paren, .Curly, .Module:
			{
				copy.children = token_apply_macro_replacements(map_, token.children)
			}
			case .Value, .Lazy_Function_Definition:
			{
				assert(false, "Not reached")
			}
		}
		append(&result, copy)
	}
	return result
}

token_rewrite_macro_match :: proc(state: ^Token_Matcher_State, macro: ^Macro, match: [dynamic]^Token)
{
	assert(len(macro.pattern_names) == len(match), "Pattern names and matched tokens did not have the same length")
	map_ := make(map[string]^Token, 16, runtime.default_allocator())
	for name, i in macro.pattern_names
	{
		if name != ""
		{
			map_[name] = match[i]
		}
	}
	// TODO do capture expansion
	token_replace_length_with_tokens(state,
	                                 len(macro.pattern),
	                                 token_apply_macro_replacements(map_, macro.replacement))
	// delete(match)
	delete(map_)
}

token_rewrite_macros :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder)
{
	for scope := scope; scope != nil; scope = scope.parent
	{
		for macro in scope.macros
		{
			retry: for
			{
				for i := 0; i < len(state.tokens); i += 1
				{
					state.start_index = i
					match := token_match_pattern(state, macro.pattern)
					if match != nil
					{
						token_rewrite_macro_match(state, macro, match)
						continue retry
					}
				}
				break
			}
		}
	}
}

token_match_argument :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> ^Token_Match_Arg
{
	peek_index := 0
	
	arg_id   := Token_Match(state, &peek_index, &Token{type = .Id}); if arg_id   == nil do return nil
	colon    := Token_Match_Operator(state, &peek_index, ":");       if colon    == nil do return nil
	arg_type := Token_Match(state, &peek_index, &Token{});           if arg_type == nil do return nil
	Token_Match_End(state, peek_index)
	
	return new_clone(Token_Match_Arg \
	{
		arg_name        = arg_id.source,
		type_descriptor = token_force_type(scope, arg_type),
	})
}

token_string_to_string :: proc(token: ^Token) -> string
{
	assert(token.type == .String, "Token was not a string")
	assert(len(token.source) >= 2, "String does not have quotation marks")
	return token.source[1:len(token.source) - 1]
}

token_force_value :: proc(token: ^Token, scope: ^Scope, builder: ^Function_Builder, loc := #caller_location) -> ^Value
{
	result_value: ^Value
	if token.type == .Integer
	{
		value, ok := strconv.parse_int(token.source)
		assert(ok, "Could not parse expression as int", loc)
		// FIXME We should be able to size immediates automatically
		result_value = value_from_signed_immediate(value)
	}
	else if token.type == .String
	{
		string_ := token_string_to_string(token)
		result_value = value_pointer_to(builder, value_global_c_string(builder.program, string_))
	}
	else if token.type == .Id
	{
		result_value = scope_lookup_force(scope, token.source, builder, loc)
	}
	else if token.type == .Value
	{
		return token.value
	}
	else if token.type == .Lazy_Function_Definition
	{
		return token_force_lazy_function_definition(&token.lazy_function_definition)
	}
	else if token.type == .Paren
	{
		assert(builder != nil, "Parens forced to value without builder")
		state: Token_Matcher_State = {tokens = &token.children}
		return token_match_expression(&state, scope, builder)
	}
	else if token.type == .Curly
	{
		assert(builder != nil, "Curly forced to value without builder")
		return token_parse_block(token, scope, builder)
	}
	else
	{
		assert(false, fmt.tprintf("Not implemented: %v", token.type), loc)
	}
	assert(result_value != nil, fmt.tprintf("Token could not be forced into value: %q", token.source), loc)
	return result_value
}

token_match_call_arguments :: proc(token: ^Token, scope: ^Scope, builder: ^Function_Builder) -> [dynamic]^Value
{
	result := make([dynamic]^Value, 0, 16)
	if len(token.children) != 0
	{
		argument_states := token_split(&token.children, &Token{type = .Operator, source = ","})
		
		for state, i in &argument_states
		{
			value := token_match_expression(&state, scope, builder)
			append(&result, value)
		}
	}
	return result
}

token_value_make :: proc(original: ^Token, result: ^Value, source_tokens: ..^Token) -> ^Token
{
	return new_clone(Token \
	{
		type   = .Value,
		parent = original.parent,
		source = combine_token_sources(..source_tokens),
		data   = {value = result},
	})
}

token_replace_tokens_in_state :: proc(state: ^Token_Matcher_State, length: int, token: ^Token = nil)
{
	length := length
	
	from := state.start_index
	if token != nil
	{
		state.tokens[from] = token
		from += 1
		length -= 1
	}
	remove_range(state.tokens, from, from + length)
}

token_rewrite_functions_pattern_callback :: proc(match: [dynamic]^Token, scope: ^Scope, builder: ^Function_Builder) -> [dynamic]^Token
{
	args          := match[0]
	arrow         := match[1]
	return_types  := match[2]
	body          := match[3]
	
	result_token := new_clone(Token \
	{
		type   = .Lazy_Function_Definition,
		parent = arrow.parent,
		source = combine_token_sources(args, arrow, return_types, body),
		data   = {lazy_function_definition =
		{
			args         = args,
			return_types = return_types,
			body         = body,
			program      = builder.program,
		}},
	})
	
	return [dynamic]^Token \
	{
		result_token,
	}
}

scope_add_macro :: proc(scope: ^Scope, macro: ^Macro)
{
	append(&scope.macros, macro)
}

token_rewrite_functions :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	@static pattern: [dynamic]^Token
	if pattern == nil
	{
		@static token_array: [4]^Token
		pattern = mem.buffer_from_slice(token_array[:])
		
		@static args:         Token = {type = .Paren}
		@static arrow:        Token = {type = .Operator, source = "->"}
		@static return_types: Token = {type = .Paren}
		@static body:         Token = {}
		
		append(&pattern, &args, &arrow, &return_types, &body)
	}
	
	return token_rewrite_pattern(state, scope, builder, pattern, token_rewrite_functions_pattern_callback)
}

token_rewrite_macro_definitions :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	keyword           := Token_Match(state, &peek_index, &Token{type = .Id, source = "macro"}); if keyword           == nil do return false
	pattern_token     := Token_Match(state, &peek_index, &Token{type = .Paren});                if pattern_token     == nil do return false
	replacement_token := Token_Match(state, &peek_index, &Token{type = .Paren});                if replacement_token == nil do return false
	token_replace_tokens_in_state(state, 3)
	
	pattern       := make([dynamic]^Token, 0, 16)
	pattern_names := make([dynamic]string, 0, 16)
	
	for token, i in pattern_token.children
	{
		if token.type == .Id && strings.has_prefix(token.source, "_")
		{
			name := token.source[1:]
			append(&pattern_names, name)
			item := new(Token)
			append(&pattern, item)
		}
		else
		{
			append(&pattern_names, "")
			append(&pattern, token)
		}
	}
	
	macro := new_clone(Macro \
	{
		pattern       = pattern,
		pattern_names = pattern_names,
		replacement   = replacement_token.children,
	})
	
	scope_add_macro(scope, macro)
	
	return true
}

token_rewrite_constant_definitions :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	name   := Token_Match(state, &peek_index, &Token{type = .Id}); if name   == nil do return false
	define := Token_Match_Operator(state, &peek_index, "::");      if define == nil do return false
	value  := Token_Match(state, &peek_index, &Token{});           if value  == nil do return false
	scope_define_lazy(scope, name.source, value)
	
	// FIXME definition should rewrite with a token so that we can do proper
	// checking inside statements and maybe pass it around.
	token_replace_tokens_in_state(state, 3)
	return true
}

token_parse_block :: proc(block: ^Token, scope: ^Scope, builder: ^Function_Builder) -> ^Value
{
	// TODO push an extra scope
	assert(block.type == .Curly, "Block was not inside curly braces")
	block_result: ^Value
	if len(block.children) != 0
	{
		block_statements := token_split(&block.children, &Token{type = .Operator, source = ";"})
		
		for state in &block_statements
		{
			block_result = token_match_expression(&state, scope, builder)
		}
	}
	
	return block_result
}

token_rewrite_statement_if :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	keyword   := Token_Match(state, &peek_index, &Token{type = .Id, source = "if"}); if keyword   == nil do return false
	condition := Token_Match(state, &peek_index, &Token{type = .Paren});             if condition == nil do return false
	body      := Token_Match(state, &peek_index, &Token{type = .Curly});             if body      == nil do return false
	Token_Match_End(state, peek_index)
	
	if If(token_force_value(condition, scope, builder)) {
		token_parse_block(body, scope, builder)
	End_If()}
	
	token_replace_tokens_in_state(state, 3)
	return true
}

token_rewrite_goto :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	keyword    := Token_Match(state, &peek_index, &Token{type = .Id, source = "goto"}); if keyword    == nil do return false
	label_name := Token_Match(state, &peek_index, &Token{type = .Id});                  if label_name == nil do return false
	Token_Match_End(state, peek_index)
	value := scope_lookup_force(scope, label_name.source, builder)
	assert(value.descriptor.type == .Void, "Label name in goto did not resolve to type Void")
	assert(value.operand.type == .Label_32, "Label name in goto did not reslove to a label")
	
	goto(builder, value.operand.label32)
	
	token_replace_tokens_in_state(state, 2)
	return true
}

token_rewrite_explicit_return :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	keyword   := Token_Match(state, &peek_index, &Token{type = .Id, source = "return"}); if keyword   == nil do return false
	to_return := Token_Match(state, &peek_index, &Token{});                              if to_return == nil do return false
	Token_Match_End(state, peek_index)
	result := token_force_value(to_return, scope, builder)
	Return(result)
	
	token_replace_tokens_in_state(state, 2)
	return true
}

token_rewrite_negative_literal :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	// FIXME distinguish unary and binary minus
	minus   := Token_Match_Operator(state, &peek_index, "-");            if minus   == nil do return false
	integer := Token_Match(state, &peek_index, &Token{type = .Integer}); if integer == nil do return false
	result := token_force_value(integer, scope, builder)
	if result.operand.type == .Immediate_8
	{
		result.operand.imm8 = -result.operand.imm8
	}
	else if result.operand.type == .Immediate_32
	{
		result.operand.imm32 = -result.operand.imm32
	}
	else if result.operand.type == .Immediate_64
	{
		result.operand.imm64 = -result.operand.imm64
	}
	else
	{
		assert(false, "Internal error, expected an immediate")
	}
	
	token_replace_tokens_in_state(state, 2, token_value_make(integer, result, minus, integer))
	return true
}

token_rewrite_pointer_to :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	and         := Token_Match_Operator(state, &peek_index, "&"); if and         == nil do return false
	value_token := Token_Match(state, &peek_index, &Token{});     if value_token == nil do return false
	
	result := value_pointer_to(builder, token_force_value(value_token, scope, builder))
	token_replace_tokens_in_state(state, 2, token_value_make(value_token, result, and, value_token))
	return true
}

token_rewrite_set_array_item :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	id         := Token_Match(state, &peek_index, &Token{type = .Id, source = "set_array_item"}); if id         == nil do return false
	args_token := Token_Match(state, &peek_index, &Token{type = .Paren});                         if args_token == nil do return false
	
	args := token_match_call_arguments(args_token, scope, builder)
	assert(len(args) == 3, "set_array_item takes exactly 3 arguments")
	array       := args[0]
	index_value := args[1]
	value       := args[2]
	
	assert(array.descriptor.type == .Fixed_Size_Array, "Wrong descriptor type in set_array_item")
	assert(array.operand.type == .Memory_Indirect, "Wrong operand type in set_array_item")
	
	item_descriptor := array.descriptor.array.item
	item_byte_size := descriptor_byte_size(item_descriptor)
	
	if false && operand_is_immediate(&index_value.operand)
	{
		index := i32(operand_immediate_as_i64(&index_value.operand))
		
		target_value := new_clone(Value \
		{
			descriptor = item_descriptor,
			operand =
			{
				type      = .Memory_Indirect,
				byte_size = item_byte_size,
				data      = {indirect = {
					reg          = array.operand.indirect.reg,
					displacement = array.operand.indirect.displacement + i32(index) * item_byte_size,
				}},
			},
		})
		
		move_value(builder, target_value, value)
	}
	else if item_byte_size == 1 || item_byte_size == 2 || item_byte_size == 4 || item_byte_size == 8
	{
		scale := SIB_Scale_1
		if      item_byte_size == 2 do scale = SIB_Scale_2
		else if item_byte_size == 4 do scale = SIB_Scale_4
		else if item_byte_size == 8 do scale = SIB_Scale_8
		index_value_in_register := ensure_register(builder, index_value, .R10)
		target_value := new_clone(Value \
		{
			descriptor = item_descriptor,
			operand =
			{
				type      = .Sib,
				byte_size = item_byte_size,
				data      = {sib = {
					scale        = scale,
					index        = index_value_in_register.operand.reg,
					base         = array.operand.indirect.reg,
					displacement = array.operand.indirect.displacement,
				}},
			},
		})
		
		move_value(builder, target_value, value)
	}
	else
	{
		assert(false, "Not implemented")
	}
	
	token_replace_tokens_in_state(state, 2)
	return true
}

token_match_label :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> ^Label
{
	peek_index := 0
	keyword := Token_Match(state, &peek_index, &Token{type = .Id, source = "label"}); if keyword == nil do return nil
	Token_Match_End(state, peek_index)
	
	return make_label()
}

token_match_fixed_array_type :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> ^Descriptor
{
	peek_index := 0
	type         := Token_Match(state, &peek_index, &Token{type = .Id});     if type         == nil do return nil
	square_brace := Token_Match(state, &peek_index, &Token{type = .Square}); if square_brace == nil do return nil
	
	descriptor := scope_lookup_type(scope, type.source)
	
	size_state: Token_Matcher_State = {tokens = &square_brace.children}
	size_value := token_match_expression(&size_state, scope, builder)
	assert(size_value.descriptor.type == .Integer, "Array size did not evaluate to an integer")
	assert(operand_is_immediate(&size_value.operand), "Array size did not evaluate to an immediate")
	length := i32(operand_immediate_as_i64(&size_value.operand))
	
	// TODO extract into a helper
	array_descriptor := new_clone(Descriptor \
	{
		type = .Fixed_Size_Array,
		data = {array =
		{
			item = descriptor,
			length = length,
		}},
	})
	return array_descriptor
}

token_rewrite_definitions :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	name   := Token_Match(state, &peek_index, &Token{type = .Id}); if name   == nil do return false
	define := Token_Match_Operator(state, &peek_index, ":");       if define == nil do return false
	
	rest_slice := state.tokens[state.start_index + peek_index:]
	rest := mem.buffer_from_slice(rest_slice)
	resize(&rest, len(rest_slice))
	rest_state: Token_Matcher_State = {tokens = &rest}
	resize(state.tokens, state.start_index)
	
	label := token_match_label(&rest_state, scope, builder)
	if label != nil
	{
		label_(builder, label)
		value := new_clone(Value \
		{
			descriptor = &descriptor_void,
			operand = label32(label),
		})
		scope_define_value(scope, name.source, value)
		return true
	}
	
	descriptor := token_match_fixed_array_type(&rest_state, scope, builder)
	if descriptor == nil
	{
		assert(len(rest) == 1, fmt.tprintf("Non-array type was not a single token: %v", rest))
		type := rest[0]
		assert(type.type == .Id, "Non-array type was not an identifier")
		descriptor = scope_lookup_type(scope, type.source)
	}
	
	value := reserve_stack(builder, descriptor)
	scope_define_value(scope, name.source, value)
	
	return true
}

token_rewrite_definition_and_assignment_statements :: proc(state: ^Token_Matcher_State, scope: ^Scope,
                                                           builder: ^Function_Builder) -> bool
{
	peek_index := 0
	name        := Token_Match(state, &peek_index, &Token{type = .Id}); if name        == nil do return false
	define      := Token_Match_Operator(state, &peek_index, ":=");      if define      == nil do return false
	token_value := Token_Match(state, &peek_index, &Token{});           if token_value == nil do return false
	
	value := token_force_value(token_value, scope, builder)
	var := Stack(value.descriptor, value)
	scope_define_value(scope, name.source, var)
	
	// FIXME definition should rewrite with a token so that we can do proper
	// checking inside statements and maybe pass it around.
	token_replace_tokens_in_state(state, 3)
	return true
}

token_rewrite_assignments :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	name        := Token_Match(state, &peek_index, &Token{type = .Id}); if name        == nil do return false
	define      := Token_Match_Operator(state, &peek_index, "=");       if define      == nil do return false
	token_value := Token_Match(state, &peek_index, &Token{});           if token_value == nil do return false
	
	value  := token_force_value(token_value, scope, builder)
	target := scope_lookup_force(scope, name.source, builder)
	Assign(target, value)
	
	// FIXME definition should rewrite with a token so that we can do proper
	// checking inside statements and maybe pass it around.
	token_replace_tokens_in_state(state, 3)
	return true
}

token_import_match_arguments :: proc(paren: ^Token, program: ^Program) -> ^Token
{
	assert(paren.type == .Paren, "Import arguments were not in parentheses")
	state := &Token_Matcher_State{tokens = &paren.children}
	
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

token_rewrite_dll_imports :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	name := Token_Match(state, &peek_index, &Token{type = .Id, source = "import"}); if name == nil do return false
	args := Token_Match(state, &peek_index, &Token{type = .Paren});                 if args == nil do return false
	result_token := token_import_match_arguments(args, builder.program)
	
	token_replace_tokens_in_state(state, 2, result_token)
	return true
}

token_rewrite_function_calls :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	target_token := Token_Match(state, &peek_index, &Token{});              if target_token == nil do return false
	args_token   := Token_Match(state, &peek_index, &Token{type = .Paren}); if args_token   == nil do return false
	if target_token.type != .Id && target_token.type != .Paren do return false
	
	target := token_force_value(target_token, scope, builder)
	args   := token_match_call_arguments(args_token, scope, builder)
	
	return_value := call_function_value(builder, target, ..args[:])
	
	token_replace_tokens_in_state(state, 2, token_value_make(args_token, return_value, target_token, args_token))
	return true
}

token_rewrite_plus :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	lhs        := Token_Match(state, &peek_index, &Token{});     if lhs        == nil do return false
	plus_token := Token_Match_Operator(state, &peek_index, "+"); if plus_token == nil do return false
	rhs        := Token_Match(state, &peek_index, &Token{});     if rhs        == nil do return false
	
	value := plus(builder,
	              token_force_value(lhs, scope, builder),
	              token_force_value(rhs, scope, builder))
	token_replace_tokens_in_state(state, 3, token_value_make(plus_token, value, lhs, plus_token, rhs))
	return true
}

token_rewrite_less_than :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	lhs        := Token_Match(state, &peek_index, &Token{});     if lhs        == nil do return false
	less_token := Token_Match_Operator(state, &peek_index, "<"); if less_token == nil do return false
	rhs        := Token_Match(state, &peek_index, &Token{});     if rhs        == nil do return false
	
	value := compare(builder, .Less,
	                 token_force_value(lhs, scope, builder),
	                 token_force_value(rhs, scope, builder))
	token_replace_tokens_in_state(state, 3, token_value_make(less_token, value, lhs, less_token, rhs))
	return true
}

token_rewrite_greater_than :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> bool
{
	peek_index := 0
	lhs           := Token_Match(state, &peek_index, &Token{});     if lhs           == nil do return false
	greater_token := Token_Match_Operator(state, &peek_index, ">"); if greater_token == nil do return false
	rhs           := Token_Match(state, &peek_index, &Token{});     if rhs           == nil do return false
	
	value := compare(builder, .Greater,
	                 token_force_value(lhs, scope, builder),
	                 token_force_value(rhs, scope, builder))
	token_replace_tokens_in_state(state, 3, token_value_make(greater_token, value, lhs, greater_token, rhs))
	return true
}

token_rewrite_expression_callback :: #type proc(^Token_Matcher_State, ^Scope, ^Function_Builder) -> bool

token_rewrite_expression :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder,
                                 callback: token_rewrite_expression_callback)
{
	retry: for
	{
		for i := 0; i < len(state.tokens); i += 1
		{
			state.start_index = i
			if callback(state, scope, builder) do continue retry
		}
		break
	}
}

token_match_expression :: proc(state: ^Token_Matcher_State, scope: ^Scope, builder: ^Function_Builder) -> ^Value
{
	if len(state.tokens) == 0 do return nil
	
	token_rewrite_macros(state, scope, builder)
	token_rewrite_expression(state, scope, builder, token_rewrite_statement_if)
	token_rewrite_expression(state, scope, builder, token_rewrite_definitions)
	token_rewrite_expression(state, scope, builder, token_rewrite_set_array_item)
	
	token_rewrite_expression(state, scope, builder, token_rewrite_functions)
	token_rewrite_expression(state, scope, builder, token_rewrite_negative_literal)
	token_rewrite_expression(state, scope, builder, token_rewrite_function_calls)
	token_rewrite_expression(state, scope, builder, token_rewrite_pointer_to)
	token_rewrite_expression(state, scope, builder, token_rewrite_plus)
	token_rewrite_expression(state, scope, builder, token_rewrite_less_than)
	token_rewrite_expression(state, scope, builder, token_rewrite_greater_than)
	
	switch len(state.tokens)
	{
		case 0: return &void_value
		case 1: return token_force_value(state.tokens[0], scope, builder)
		case:
		{
			// Statement handling
			token_rewrite_expression(state, scope, builder, token_rewrite_definition_and_assignment_statements)
			token_rewrite_expression(state, scope, builder, token_rewrite_assignments)
			token_rewrite_expression(state, scope, builder, token_rewrite_explicit_return)
			token_rewrite_expression(state, scope, builder, token_rewrite_goto)
			token_rewrite_expression(state, scope, builder, token_rewrite_constant_definitions)
			if len(state.tokens) != 0
			{
				assert(false, fmt.tprintf("Could not reduce an expression: %q", combine_token_sources(..state.tokens[:])))
			}
			return nil
		}
	}
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
			argument_states := token_split(&args.children, &Token{type = .Operator, source = ","})
			
			for state, i in &argument_states
			{
				arg := token_match_argument(&state, function_scope, builder)
				assert(arg != nil, "Ill-formed function argument declaration")
				arg_value := Arg(arg.type_descriptor)
				scope_define_value(function_scope, arg.arg_name, arg_value)
			}
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
				fn_return_descriptor(builder, token_force_type(function_scope, return_type_token), .Explicit)
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
			body_result := token_parse_block(body, function_scope, builder)
			if body_result != nil
			{
				fn_return(builder, body_result, .Implicit)
			}
		}
	}
	End_Function()
	
	return value
}

token_match_module :: proc(token: ^Token, program: ^Program)
{
	assert(token.type == .Module, "Token was not a module")
	if len(token.children) == 0 do return
	
	state := &Token_Matcher_State{tokens = &token.children}
	global_builder: Function_Builder = {program = program}
	
	token_rewrite_expression(state, program.global_scope, &global_builder, token_rewrite_macro_definitions)
	token_rewrite_expression(state, program.global_scope, &global_builder, token_rewrite_dll_imports)
	token_rewrite_expression(state, program.global_scope, &global_builder, token_rewrite_functions)
	token_rewrite_expression(state, program.global_scope, &global_builder, token_rewrite_constant_definitions)
	
	assert(len(token.children) == 0, "Unable to parse entire module")
}

program_import_file_internal :: proc(program: ^Program, file_path: string) -> bool
{
	file_handle := win32.create_file_w(win32.utf8_to_wstring(file_path),
	                                   win32.FILE_GENERIC_READ,
	                                   win32.FILE_SHARE_READ,
	                                   nil,
	                                   win32.OPEN_EXISTING,
	                                   win32.FILE_ATTRIBUTE_NORMAL,
	                                   nil)
	if file_handle == win32.INVALID_HANDLE
	{
		fmt.printf("Could not open file %q\n", file_path)
		return false
	}
	
	buffer_size: i64
	win32.get_file_size_ex(file_handle, &buffer_size)
	buffer := make_buffer(int(buffer_size), PAGE_READWRITE)
	bytes_read: i32
	is_success := win32.read_file(file_handle, &buffer.memory[0], u32(buffer_size), &bytes_read, nil)
	win32.close_handle(file_handle)
	file_handle = nil
	if !is_success
	{
		fmt.printf("Could not read file %q\n", file_path)
		return false
	}
	buffer.occupied = int(bytes_read)
	
	source := string(buffer.memory)
	
	result := tokenize(file_path, source)
	if result.type != .Success
	{
		for error in &result.errors
		{
			print_message_with_location(error.message, &error.location)
		}
		return false
	}
	
	token_match_module(result.root, program)
	return true
}

program_import_file :: proc(program: ^Program, file_path: string) -> bool
{
	file_path := file_path
	if !strings.has_suffix(file_path, ".mass")
	{
		file_path = fmt.tprintf("%s.mass", file_path)
	}
	return program_import_file_internal(program, file_path)
}
