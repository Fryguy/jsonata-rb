# frozen_string_literal: true

# (c) Copyright IBM Corp. 2016, 2018 All Rights Reserved
#   Project name: JSONata
#   This project is licensed under the MIT License, see LICENSE

# Port of jsonata-js src/signature.js

module Jsonata
  class Signature
    # A mapping between the function signature symbols and the full plural of the type
    # Expected to be used in error messages
    ARRAY_SIGNATURE_MAPPING = {
      'a' => 'arrays',
      'b' => 'booleans',
      'f' => 'functions',
      'n' => 'numbers',
      'o' => 'objects',
      's' => 'strings'
    }.freeze

    Param = Struct.new(:regex, :type, :array, :context, :context_regex, :subtype)

    attr_reader :definition

    # Parses a function signature definition and returns a validation function
    # @param signature - the signature between the <angle brackets>
    def initialize(signature)
      @definition = signature
      # create a Regex that represents this signature and return a function that when invoked,
      # returns the validated (possibly fixed-up) arguments, or throws a validation error
      # step through the signature, one symbol at a time
      position = 1
      @params = []
      param = Param.new
      prev_param = param
      next_param = lambda do
        @params.push(param)
        prev_param = param
        param = Param.new
      end

      while position < signature.length
        symbol = signature[position]
        if symbol == ':'
          # TODO figure out what to do with the return type
          # ignore it for now
          break
        end

        case symbol
        when 's', 'n', 'b', 'l', 'o' # string, number, boolean, null, object
          param.regex = "[#{symbol}m]"
          param.type = symbol
          next_param.call
        when 'a' # array
          #  normally treat any value as singleton array
          param.regex = '[asnblfom]'
          param.type = symbol
          param.array = true
          next_param.call
        when 'f' # function
          param.regex = 'f'
          param.type = symbol
          next_param.call
        when 'j' # any JSON type
          param.regex = '[asnblom]'
          param.type = symbol
          next_param.call
        when 'x' # any type
          param.regex = '[asnblfom]'
          param.type = symbol
          next_param.call
        when '-' # use context if param not supplied
          prev_param.context = true
          prev_param.context_regex = Regexp.new(prev_param.regex) # pre-compiled to test the context type at runtime
          prev_param.regex += '?'
        when '?', '+' # optional param, one or more
          prev_param.regex += symbol
        when '(' # choice of types
          # search forward for matching ')'
          end_paren = find_closing_bracket(signature, position, '(', ')')
          choice = signature[(position + 1)...end_paren]
          if choice.index('<').nil?
            # no parameterized types, simple regex
            param.regex = "[#{choice}m]"
          else
            # TODO harder
            raise Jsonata::Error.new('S0402', :value => choice, :offset => position)
          end
          param.type = "(#{choice})"
          position = end_paren
          next_param.call
        when '<' # type parameter - can only be applied to 'a' and 'f'
          if prev_param.type == 'a' || prev_param.type == 'f'
            # search forward for matching '>'
            end_pos = find_closing_bracket(signature, position, '<', '>')
            prev_param.subtype = signature[(position + 1)...end_pos]
            position = end_pos
          else
            raise Jsonata::Error.new('S0401', :value => prev_param.type, :offset => position)
          end
        end
        position += 1
      end
      regex_str = "^#{@params.map { |p| "(#{p.regex})" }.join}$"
      @regex = Regexp.new(regex_str)
    end

    def validate(args, context)
      supplied_sig = args.map { |arg| get_symbol(arg) }.join
      is_valid = @regex.match(supplied_sig)
      throw_validation_error(args, supplied_sig) unless is_valid

      validated_args = []
      arg_index = 0
      @params.each_with_index do |param, index|
        arg = args[arg_index]
        match = is_valid[index + 1]
        if match == ''
          if param.context && param.context_regex
            # substitute context value for missing arg
            # first check that the context value is the right type
            context_type = get_symbol(context)
            # test contextType against the regex for this arg (without the trailing ?)
            if param.context_regex.match?(context_type)
              validated_args.push(context)
            else
              # context value not compatible with this argument
              raise Jsonata::Error.new('T0411', :value => context, :index => arg_index + 1)
            end
          else
            validated_args.push(arg)
            arg_index += 1
          end
        else
          # may have matched multiple args (if the regex ends with a '+')
          # split into single tokens
          match.each_char do |single|
            arg = args[arg_index]
            if param.type == 'a'
              if single == 'm'
                # missing (undefined)
                arg = nil
              else
                array_ok = true
                # is there type information on the contents of the array?
                unless param.subtype.nil?
                  if single != 'a' && match != param.subtype
                    array_ok = false
                  elsif single == 'a'
                    if arg.length.positive?
                      item_type = get_symbol(arg[0])
                      if item_type != param.subtype[0] # TODO recurse further
                        array_ok = false
                      else
                        # make sure every item in the array is this type
                        array_ok = arg.all? { |val| get_symbol(val) == item_type }
                      end
                    end
                  end
                end
                unless array_ok
                  raise Jsonata::Error.new('T0412', :value => arg, :index => arg_index + 1,
                                                    :type => ARRAY_SIGNATURE_MAPPING[param.subtype])
                end
                # the function expects an array. If it's not one, make it so
                arg = [arg] if single != 'a'
              end
            end
            validated_args.push(arg)
            arg_index += 1
          end
        end
      end
      validated_args
    end

    private

    # returns the position of the closing symbol (e.g. bracket) in a string
    # that balances the opening symbol at position start
    def find_closing_bracket(str, start, open_symbol, close_symbol)
      depth = 1
      position = start
      while position < str.length
        position += 1
        symbol = str[position]
        if symbol == close_symbol
          depth -= 1
          break if depth.zero? # we're done
        elsif symbol == open_symbol
          depth += 1
        end
      end
      position
    end

    def get_symbol(value)
      if Utils.function?(value)
        'f'
      else
        case value
        when String then 's'
        when Numeric then 'n'
        when true, false then 'b'
        when NULL then 'l'
        when Array then 'a'
        when nil then 'm' # any value can be undefined, but should be allowed to match - m for missing
        else 'o'
        end
      end
    end

    def throw_validation_error(bad_args, bad_sig)
      # to figure out where this went wrong we need apply each component of the
      # regex to each argument until we get to the one that fails to match
      partial_pattern = '^'
      good_to = 0
      @params.each do |param|
        partial_pattern += param.regex
        match = Regexp.new(partial_pattern).match(bad_sig)
        if match.nil?
          # failed here
          raise Jsonata::Error.new('T0410', :value => bad_args[good_to], :index => good_to + 1)
        end

        good_to = match[0].length
      end
      # if it got this far, it's probably because of extraneous arguments (we
      # haven't added the trailing '$' in the regex yet.
      raise Jsonata::Error.new('T0410', :value => bad_args[good_to], :index => good_to + 1)
    end
  end
end
