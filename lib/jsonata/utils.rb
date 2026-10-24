# frozen_string_literal: true

# Port of jsonata-js src/utils.js
#
# In addition to the functions in utils.js, this file contains the helpers that
# emulate JavaScript semantics that the rest of the port depends on:
#
# * `nil` represents JavaScript `undefined`, and `Jsonata::NULL` represents JSON `null`.
# * `Jsonata::JArray` is an Array that can carry the extra properties that
#   jsonata-js attaches to arrays (sequence, keepSingleton, tupleStream, cons, outerWrapper).
# * JSON objects are Hashes with String keys.

module Jsonata
  # Represents the JSON value `null` (as distinct from `nil`, which represents `undefined`)
  NULL = Object.new
  class << NULL
    def inspect = 'Jsonata::NULL'
    def to_s = 'null'
    def to_json(*) = 'null'
  end
  NULL.freeze

  # An Array that carries the additional properties that jsonata-js sets on arrays
  class JArray < Array
    attr_accessor :sequence, :keep_singleton, :tuple_stream, :cons, :outer_wrapper, :max_length

    def push(*items)
      if max_length && length + items.length > max_length
        raise Jsonata::Error.new('D2015', value: max_length)
      end

      super
    end
    alias << push
  end

  module Utils
    module_function

    # Check if value is a finite number
    # @param n - number to evaluate
    # @returns true if n is a finite number
    def numeric?(n)
      is_num = false
      if n.is_a?(Numeric)
        is_num = !(n.is_a?(Float) && n.nan?)
        if is_num && n.is_a?(Float) && n.infinite?
          raise Jsonata::Error.new('D1001', value: n)
        end
      end
      is_num
    end

    # Returns true if the arg is an array of strings
    def array_of_strings?(arg)
      result = false
      if arg.is_a?(Array)
        result = arg.all? { |item| item.is_a?(String) }
      end
      result
    end

    # Returns true if the arg is an array of numbers
    def array_of_numbers?(arg)
      result = false
      if arg.is_a?(Array)
        result = arg.all? { |item| numeric?(item) }
      end
      result
    end

    # Tests if a value is a sequence
    def sequence?(value)
      value.is_a?(JArray) && value.sequence == true
    end

    # @returns true if it is a function (lambda or built-in)
    def function?(arg)
      arg.is_a?(Lambda) || arg.is_a?(NativeFunction) || callable?(arg)
    end

    # Equivalent of JavaScript `typeof arg === 'function'`
    def callable?(arg)
      arg.is_a?(Proc) || arg.is_a?(Method) || arg.is_a?(Closure)
    end

    # Returns the arity (number of arguments) of the function
    def get_function_arity(func)
      case func
      when Closure then func.arity
      when NativeFunction then parameter_arity(func.implementation)
      when Lambda then func.arguments.length
      else parameter_arity(func)
      end
    end

    # Equivalent of JavaScript Function.length - the number of declared parameters
    # before the first one with a default value
    def parameter_arity(callable)
      callable.parameters.take_while { |type, _| type == :req }.length
    end

    # Names of the declared parameters of a Ruby callable (used for partial application of native functions)
    def parameter_names(callable)
      callable.parameters.reject { |type, _| %i[block keyrest key keyreq].include?(type) }.map { |_, name| name.to_s }
    end

    # Invokes a Ruby callable with JavaScript calling semantics - missing arguments are
    # passed as undefined (nil), and extraneous arguments are dropped.
    # If `receiver` is given and the callable is an UnboundMethod, it is bound to the receiver
    # (the equivalent of Function.prototype.apply(this, args))
    def invoke(callable, args, receiver = nil)
      params = callable.parameters
      unless params.any? { |type, _| type == :rest }
        required = params.count { |type, _| type == :req }
        optional = params.count { |type, _| type == :opt }
        args = args.take(required + optional)
        args += Array.new(required - args.length) if args.length < required
      end
      if callable.is_a?(UnboundMethod)
        callable.bind_call(receiver, *args)
      else
        callable.call(*args)
      end
    end

    # Tests whether arg is a lambda function
    def lambda?(arg)
      arg.is_a?(Lambda)
    end

    # Compares two values for equality
    # @returns true if they are deep equal
    def deep_equal?(lhs, rhs)
      return true if lhs.equal?(rhs)

      if lhs.is_a?(Array) && rhs.is_a?(Array)
        # both arrays (or sequences)
        # must be the same length
        return false if lhs.length != rhs.length

        # must contain same values in same order
        lhs.each_index do |ii|
          return false unless deep_equal?(lhs[ii], rhs[ii])
        end
        return true
      end
      if lhs.is_a?(Hash) && rhs.is_a?(Hash)
        # both objects
        # must have the same set of keys (in any order)
        return false if lhs.length != rhs.length

        lkeys = lhs.keys.sort
        rkeys = rhs.keys.sort
        return false if lkeys != rkeys

        # must have the same values
        lkeys.each do |key|
          return false unless deep_equal?(lhs[key], rhs[key])
        end
        return true
      end
      return false if lhs.is_a?(Array) || lhs.is_a?(Hash) || rhs.is_a?(Array) || rhs.is_a?(Hash)

      strict_equal?(lhs, rhs)
    end

    # Equivalent of the JavaScript `===` operator
    def strict_equal?(lhs, rhs)
      if lhs.is_a?(Numeric) && rhs.is_a?(Numeric)
        lhs == rhs
      elsif lhs.is_a?(String) && rhs.is_a?(String)
        lhs == rhs
      else
        lhs.equal?(rhs)
      end
    end

    # converts a string to an array of characters
    def string_to_array(str)
      str.chars
    end

    # @returns the keys (property names) of the object
    def keys(arg)
      case arg
      when Hash then arg.keys
      when Array then (0...arg.length).map(&:to_s)
      else []
      end
    end

    ##################################################################
    # JavaScript emulation helpers (not part of utils.js)
    ##################################################################

    # Equivalent of JavaScript `typeof value`
    def typeof(value)
      case value
      when nil then 'undefined'
      when String then 'string'
      when Numeric then 'number'
      when true, false then 'boolean'
      else
        callable?(value) ? 'function' : 'object'
      end
    end

    # Equivalent of JavaScript truthiness
    def truthy?(value)
      case value
      when nil, false, NULL, '' then false
      when Numeric then !(value.zero? || (value.is_a?(Float) && value.nan?))
      else true
      end
    end

    # Converts a numeric result of a floating point operation to an Integer, if it is integral
    def normalize_number(num)
      if num.is_a?(Float) && num.finite? && num == num.truncate && num.abs < 9_007_199_254_740_992
        num.to_i
      else
        num
      end
    end

    # Equivalent of JavaScript Number.isInteger
    def integer?(value)
      value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.truncate)
    end

    # Equivalent of the JavaScript Number::toString() algorithm
    def number_to_s(num)
      if num.is_a?(Integer)
        return num.to_s if num.abs < 10**21

        num = num.to_f
      end
      return 'NaN' if num.nan?
      return (num.positive? ? 'Infinity' : '-Infinity') if num.infinite?
      return '0' if num.zero?

      digits, point = shortest_digits(num.abs)
      k = digits.length
      str = if k <= point && point <= 21
              digits + ('0' * (point - k))
            elsif point.positive? && point <= 21
              "#{digits[0, point]}.#{digits[point..]}"
            elsif point > -6 && point <= 0
              "0.#{'0' * -point}#{digits}"
            else
              e = point - 1
              exp = e.negative? ? "-#{-e}" : "+#{e}"
              k == 1 ? "#{digits}e#{exp}" : "#{digits[0]}.#{digits[1..]}e#{exp}"
            end
      num.negative? ? "-#{str}" : str
    end

    # Returns the shortest round-trip decimal digits of a positive finite float,
    # and the position of the decimal point relative to the start of the digits
    def shortest_digits(num)
      mantissa, exp = num.to_s.split('e')
      int_part, frac_part = mantissa.split('.')
      digits = int_part + (frac_part || '')
      point = int_part.length + exp.to_i
      stripped = digits.sub(/\A0+/, '')
      point -= digits.length - stripped.length
      digits = stripped.sub(/0+\z/, '')
      [digits, point]
    end

    # Equivalent of JavaScript Number.prototype.toFixed
    def to_fixed(num, digits)
      return number_to_s(num) if num.is_a?(Float) && !num.finite?
      return number_to_s(num) if num.abs >= 1e21

      negative = num.negative?
      scaled = (num.abs.to_r * (10**digits)).round(half: :up)
      str = scaled.to_s
      if digits.positive?
        str = str.rjust(digits + 1, '0')
        str = "#{str[0...-digits]}.#{str[-digits..]}"
      end
      negative && scaled != 0 ? "-#{str}" : str
    end

    # Equivalent of JavaScript Number.prototype.toPrecision, followed by conversion back to a number
    def to_precision(num, precision)
      return num if num.zero? || !num.finite?

      exact = num.abs.to_r
      e = Math.log10(num.abs).floor
      # correct for floating point inaccuracies in log10
      e += 1 while exact >= Rational(10)**(e + 1)
      e -= 1 while exact < Rational(10)**e
      scale = Rational(10)**(precision - 1 - e)
      n = (exact * scale).round(half: :up)
      result = (n / scale).to_f
      num.negative? ? -result : result
    end

    # Equivalent of JavaScript parseInt(str, 10) - returns nil (NaN) if no digits
    def parse_int(str)
      m = /\A\s*([-+]?\d+)/.match(str.to_s)
      m ? m[1].to_i : nil
    end

    # Equivalent of Array.prototype.slice / String.prototype.slice
    def js_slice(obj, start, end_pos = nil)
      len = obj.length
      relative = lambda do |val|
        val = val.to_f
        return 0 if val.nan?

        val = val.truncate if val.finite?
        val = len + val if val.negative?
        val.clamp(0, len).to_i
      end
      from = relative.call(start)
      to = end_pos.nil? ? len : relative.call(end_pos)
      return obj.is_a?(String) ? +'' : [] if to <= from

      obj[from...to]
    end

    # Equivalent of String.prototype.split(separator, limit) for a string separator
    def js_split(str, separator, limit = nil)
      result = if separator == ''
                 str.chars
               else
                 parts = []
                 position = 0
                 index = str.index(separator, position)
                 until index.nil?
                   parts.push(str[position...index])
                   position = index + separator.length
                   index = str.index(separator, position)
                 end
                 parts.push(str[position..])
                 parts
               end
      limit.nil? ? result : result.take(limit.to_i)
    end

    # Equivalent of the JavaScript Number(str) conversion
    def js_number(str)
      s = str.strip
      return 0 if s.empty?

      case s
      when /\A0[xX][0-9a-fA-F]+\z/, /\A0[oO][0-7]+\z/, /\A0[bB][01]+\z/
        Integer(s)
      when /\A[-+]?(\d+\.?\d*([eE][-+]?\d+)?|\.\d+([eE][-+]?\d+)?)\z/
        normalize_number(Float(s))
      when /\A[-+]?Infinity\z/
        s.start_with?('-') ? -Float::INFINITY : Float::INFINITY
      else
        Float::NAN
      end
    end

    class URIError < StandardError; end

    URI_UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
    URI_RESERVED = ';/?:@&=+$,#'

    # Equivalent of encodeURI / encodeURIComponent
    # @param unescaped - the set of characters that are not escaped
    def encode_uri(str, unescaped)
      raise URIError unless str.valid_encoding?

      str.each_char.map do |ch|
        if unescaped.include?(ch)
          ch
        else
          ch.bytes.map { |b| format('%%%02X', b) }.join
        end
      end.join
    end

    # Equivalent of decodeURI / decodeURIComponent
    # @param reserved - the set of characters whose escape sequences are not decoded
    def decode_uri(str, reserved)
      result = +''
      k = 0
      length = str.length
      while k < length
        ch = str[k]
        if ch != '%'
          result << ch
          k += 1
          next
        end
        start = k
        raise URIError if k + 2 >= length || !str[k + 1, 2].match?(/\A\h\h\z/)

        b = str[k + 1, 2].to_i(16)
        k += 2
        if b < 0x80
          c = b.chr
          result << (reserved.include?(c) ? str[start..k] : c)
        else
          n = if (b & 0xE0) == 0xC0 then 2
              elsif (b & 0xF0) == 0xE0 then 3
              elsif (b & 0xF8) == 0xF0 then 4
              else raise URIError
              end
          bytes = [b]
          (n - 1).times do
            k += 1
            raise URIError if k + 2 >= length || str[k] != '%' || !str[k + 1, 2].match?(/\A\h\h\z/)

            byte = str[k + 1, 2].to_i(16)
            raise URIError if (byte & 0xC0) != 0x80

            bytes.push(byte)
            k += 2
          end
          decoded = bytes.pack('C*').force_encoding(Encoding::UTF_8)
          raise URIError unless decoded.valid_encoding?

          result << decoded
        end
        k += 1
      end
      result
    end

    # Equivalent of String.fromCharCode for a single code point.
    # Lone surrogates are encoded as (invalid) UTF-8 bytes, so that they can be detected later
    def from_char_code(codepoint)
      [codepoint].pack('U').force_encoding(Encoding::UTF_8)
    end

    # Translates a JavaScript regular expression into a Ruby Regexp
    # @param source - the JavaScript regex pattern
    # @param flags - the JavaScript regex flags (only 'i' and 'm' are significant)
    def js_regexp(source, flags = '')
      multiline = flags.include?('m')
      out = +''
      in_class = false
      i = 0
      while i < source.length
        ch = source[i]
        if ch == '\\'
          out << ch << (source[i + 1] || '')
          i += 2
          next
        end
        if in_class
          in_class = false if ch == ']'
          out << ch
        elsif ch == '['
          if source[i + 1] == ']'
            # empty class - matches nothing
            out << '(?!)'
            i += 2
            next
          elsif source[i + 1, 2] == '^]'
            # negated empty class - matches anything
            out << '[\s\S]'
            i += 3
            next
          end
          in_class = true
          out << ch
          # a ']' immediately after '[' or '[^' is a literal in Ruby but closes the class in JS
        elsif ch == '^' && !multiline
          out << '\A'
        elsif ch == '$' && !multiline
          out << '\z'
        else
          out << ch
        end
        i += 1
      end
      options = flags.include?('i') ? Regexp::IGNORECASE : 0
      Regexp.new("(?a)#{out}", options)
    end

    # Converts a Ruby value supplied by the caller into the representation used internally:
    # Symbol keys are converted to Strings and nil is converted to NULL
    def from_ruby(value)
      case value
      when nil then NULL
      when Hash then value.each_with_object({}) { |(k, v), h| h[k.is_a?(Symbol) ? k.to_s : k] = from_ruby(v) }
      when JArray then value
      when Array then value.map { |v| from_ruby(v) }
      when Symbol then value.to_s
      else value
      end
    end

    # Converts an internal value into a plain Ruby value for the caller:
    # NULL is converted to nil, and JArrays to plain Arrays
    def to_ruby(value)
      case value
      when NULL then nil
      when Hash then value.transform_values { |v| to_ruby(v) }
      when Array then value.map { |v| to_ruby(v) }
      else value
      end
    end

    # JSON.stringify with JavaScript semantics
    # @param replacer - optional proc(value) returning the replaced value
    # @param space - number of spaces to indent
    def json_stringify(value, replacer = nil, space = 0)
      value = replacer.call(value) if replacer
      stringify_value(value, replacer, space, '')
    end

    def stringify_value(value, replacer, space, indent)
      case value
      when nil then nil
      when NULL, true, false then value == NULL ? 'null' : value.to_s
      when String then quote_json_string(value)
      when Numeric
        value.is_a?(Float) && !value.finite? ? 'null' : number_to_s(value)
      when Array
        return '[]' if value.empty?

        inner = indent + (' ' * space)
        items = value.map do |item|
          item = replacer.call(item) if replacer
          stringify_value(item, replacer, space, inner) || 'null'
        end
        if space.positive?
          "[\n#{inner}#{items.join(",\n#{inner}")}\n#{indent}]"
        else
          "[#{items.join(',')}]"
        end
      when Hash
        inner = indent + (' ' * space)
        sep = space.positive? ? ': ' : ':'
        items = value.filter_map do |k, v|
          v = replacer.call(v) if replacer
          str = stringify_value(v, replacer, space, inner)
          "#{quote_json_string(k.to_s)}#{sep}#{str}" unless str.nil?
        end
        return '{}' if items.empty?

        if space.positive?
          "{\n#{inner}#{items.join(",\n#{inner}")}\n#{indent}}"
        else
          "{#{items.join(',')}}"
        end
      else
        callable?(value) ? nil : '{}'
      end
    end

    JSON_ESCAPES = { '"' => '\\"', '\\' => '\\\\', "\b" => '\\b', "\f" => '\\f', "\n" => '\\n', "\r" => '\\r', "\t" => '\\t' }.freeze

    def quote_json_string(str)
      unless str.valid_encoding?
        # lone surrogates (see #from_char_code) are escaped, as they are by JSON.stringify
        marked = str.scrub { |bytes| "\uFFFF#{bytes.unpack1('H*')}\uFFFF" }
        return quote_json_string(marked).gsub(/(?:\uFFFF\h+\uFFFF)+/) do |run|
          bytes = run.scan(/\h\h/).map(&:hex)
          bytes.each_slice(3).map do |b0, b1, b2|
            codepoint = ((b0 & 0x0F) << 12) | (((b1 || 0) & 0x3F) << 6) | ((b2 || 0) & 0x3F)
            format('\\u%04x', codepoint)
          end.join
        end
      end

      escaped = str.gsub(/["\\\u0000-\u001f]/) do |ch|
        JSON_ESCAPES[ch] || format('\\u%04x', ch.ord)
      end
      "\"#{escaped}\""
    end

    # Equivalent of Math.floor - the result is an Integer only if it can be represented exactly
    def js_floor(num)
      num.is_a?(Integer) ? num : normalize_number(num.floor.to_f)
    end
  end
end
