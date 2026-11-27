# frozen_string_literal: true

# (c) Copyright IBM Corp. 2016, 2018 All Rights Reserved
#   Project name: JSONata
#   This project is licensed under the MIT License, see LICENSE

# Port of jsonata-js src/parser.js
#
# AST nodes are represented as Hashes with Symbol keys. In jsonata-js, the nodes created by the
# Pratt parser inherit (via the prototype chain) from their entry in the symbol table; here that
# relationship is maintained in a separate identity map (see #symbol_of).

module Jsonata
  class Parser
    OPERATORS = {
      '.'   => 75,
      '['   => 80,
      ']'   => 0,
      '{'   => 70,
      '}'   => 0,
      '('   => 80,
      ')'   => 0,
      ','   => 0,
      '@'   => 80,
      '#'   => 80,
      ';'   => 80,
      ':'   => 80,
      '?'   => 20,
      '+'   => 50,
      '-'   => 50,
      '*'   => 60,
      '/'   => 60,
      '%'   => 60,
      '|'   => 20,
      '='   => 40,
      '<'   => 40,
      '>'   => 40,
      '^'   => 40,
      '**'  => 60,
      '..'  => 20,
      ':='  => 10,
      '!='  => 40,
      '<='  => 40,
      '>='  => 40,
      '~>'  => 40,
      '?:'  => 40,
      '??'  => 40,
      'and' => 30,
      'or'  => 25,
      'in'  => 40,
      '&'   => 50,
      '!'   => 0, # not an operator, but needed as a stop character for name tokens
      '~'   => 0 # not an operator, but needed as a stop character for name tokens
    }.freeze

    ESCAPES = { # JSON string escape sequences - see json.org
      '"'  => '"',
      '\\' => '\\',
      '/'  => '/',
      'b'  => "\b",
      'f'  => "\f",
      'n'  => "\n",
      'r'  => "\r",
      't'  => "\t"
    }.freeze

    # opening and closing delimiters of template strings
    TEMPLATE_DELIMITERS = {"«" => "»", '<<' => '>>'}.freeze

    WHITESPACE = " \t\n\r\v"

    # The value of a regex literal token
    RegexLiteral = Struct.new(:source, :flags) do
      def regexp
        @regexp ||= Utils.js_regexp(source, flags)
      end
    end

    # Tokenizer (lexer) - invoked by the parser to return one token at a time
    class Tokenizer
      def initialize(path)
        @path = path
        @position = 0
        @length = path.length
        @templates = []
      end

      def call(prefix = false)
        self.next(prefix)
      end

      def next(prefix = false)
        template = @templates.last
        if template && template[:depth].zero? && char_at(@position) != '{'
          # template text; a '{' falls through to be lexed as an operator, starting an embedded expression
          return next_template_token(template)
        end
        return nil if @position >= @length

        current_char = char_at(@position)
        # skip whitespace
        while @position < @length && WHITESPACE.include?(current_char)
          @position += 1
          current_char = char_at(@position)
        end
        # skip comments
        if current_char == '/' && char_at(@position + 1) == '*'
          comment_start = @position
          @position += 2
          current_char = char_at(@position)
          until current_char == '*' && char_at(@position + 1) == '/'
            @position += 1
            current_char = char_at(@position)
            if @position >= @length
              # no closing tag
              raise Jsonata::Error.new('S0106', :position => comment_start)
            end
          end
          @position += 2
          return self.next(prefix) # need this to swallow any following whitespace
        end
        # test for regex
        if prefix != true && current_char == '/'
          @position += 1
          return create('regex', scan_regex)
        end
        # test for the start of a template string: '«', or '<<' in prefix position
        # (in infix position '<' is the less-than operator, so "a"<<<b>> is "a" < <<b>>)
        open = if current_char == '<'
                 prefix == true ? '' : (@path[@position, 2] || '')
               else
                 current_char
               end
        if TEMPLATE_DELIMITERS.key?(open)
          @position += open.length
          @templates.push({:close => TEMPLATE_DELIMITERS[open], :depth => 0})
          return create('template', open)
        end
        # handle double-char operators
        two_chars = @path[@position, 2]
        if %w[.. := != >= <= ** ~> ?: ??].include?(two_chars)
          @position += 2
          return create('operator', two_chars)
        end
        # test for single char operators
        if OPERATORS.key?(current_char)
          @position += 1
          if template
            # track braces inside an embedded expression; the '}' that brings the depth
            # back to zero closes the expression and resumes the template text
            if current_char == '{'
              template[:depth] += 1
            elsif current_char == '}'
              template[:depth] -= 1
            end
          end
          return create('operator', current_char)
        end
        # test for string literals
        if current_char == '"' || current_char == "'"
          quote_type = current_char
          # double quoted string literal - find end of string
          @position += 1
          qstr = +''
          while @position < @length
            current_char = char_at(@position)
            if current_char == '\\' # escape sequence
              @position += 1
              qstr << scan_escape
            elsif current_char == quote_type
              @position += 1
              return create('string', qstr)
            else
              qstr << current_char
            end
            @position += 1
          end
          raise Jsonata::Error.new('S0101', :position => @position)
        end
        # test for numbers
        match = /\A-?(0|([1-9][0-9]*))(\.[0-9]+)?([Ee][-+]?[0-9]+)?/.match(@path[@position..])
        unless match.nil?
          num = Float(match[0])
          if !num.nan? && num.finite?
            @position += match[0].length
            return create('number', Utils.normalize_number(num))
          else
            raise Jsonata::Error.new('S0102', :position => @position, :token => match[0])
          end
        end
        # test for quoted names (backticks)
        if current_char == '`'
          # scan for closing quote
          @position += 1
          end_pos = @path.index('`', @position)
          unless end_pos.nil?
            name = @path[@position...end_pos]
            @position = end_pos + 1
            return create('name', name)
          end
          @position = @length
          raise Jsonata::Error.new('S0105', :position => @position)
        end
        # test for names
        i = @position
        loop do
          ch = char_at(i)
          if i == @length || WHITESPACE.include?(ch) || OPERATORS.key?(ch)
            if char_at(@position) == '$'
              # variable reference
              name = @path[(@position + 1)...i]
              @position = i
              return create('variable', name)
            else
              name = @path[@position...i]
              @position = i
              case name
              when 'or', 'in', 'and'
                return create('operator', name)
              when 'true'
                return create('value', true)
              when 'false'
                return create('value', false)
              when 'null'
                return create('value', NULL)
              else
                if @position == @length && name == ''
                  # whitespace at end of input
                  return nil
                end

                return create('name', name)
              end
            end
          else
            i += 1
          end
        end
      end

      private

      # equivalent of String.prototype.charAt
      def char_at(index)
        (index >= 0 && @path[index]) || ''
      end

      def create(type, value)
        {:type => type, :value => value, :position => @position}
      end

      def scan_regex
        # the prefix '/' will have been previously scanned. Find the end of the regex.
        # search for closing '/' ignoring any that are escaped, or within brackets
        start = @position
        depth = 0

        closing_slash = lambda do |position|
          if char_at(position) == '/' && depth.zero?
            backslash_count = 0
            backslash_count += 1 while char_at(position - (backslash_count + 1)) == '\\'
            return true if backslash_count.even?
          end
          false
        end

        while @position < @length
          current_char = char_at(@position)
          if closing_slash.call(@position)
            # end of regex found
            pattern = @path[start...@position]
            raise Jsonata::Error.new('S0301', :position => @position) if pattern == ''

            @position += 1
            current_char = char_at(@position)
            # flags
            start = @position
            while current_char == 'i' || current_char == 'm'
              @position += 1
              current_char = char_at(@position)
            end
            flags = "#{@path[start...@position]}g"
            return RegexLiteral.new(pattern, flags)
          end
          if (current_char == '(' || current_char == '[' || current_char == '{') && char_at(@position - 1) != '\\'
            depth += 1
          end
          if (current_char == ')' || current_char == ']' || current_char == '}') && char_at(@position - 1) != '\\'
            depth -= 1
          end

          @position += 1
        end
        raise Jsonata::Error.new('S0302', :position => @position)
      end

      # decode the escape sequence whose '\' has just been scanned; position is on the escaped character.
      # 'extra' lists additional characters that may be escaped as themselves
      def scan_escape(extra = nil)
        current_char = char_at(@position)
        return ESCAPES[current_char] if ESCAPES.key?(current_char)
        return current_char if current_char != '' && extra&.include?(current_char)

        if current_char == 'u'
          # \u should be followed by 4 hex digits
          octets = @path[@position + 1, 4] || ''
          if /\A[0-9a-fA-F]{4}\z/.match?(octets)
            @position += 4
            codepoint = octets.to_i(16)
            # Ruby strings cannot hold UTF-16 surrogate pairs, so combine them here (Ruby specific)
            low = @path[@position + 1, 6]
            if (0xD800..0xDBFF).cover?(codepoint) && low&.match?(/\A\\u[dD][c-fC-F][0-9a-fA-F]{2}\z/)
              codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low[2..].to_i(16) - 0xDC00)
              @position += 6
            end
            return Utils.from_char_code(codepoint)
          end
          raise Jsonata::Error.new('S0104', :position => @position)
        end
        # illegal escape sequence
        raise Jsonata::Error.new('S0103', :position => @position, :token => current_char)
      end

      # Template strings «...» and <<...>> are tokenized as:
      #   (template) [ (template-text) | '{' <tokens> '}' ]* (template-end)
      # The tokenizer keeps a stack with one entry per open template (they can nest inside {}).
      # Each entry counts the unmatched '{' in the current embedded expression; when it is
      # zero the tokenizer is scanning literal text, otherwise it is scanning JSONata tokens.
      # The count only changes where '{' and '}' are lexed as operators (see below), and the
      # '{' that starts an embedded expression is lexed that way too, taking the count to one.
      # Keeping this state here means every caller of the lexer (including remainingTokens)
      # gets the right tokens without having to know about templates.
      # Reaching the end of input inside template text is not an error here: the lexer returns
      # null like it does at the end of any expression, and the parser reports the unterminated
      # template (S0107), so that it can be recovered from in recover mode.
      TEMPLATE_ESCAPES = "{}<>«»"
      private_constant :TEMPLATE_ESCAPES

      def template_close?(template)
        # the first '>>' closes a <<...>> template, so '<<a>>>b' is '<<a>>' followed by '>'
        @path[@position, template[:close].length] == template[:close]
      end

      def next_template_token(template)
        return nil if @position >= @length

        if template_close?(template)
          @position += template[:close].length
          @templates.pop
          return create('template-end', template[:close])
        end
        # literal text up to the next unescaped '{' or the closing delimiter
        text = +''
        while @position < @length && char_at(@position) != '{' && !template_close?(template)
          current_char = char_at(@position)
          if current_char == '\\'
            @position += 1
            text << scan_escape(TEMPLATE_ESCAPES)
          elsif current_char == '}'
            # a literal '}' must be escaped, so that a stray brace is reported rather than kept as text
            raise Jsonata::Error.new('S0108', :position => @position + 1, :token => current_char)
          else
            text << current_char
          end
          @position += 1
        end
        create('template-text', text)
      end
    end

    # An entry in the symbol table
    Sym = Struct.new(:id, :value, :lbp, :nud, :led)

    # This parser implements the 'Top down operator precedence' algorithm developed by Vaughan R Pratt; http://dl.acm.org/citation.cfm?id=512931.
    # and builds on the Javascript framework described by Douglas Crockford at http://javascript.crockford.com/tdop/tdop.html
    # and in 'Beautiful Code', edited by Andy Oram and Greg Wilson, Copyright 2007 O'Reilly Media, Inc. 798-0-596-51004-6
    def self.parse(source, recover = false)
      new(source, recover).parse
    end

    def initialize(source, recover = false)
      @source = source
      @recover = recover
      @node = nil
      @lexer = nil
      @symbol_table = {}
      @node_symbols = {}.compare_by_identity
      @errors = []
      @ancestor_label = 0
      @ancestor_index = 0
      @ancestry = []
      define_symbols
    end

    def parse
      # now invoke the tokenizer and the parser and return the syntax tree
      @lexer = Tokenizer.new(@source)
      advance
      # parse the tokens
      expr = expression(0)
      if node_id(@node) != '(end)'
        err = Jsonata::Error.new('S0201', :position => @node[:position], :token => @node[:value])
        handle_error(err)
      end
      expr = process_ast(expr)

      if expr[:type] == 'parent' || expr.key?(:seeking_parent)
        # error - trying to derive ancestor at top level
        raise Jsonata::Error.new('S0217', :token => expr[:type], :position => expr[:position])
      end

      expr[:errors] = @errors unless @errors.empty?

      expr
    end

    private

    def symbol_of(node)
      @node_symbols[node]
    end

    def node_id(node)
      symbol_of(node)&.id
    end

    def node_lbp(node)
      symbol_of(node)&.lbp || 0
    end

    def remaining_tokens
      remaining = []
      if node_id(@node) != '(end)'
        remaining.push({:type => @node[:type], :value => @node[:value], :position => @node[:position]})
      end
      nxt = @lexer.call
      until nxt.nil?
        remaining.push(nxt)
        nxt = @lexer.call
      end
      remaining
    end

    def base_nud
      lambda do |this|
        # error - symbol has been invoked as a unary operator
        err = Jsonata::Error.new('S0211', :token => this[:value], :position => this[:position])

        raise err unless @recover

        err.remaining = remaining_tokens
        @errors.push(err)
        {:type => 'error', :error => err, :code => err.code, :token => err.token, :position => err.position, :remaining => err.remaining}
      end
    end

    def symbol(id, bp = 0)
      s = @symbol_table[id]
      bp ||= 0
      if s
        s.lbp = bp if bp >= s.lbp
      else
        s = Sym.new(id, id, bp, base_nud, nil)
        @symbol_table[id] = s
      end
      s
    end

    def handle_error(err)
      raise err unless @recover

      # tokenize the rest of the buffer and add it to an error token
      err.remaining = remaining_tokens
      @errors.push(err)
      sym = @symbol_table['(error)']
      @node = {:value => sym.value, :error => err, :type => '(error)'}
      @node_symbols[@node] = sym
      @node
    end

    def advance(id = nil, infix = false)
      if id && node_id(@node) != id
        code = if node_id(@node) == '(end)'
                 # unexpected end of buffer
                 'S0203'
               else
                 'S0202'
               end
        err = Jsonata::Error.new(code, :position => @node[:position], :token => @node[:value], :value => id)
        return handle_error(err)
      end
      next_token = @lexer.call(infix)
      if next_token.nil?
        @node = @end_node
        @node[:position] = @source.length
        return @node
      end
      value = next_token[:value]
      type = next_token[:type]
      case type
      when 'name', 'variable'
        sym = @symbol_table['(name)']
      when 'operator'
        sym = @symbol_table[value]
        unless sym
          return handle_error(Jsonata::Error.new('S0204', :position => next_token[:position], :token => value))
        end
      when 'string', 'number', 'value'
        sym = @symbol_table['(literal)']
      when 'regex'
        type = 'regex'
        sym = @symbol_table['(regex)']
      when 'template', 'template-text', 'template-end'
        sym = @symbol_table["(#{type})"]
      else
        return handle_error(Jsonata::Error.new('S0205', :position => next_token[:position], :token => value))
      end

      @node = {:value => value, :type => type, :position => next_token[:position]}
      @node_symbols[@node] = sym
      @node
    end

    # prefix operators whose nud parses an operand, so the token after them is in prefix position
    STARTS_OPERAND = {'-' => true, '(' => true, '[' => true, '{' => true, '|' => true}.freeze
    private_constant :STARTS_OPERAND

    # Pratt's algorithm
    def expression(rbp)
      t = @node
      advance(nil, !(t[:type] == 'operator' && STARTS_OPERAND[t[:value]]))
      left = symbol_of(t).nud.call(t)
      while rbp < node_lbp(@node)
        t = @node
        advance
        left = symbol_of(t).led.call(t, left)
      end
      left
    end

    def terminal(id)
      s = symbol(id, 0)
      s.nud = ->(this) { this }
    end

    # match infix operators
    # <expression> <operator> <expression>
    # left associative
    def infix(id, bp = nil, &led)
      binding_power = bp || OPERATORS[id]
      s = symbol(id, binding_power)
      s.led = led || lambda do |this, left|
        this[:lhs] = left
        this[:rhs] = expression(binding_power)
        this[:type] = 'binary'
        this
      end
      s
    end

    # match infix operators
    # <expression> <operator> <expression>
    # right associative
    def infixr(id, bp, &led)
      s = symbol(id, bp)
      s.led = led
      s
    end

    # match prefix operators
    # <operator> <expression>
    def prefix(id, &nud)
      s = symbol(id)
      s.nud = nud || lambda do |this|
        this[:expression] = expression(70)
        this[:type] = 'unary'
        this
      end
      s
    end

    def deep_clone(obj)
      case obj
      when Hash then obj.to_h { |k, v| [k, deep_clone(v)] }
      when Array then obj.map { |v| deep_clone(v) }
      else obj
      end
    end

    def define_symbols
      terminal('(end)')
      @end_node = {:value => '(end)'}
      @node_symbols[@end_node] = @symbol_table['(end)']
      terminal('(name)')
      terminal('(literal)')
      terminal('(regex)')
      symbol(':')
      symbol(';')
      symbol(',')
      symbol(')')
      symbol(']')
      symbol('}')
      symbol('..') # range operator
      symbol('(template-text)') # only valid inside a template string
      symbol('(template-end)')
      infix('.') # map operator
      infix('+') # numeric addition
      infix('-') # numeric subtraction
      infix('*') # numeric multiplication
      infix('/') # numeric division
      infix('%') # numeric modulus
      infix('=') # equality
      infix('<') # less than
      infix('>') # greater than
      infix('!=') # not equal to
      infix('<=') # less than or equal
      infix('>=') # greater than or equal
      infix('&') # string concatenation
      infix('and') # Boolean AND
      infix('or') # Boolean OR
      infix('in') # is member of array
      terminal('and') # the 'keywords' can also be used as terminals (field names)
      terminal('or')
      terminal('in')
      prefix('-') # unary numeric negation
      infix('~>') # function application

      # coalescing operator
      infix('??', OPERATORS['??']) do |this, left|
        this[:type] = 'condition'
        this[:condition] = {
          :type      => 'function',
          :value     => '(',
          :procedure => {:type => 'variable', :value => 'exists'},
          :arguments => [deep_clone(left)]
        }
        this[:then] = left
        this[:else] = expression(0)
        this
      end

      # template string: «text {expr} text» or <<text {expr} text>>
      # produces a 'template' node whose parts are, in order, literal text (plain strings) and
      # embedded expressions ({expression, position}, where position is that of the opening '{')
      prefix('(template)') do |this|
        error_count = @errors.length
        this[:type] = 'template'
        this[:parts] = []
        # (jsonata-js: for (;;) with return statements; here each exit breaks out of the loop and returns this)
        loop do
          if node_id(@node) == '(template-text)'
            this[:parts].push(@node[:value])
            advance
          elsif node_id(@node) == '{'
            position = @node[:position]
            advance
            if node_id(@node) != '}' # empty {} contributes nothing
              this[:parts].push({:expression => expression(0), :position => position})
            end
            advance('}')
          elsif node_id(@node) == '(template-end)'
            advance(nil, true)
            break
          elsif node_id(@node) == '(end)' && @errors.length == error_count
            # the input ended inside the template text
            handle_error(Jsonata::Error.new('S0107', :position => @node[:position], :value => TEMPLATE_DELIMITERS[this[:value]]))
            break
          else
            # recover mode only: an error inside {} has already been recorded and the
            # remaining tokens consumed, so return what has been parsed so far
            break
          end
        end
        this
      end

      infixr('(error)', 10) do |this, left|
        this[:lhs] = left

        this[:error] = @node[:error]
        this[:remaining] = remaining_tokens
        this[:type] = 'error'
        this
      end

      # field wildcard (single level)
      prefix('*') do |this|
        this[:type] = 'wildcard'
        this
      end

      # descendant wildcard (multi-level)
      prefix('**') do |this|
        this[:type] = 'descendant'
        this
      end

      # parent operator
      prefix('%') do |this|
        this[:type] = 'parent'
        this
      end

      # function invocation
      infix('(', OPERATORS['(']) do |this, left|
        # left is is what we are trying to invoke
        this[:procedure] = left
        this[:type] = 'function'
        this[:arguments] = []
        if node_id(@node) != ')'
          loop do
            if @node[:type] == 'operator' && node_id(@node) == '?'
              # partial function application
              this[:type] = 'partial'
              this[:arguments].push(@node)
              advance('?')
            else
              this[:arguments].push(expression(0))
            end
            break if node_id(@node) != ','

            advance(',')
          end
        end
        advance(')', true)
        # if the name of the function is 'function' or lambda (U+03BB), then this is function definition (lambda function)
        if left[:type] == 'name' && (left[:value] == 'function' || left[:value] == "\u03BB")
          # all of the args must be VARIABLE tokens
          this[:arguments].each_with_index do |arg, index|
            next if arg[:type] == 'variable'

            handle_error(Jsonata::Error.new('S0208', :position => arg[:position], :token => arg[:value], :value => index + 1))
          end
          this[:type] = 'lambda'
          # is the next token a '<' - if so, parse the function signature
          if node_id(@node) == '<'
            sig_pos = @node[:position]
            depth = 1
            sig = +'<'
            while depth.positive? && node_id(@node) != '{' && node_id(@node) != '(end)'
              tok = advance
              if node_id(tok) == '>'
                depth -= 1
              elsif node_id(tok) == '<'
                depth += 1
              end
              sig << tok[:value].to_s
            end
            advance('>')
            begin
              this[:signature] = Signature.new(sig)
            rescue Jsonata::Error => e
              # insert the position into this error
              e.position = sig_pos + e.offset
              next handle_error(e)
            end
          end
          # parse the function body
          advance('{')
          this[:body] = expression(0)
          advance('}')
        end
        this
      end

      # parenthesis - block expression
      prefix('(') do |this|
        expressions = []
        while node_id(@node) != ')'
          expressions.push(expression(0))
          break if node_id(@node) != ';'

          advance(';')
        end
        advance(')', true)
        this[:type] = 'block'
        this[:expressions] = expressions
        this
      end

      # array constructor
      prefix('[') do |this|
        a = []
        if node_id(@node) != ']'
          loop do
            item = expression(0)
            if node_id(@node) == '..'
              # range operator
              range = {:type => 'binary', :value => '..', :position => @node[:position], :lhs => item}
              advance('..')
              range[:rhs] = expression(0)
              item = range
            end
            a.push(item)
            break if node_id(@node) != ','

            advance(',')
          end
        end
        advance(']', true)
        this[:expressions] = a
        this[:type] = 'unary'
        this
      end

      # filter - predicate or array index
      infix('[', OPERATORS['[']) do |this, left|
        if node_id(@node) == ']'
          # empty predicate means maintain singleton arrays in the output
          step = left
          step = step[:lhs] while step && step[:type] == 'binary' && step[:value] == '['
          step[:keep_array] = true
          advance(']')
          left
        else
          this[:lhs] = left
          this[:rhs] = expression(OPERATORS[']'])
          this[:type] = 'binary'
          advance(']', true)
          this
        end
      end

      # order-by
      infix('^', OPERATORS['^']) do |this, left|
        advance('(')
        terms = []
        loop do
          term = {
            :descending => false
          }
          if node_id(@node) == '<'
            # ascending sort
            advance('<')
          elsif node_id(@node) == '>'
            # descending sort
            term[:descending] = true
            advance('>')
          else
            # unspecified - default to ascending
          end
          term[:expression] = expression(0)
          terms.push(term)
          break if node_id(@node) != ','

          advance(',')
        end
        advance(')')
        this[:lhs] = left
        this[:rhs] = terms
        this[:type] = 'binary'
        this
      end

      object_parser = lambda do |this, left = nil|
        a = []
        if node_id(@node) != '}'
          loop do
            n = expression(0)
            advance(':')
            v = expression(0)
            a.push([n, v]) # holds an array of name/value expression pairs
            break if node_id(@node) != ','

            advance(',')
          end
        end
        advance('}', true)
        if left.nil?
          # NUD - unary prefix form
          this[:lhs] = a
          this[:type] = 'unary'
        else
          # LED - binary infix form
          this[:lhs] = left
          this[:rhs] = a
          this[:type] = 'binary'
        end
        this
      end

      # object constructor
      prefix('{', &object_parser)

      # object grouping
      infix('{', OPERATORS['{'], &object_parser)

      # bind variable
      infixr(':=', OPERATORS[':=']) do |this, left|
        if left[:type] != 'variable'
          next handle_error(Jsonata::Error.new('S0212', :position => left[:position], :token => left[:value]))
        end

        this[:lhs] = left
        this[:rhs] = expression(OPERATORS[':='] - 1) # subtract 1 from bindingPower for right associative operators
        this[:type] = 'binary'
        this
      end

      # focus variable bind
      infix('@', OPERATORS['@']) do |this, left|
        this[:lhs] = left
        this[:rhs] = expression(OPERATORS['@'])
        if this[:rhs][:type] != 'variable'
          next handle_error(Jsonata::Error.new('S0214', :position => this[:rhs][:position], :token => '@'))
        end

        this[:type] = 'binary'
        this
      end

      # index (position) variable bind
      infix('#', OPERATORS['#']) do |this, left|
        this[:lhs] = left
        this[:rhs] = expression(OPERATORS['#'])
        if this[:rhs][:type] != 'variable'
          next handle_error(Jsonata::Error.new('S0214', :position => this[:rhs][:position], :token => '#'))
        end

        this[:type] = 'binary'
        this
      end

      # if/then/else ternary operator ?:
      infix('?', OPERATORS['?']) do |this, left|
        this[:type] = 'condition'
        this[:condition] = left
        this[:then] = expression(0)
        if node_id(@node) == ':'
          # else condition
          advance(':')
          this[:else] = expression(0)
        end
        this
      end

      # elvis/default operator
      infix('?:', OPERATORS['?:']) do |this, left|
        this[:type] = 'condition'
        # Deep-clone `left` so the condition and then branches have
        # independent AST nodes. Sharing the same reference causes
        # post-parse processing (e.g. predicate stages, unary minus
        # folding on number literals) to mutate the same node twice,
        # producing wrong results (see #773 for the equivalent ?? fix).
        this[:condition] = deep_clone(left)
        this[:then] = left
        this[:else] = expression(0)
        this
      end

      # object transformer
      prefix('|') do |this|
        this[:type] = 'transform'
        this[:pattern] = expression(0)
        advance('|')
        this[:update] = expression(0)
        if node_id(@node) == ','
          advance(',')
          this[:delete] = expression(0)
        end
        advance('|')
        this
      end
    end

    # tail call optimization
    # this is invoked by the post parser to analyse lambda functions to see
    # if they make a tail call.  If so, it is replaced by a thunk which will
    # be invoked by the trampoline loop during function application.
    # This enables tail-recursive functions to be written without growing the stack
    def tail_call_optimize(expr)
      if expr[:type] == 'function' && !expr[:predicate]
        thunk = {:type => 'lambda', :thunk => true, :arguments => [], :position => expr[:position]}
        thunk[:body] = expr
        thunk
      elsif expr[:type] == 'condition'
        # analyse both branches
        expr[:then] = tail_call_optimize(expr[:then])
        expr[:else] = tail_call_optimize(expr[:else]) if expr.key?(:else)
        expr
      elsif expr[:type] == 'block'
        # only the last expression in the block
        length = expr[:expressions].length
        expr[:expressions][length - 1] = tail_call_optimize(expr[:expressions][length - 1]) if length.positive?
        expr
      else
        expr
      end
    end

    def seek_parent(node, slot)
      case node[:type]
      when 'name', 'wildcard'
        slot[:level] -= 1
        if slot[:level].zero?
          if node[:ancestor].nil?
            node[:ancestor] = slot
          else
            # reuse the existing label
            @ancestry[slot[:index]][:slot][:label] = node[:ancestor][:label]
            node[:ancestor] = slot
          end
          node[:tuple] = true
        end
      when 'parent'
        slot[:level] += 1
      when 'block'
        # look in last expression in the block
        unless node[:expressions].empty?
          node[:tuple] = true
          slot = seek_parent(node[:expressions][-1], slot)
        end
      when 'path'
        # last step in path
        node[:tuple] = true
        index = node[:steps].length - 1
        slot = seek_parent(node[:steps][index], slot)
        index -= 1
        while slot[:level].positive? && index >= 0
          # check previous steps
          slot = seek_parent(node[:steps][index], slot)
          index -= 1
        end
      else
        # error - can't derive ancestor
        raise Jsonata::Error.new('S0217', :token => node[:type], :position => node[:position])
      end
      slot
    end

    def push_ancestry(result, value)
      return unless value.key?(:seeking_parent) || value[:type] == 'parent'

      slots = value.key?(:seeking_parent) ? value[:seeking_parent] : []
      slots.push(value[:slot]) if value[:type] == 'parent'
      if result.key?(:seeking_parent)
        result[:seeking_parent].concat(slots)
      else
        result[:seeking_parent] = slots
      end
    end

    # add a processed expression to a block (expressions in parentheses)
    def block_expression(block, part)
      push_ancestry(block, part)
      block[:consarray] = true if part[:consarray] || (part[:type] == 'path' && part[:steps][0][:consarray])
      part
    end

    def resolve_ancestry(path)
      index = path[:steps].length - 1
      laststep = path[:steps][index]
      slots = laststep.key?(:seeking_parent) ? laststep[:seeking_parent] : []
      slots.push(laststep[:slot]) if laststep[:type] == 'parent'
      slots.each do |slot|
        index = path[:steps].length - 2
        while slot[:level].positive?
          if index.negative?
            if path.key?(:seeking_parent)
              path[:seeking_parent].push(slot)
            else
              path[:seeking_parent] = [slot]
            end
            break
          end
          # try previous step
          step = path[:steps][index]
          index -= 1
          # multiple contiguous steps that bind the focus should be skipped
          while index >= 0 && step[:focus] && path[:steps][index][:focus]
            step = path[:steps][index]
            index -= 1
          end
          slot = seek_parent(step, slot)
        end
      end
    end

    # post-parse stage
    # the purpose of this is to add as much semantic value to the parse tree as possible
    # in order to simplify the work of the evaluator.
    # This includes flattening the parts of the AST representing location paths,
    # converting them to arrays of steps which in turn may contain arrays of predicates.
    # following this, nodes containing '.' and '[' should be eliminated from the AST.
    def process_ast(expr)
      result = nil
      case expr[:type]
      when 'binary'
        case expr[:value]
        when '.'
          lstep = process_ast(expr[:lhs])

          if lstep[:type] == 'path' && lstep.key?(:group)
            # a reduce terminates its path, so the steps that follow it start a new path, as if
            # the grouped path was in parentheses - i.e. a{k:v}.x is the same as (a{k:v}).x
            block = {:type => 'block', :position => expr[:lhs][:position]}
            block[:expressions] = [block_expression(block, lstep)]
            result = {:type => 'path', :steps => [block]}
            # but unlike in parentheses, the parent references that the grouped path can't
            # resolve itself are passed on to be resolved by the enclosing expression
            push_ancestry(result, block)
          elsif lstep[:type] == 'path'
            result = lstep
          else
            result = {:type => 'path', :steps => [lstep]}
          end
          result[:seeking_parent] = [lstep[:slot]] if lstep[:type] == 'parent'
          rest = process_ast(expr[:rhs])
          if rest[:type] == 'path'
            result[:steps].concat(rest[:steps])
          else
            rest[:stages] = rest.delete(:predicate) if rest.key?(:predicate)
            result[:steps].push(rest)
          end
          # any steps within a path that are string literals, should be changed to 'name'
          result[:steps].select do |step|
            if step[:type] == 'number' || step[:type] == 'value'
              # don't allow steps to be numbers or the values true/false/null
              raise Jsonata::Error.new('S0213', :position => step[:position], :value => step[:value])
            end

            step[:type] == 'string'
          end.each do |lit|
            lit[:type] = 'name'
          end
          # any step that signals keeping a singleton array, should be flagged on the path
          result[:keep_singleton_array] = true if result[:steps].any? { |step| step[:keep_array] == true }
          # if first step is a path constructor, flag it for special handling
          firststep = result[:steps][0]
          firststep[:consarray] = true if firststep[:type] == 'unary' && firststep[:value] == '['
          # if the last step is an array constructor, flag it so it doesn't flatten
          laststep = result[:steps][-1]
          laststep[:consarray] = true if laststep[:type] == 'unary' && laststep[:value] == '['
          resolve_ancestry(result)
        when '['
          # predicated step
          # LHS is a step or a predicated step
          # RHS is the predicate expr
          result = process_ast(expr[:lhs])
          step = result
          type = :predicate
          if result[:type] == 'path'
            step = result[:steps][-1]
            type = :stages
          end
          raise Jsonata::Error.new('S0209', :position => expr[:position]) if step.key?(:group)

          step[type] = [] unless step.key?(type)
          predicate = process_ast(expr[:rhs])
          if predicate.key?(:seeking_parent)
            predicate[:seeking_parent].each do |slot|
              if slot[:level] == 1
                seek_parent(step, slot)
              else
                slot[:level] -= 1
              end
            end
            push_ancestry(step, predicate)
          end
          step[type].push({:type => 'filter', :expr => predicate, :position => expr[:position]})
        when '{'
          # group-by
          # LHS is a step or a predicated step
          # RHS is the object constructor expr
          result = process_ast(expr[:lhs])
          raise Jsonata::Error.new('S0210', :position => expr[:position]) if result.key?(:group)

          # object constructor - process each pair
          result[:group] = {
            :lhs      => expr[:rhs].map { |pair| [process_ast(pair[0]), process_ast(pair[1])] },
            :position => expr[:position]
          }
        when '^'
          # order-by
          # LHS is the array to be ordered
          # RHS defines the terms
          result = process_ast(expr[:lhs])
          result = {:type => 'path', :steps => [result]} if result[:type] != 'path'
          sort_step = {:type => 'sort', :position => expr[:position]}
          sort_step[:terms] = expr[:rhs].map do |terms|
            expression = process_ast(terms[:expression])
            push_ancestry(sort_step, expression)
            {
              :descending => terms[:descending],
              :expression => expression
            }
          end
          result[:steps].push(sort_step)
          resolve_ancestry(result)
        when ':='
          result = {:type => 'bind', :value => expr[:value], :position => expr[:position]}
          result[:lhs] = process_ast(expr[:lhs])
          result[:rhs] = process_ast(expr[:rhs])
          push_ancestry(result, result[:rhs])
        when '@'
          result = process_ast(expr[:lhs])
          step = result
          step = result[:steps][-1] if result[:type] == 'path'
          # throw error if there are any predicates defined at this point
          # at this point the only type of stages can be predicates
          if step.key?(:stages) || step.key?(:predicate)
            raise Jsonata::Error.new('S0215', :position => expr[:position])
          end
          # also throw if this is applied after an 'order-by' clause
          raise Jsonata::Error.new('S0216', :position => expr[:position]) if step[:type] == 'sort'

          step[:keep_array] = true if expr[:keep_array]
          step[:focus] = expr[:rhs][:value]
          step[:tuple] = true
        when '#'
          result = process_ast(expr[:lhs])
          step = result
          if result[:type] == 'path'
            step = result[:steps][-1]
          else
            result = {:type => 'path', :steps => [result]}
            step[:stages] = step.delete(:predicate) if step.key?(:predicate)
          end
          if step.key?(:stages)
            step[:stages].push({:type => 'index', :value => expr[:rhs][:value], :position => expr[:position]})
          else
            step[:index] = expr[:rhs][:value]
          end
          step[:tuple] = true
        when '~>'
          result = {:type => 'apply', :value => expr[:value], :position => expr[:position]}
          result[:lhs] = process_ast(expr[:lhs])
          result[:rhs] = process_ast(expr[:rhs])
          result[:keep_array] = result[:lhs][:keep_array] || result[:rhs][:keep_array]
        else
          result = {:type => expr[:type], :value => expr[:value], :position => expr[:position]}
          result[:lhs] = process_ast(expr[:lhs])
          result[:rhs] = process_ast(expr[:rhs])
          push_ancestry(result, result[:lhs])
          push_ancestry(result, result[:rhs])
        end
      when 'unary'
        result = {:type => expr[:type], :value => expr[:value], :position => expr[:position]}
        if expr[:value] == '['
          # array constructor - process each item
          result[:expressions] = expr[:expressions].map do |item|
            value = process_ast(item)
            push_ancestry(result, value)
            value
          end
        elsif expr[:value] == '{'
          # object constructor - process each pair
          result[:lhs] = expr[:lhs].map do |pair|
            key = process_ast(pair[0])
            push_ancestry(result, key)
            value = process_ast(pair[1])
            push_ancestry(result, value)
            [key, value]
          end
        else
          # all other unary expressions - just process the expression
          result[:expression] = process_ast(expr[:expression])
          # if unary minus on a number, then pre-process
          if expr[:value] == '-' && result[:expression][:type] == 'number'
            result = result[:expression]
            result[:value] = -result[:value]
          else
            push_ancestry(result, result[:expression])
          end
        end
      when 'function', 'partial'
        result = {:type => expr[:type], :name => expr[:name], :value => expr[:value], :position => expr[:position]}
        result[:arguments] = expr[:arguments].map do |arg|
          arg_ast = process_ast(arg)
          push_ancestry(result, arg_ast)
          arg_ast
        end
        result[:procedure] = process_ast(expr[:procedure])
      when 'lambda'
        result = {
          :type      => expr[:type],
          :arguments => expr[:arguments],
          :signature => expr[:signature],
          :position  => expr[:position]
        }
        body = process_ast(expr[:body])
        result[:body] = tail_call_optimize(body)
      when 'template'
        result = {:type => expr[:type], :value => expr[:value], :position => expr[:position]}
        result[:parts] = expr[:parts].map do |part|
          next part if part.kind_of?(String) # literal text

          part_ast = process_ast(part[:expression])
          push_ancestry(result, part_ast)
          {:expression => part_ast, :position => part[:position]}
        end
      when 'condition'
        result = {:type => expr[:type], :position => expr[:position]}
        result[:condition] = process_ast(expr[:condition])
        push_ancestry(result, result[:condition])
        result[:then] = process_ast(expr[:then])
        push_ancestry(result, result[:then])
        if expr.key?(:else)
          result[:else] = process_ast(expr[:else])
          push_ancestry(result, result[:else])
        end
      when 'transform'
        result = {:type => expr[:type], :position => expr[:position]}
        result[:pattern] = process_ast(expr[:pattern])
        result[:update] = process_ast(expr[:update])
        result[:delete] = process_ast(expr[:delete]) if expr.key?(:delete)
      when 'block'
        result = {:type => expr[:type], :position => expr[:position]}
        # array of expressions - process each one
        result[:expressions] = expr[:expressions].map do |item|
          block_expression(result, process_ast(item))
        end
        # TODO scan the array of expressions to see if any of them assign variables
        # if so, need to mark the block as one that needs to create a new frame
      when 'name'
        result = {:type => 'path', :steps => [expr]}
        result[:keep_singleton_array] = true if expr[:keep_array]
      when 'parent'
        result = {:type => 'parent', :slot => {:label => "!#{@ancestor_label}", :level => 1, :index => @ancestor_index}}
        @ancestor_label += 1
        @ancestor_index += 1
        @ancestry.push(result)
      when 'string', 'number', 'value', 'wildcard', 'descendant', 'variable', 'regex'
        result = expr
      when 'operator'
        # the tokens 'and' and 'or' might have been used as a name rather than an operator
        if %w[and or in].include?(expr[:value])
          expr[:type] = 'name'
          result = process_ast(expr)
        elsif expr[:value] == '?'
          # partial application
          result = expr
        else
          raise Jsonata::Error.new('S0201', :position => expr[:position], :token => expr[:value])
        end
      when 'error'
        result = expr
        result = process_ast(expr[:lhs]) if expr[:lhs]
      else
        code = 'S0206'
        code = 'S0207' if node_id(expr) == '(end)'
        err = Jsonata::Error.new(code, :position => expr[:position], :token => expr[:value])
        raise err unless @recover

        @errors.push(err)
        return {:type => 'error', :error => err}
      end
      result[:keep_array] = true if expr[:keep_array]
      result
    end
  end
end
