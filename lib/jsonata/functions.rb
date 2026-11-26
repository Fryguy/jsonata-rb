# frozen_string_literal: true

# (c) Copyright IBM Corp. 2016, 2018 All Rights Reserved
#   Project name: JSONata
#   This project is licensed under the MIT License, see LICENSE

# Port of jsonata-js src/functions.js
#
# The functions are defined as instance methods, and are invoked with a Jsonata::Focus object as the receiver,
# which is the equivalent of the `this` object that jsonata-js invokes them with.

module Jsonata
  module Functions
    # Sum function
    # @param args [Object] Arguments
    # @return [Numeric] Total value of arguments
    def sum(args)
      # undefined inputs always return undefined
      return nil if args.nil?

      total = 0.0
      args.each do |num|
        total += num
      end
      Utils.normalize_number(total)
    end

    # Count function
    # @param args [Object] Arguments
    # @return [Numeric] Number of elements in the array
    def count(args)
      # undefined inputs always return undefined
      return 0 if args.nil?

      args.length
    end

    # Max function
    # @param args [Object] Arguments
    # @return [Numeric] Max element in the array
    def max(args)
      # undefined inputs always return undefined
      return nil if args.nil? || args.empty?

      args.max
    end

    # Min function
    # @param args [Object] Arguments
    # @return [Numeric] Min element in the array
    def min(args)
      # undefined inputs always return undefined
      return nil if args.nil? || args.empty?

      args.min
    end

    # Average function
    # @param args [Object] Arguments
    # @return [Numeric] Average element in the array
    def average(args)
      # undefined inputs always return undefined
      return nil if args.nil? || args.empty?

      total = 0.0
      args.each do |num|
        total += num
      end
      Utils.normalize_number(total / args.length)
    end

    # Stringify arguments
    # @param arg [Object] Arguments
    # @param prettify [Boolean] Pretty print the result
    # @return [String] String from arguments
    def string(arg, prettify = false)
      # undefined inputs always return undefined
      return nil if arg.nil?

      if arg.kind_of?(String)
        # already a string
        arg
      elsif Utils.function?(arg)
        # functions (built-in and lambda convert to empty string
        ''
      elsif arg.kind_of?(Float) && !arg.finite?
        raise Jsonata::Error.new('D3001', :value => arg)
      else
        space = prettify ? 2 : 0
        arg = arg[0] if arg.kind_of?(JArray) && arg.outer_wrapper
        Utils.json_stringify(arg, lambda { |val|
          if !val.nil? && val != NULL && Utils.numeric?(val)
            Utils.integer?(val) ? val : Utils.to_precision(val, 15)
          else
            Utils.function?(val) ? '' : val
          end
        }, space)
      end
    end

    # Create substring based on character number and length
    # @param str [String] String to evaluate
    # @param start [Integer] Character number to start substring
    # @param length [Integer] Number of characters in substring
    # @return [String, Object] Substring
    def substring(str, start, length)
      # undefined inputs always return undefined
      return nil if str.nil?

      str_array = Utils.string_to_array(str)
      str_length = str_array.length

      start = 0 if (str_length + start).negative?

      unless length.nil?
        return '' if length <= 0

        end_pos = start >= 0 ? start + length : str_length + start + length
        return Utils.js_slice(str_array, start, end_pos).join
      end

      Utils.js_slice(str_array, start).join
    end

    # Create substring up until a character
    # @param str [String] String to evaluate
    # @param chars [String] Character to define substring boundary
    # @return [Object] Substring
    def substring_before(str, chars)
      # undefined inputs always return undefined
      return nil if str.nil?

      pos = str.index(chars)
      if pos.nil?
        str
      else
        str[0, pos]
      end
    end

    # Create substring after a character
    # @param str [String] String to evaluate
    # @param chars [String] Character to define substring boundary
    # @return [Object] Substring
    def substring_after(str, chars)
      # undefined inputs always return undefined
      return nil if str.nil?

      pos = str.index(chars)
      if pos.nil?
        str
      else
        str[(pos + chars.length)..]
      end
    end

    # Lowercase a string
    # @param str [String] String to evaluate
    # @return [String] Lowercase string
    def lowercase(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      str.downcase
    end

    # Uppercase a string
    # @param str [String] String to evaluate
    # @return [String] Uppercase string
    def uppercase(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      str.upcase
    end

    # length of a string
    # @param str [String] string
    # @return [Numeric] The number of characters in the string
    def length(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      Utils.string_to_array(str).length
    end

    # Normalize and trim whitespace within a string
    # @param str [String] string to be trimmed
    # @return [String] trimmed string
    def trim(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      # normalize whitespace
      result = str.gsub(/[ \t\n\r]+/, ' ')
      if result[0] == ' '
        # strip leading space
        result = result[1..]
      end
      if result[-1] == ' '
        # strip trailing space
        result = result[0...-1]
      end
      result
    end

    # Pad a string to a minimum width by adding characters to the start or end
    # @param str [String] string to be padded
    # @param width [Numeric] the minimum width; +ve pads to the right, -ve pads to the left
    # @param char [String] the pad character(s); defaults to ' '
    # @return [String] padded string
    def pad(str, width, char)
      # undefined inputs always return undefined
      return nil if str.nil?

      char = ' ' if char.nil? || char.empty?

      width = width.truncate
      pad_length = width.abs - length(str)
      if pad_length.positive?
        # limit the length of the padding to ten million characters (1e7) to
        # protect against excessive memory allocation, consistent with the hard
        # limit imposed by the range operator (see error D2014)
        raise Jsonata::Error.new('D2016', :value => pad_length) if pad_length > 1e7

        padding = char * pad_length
        padding = substring(padding, 0, pad_length) if char.length > 1
        if width.positive?
          str + padding
        else
          padding + str
        end
      else
        str
      end
    end

    # Evaluate the matcher function against the str arg
    #
    # @param matcher [Object] matching function (native or lambda)
    # @param str [String] the string to match against
    # @return [Object] structure that represents the match(es)
    def evaluate_matcher(matcher, str = nil)
      result = call_function(matcher, [str])
      if Utils.truthy?(result) && !(result.kind_of?(Hash) && (result['start'].kind_of?(Numeric) || result['end'] == 'number' ||
                                                         result['groups'].kind_of?(Array) || Utils.function?(result['next'])))
        # the matcher function didn't return the correct structure
        raise Jsonata::Error.new('T1010')
      end

      result
    end

    # Tests if the str contains the token
    # @param str [String] string to test
    # @param token [String] substring or regex to find
    # @return [Boolean] true if str contains token
    def contains(str, token)
      # undefined inputs always return undefined
      return nil if str.nil? || token.nil?

      if token.kind_of?(String)
        str.include?(token)
      else
        matches = evaluate_matcher(token, str)
        !matches.nil?
      end
    end

    # Match a string with a regex returning an array of object containing details of each match
    # @param str [String] string
    # @param regex [String] the regex applied to the string
    # @param limit [Integer] max number of matches to return
    # @return [Array] The array of match objects
    def match(str, regex, limit)
      # undefined inputs always return undefined
      return nil if str.nil?

      # limit, if specified, must be a non-negative number
      raise Jsonata::Error.new('D3040', :value => limit, :index => 3) if !limit.nil? && limit.negative?

      result = create_sequence

      if limit.nil? || limit.positive?
        count = 0
        matches = evaluate_matcher(regex, str)
        unless matches.nil?
          while !matches.nil? && (limit.nil? || count < limit)
            result.push({
                          'match'  => matches['match'],
                          'index'  => matches['start'],
                          'groups' => matches['groups']
                        })
            matches = evaluate_matcher(matches['next'])
            count += 1
          end
        end
      end

      result
    end

    # Match a string with a regex returning an array of object containing details of each match
    # @param str [String] string
    # @param pattern [String] the substring/regex applied to the string
    # @param replacement [String] text to replace the matched substrings
    # @param limit [Integer] max number of matches to return
    # @return [Array] The array of match objects
    def replace(str, pattern, replacement, limit)
      # undefined inputs always return undefined
      return nil if str.nil? || pattern.nil?

      # pattern cannot be an empty string
      raise Jsonata::Error.new('D3010', :value => pattern, :index => 2) if pattern == ''

      # limit, if specified, must be a non-negative number
      raise Jsonata::Error.new('D3011', :value => limit, :index => 4) if !limit.nil? && limit.negative?

      replacer = if replacement.kind_of?(String)
                   lambda do |regex_match|
                     substitute = +''
                     # scan forward, copying the replacement text into the substitute string
                     # and replace any occurrence of $n with the values matched by the regex
                     position = 0
                     index = replacement.index('$', position)
                     while !index.nil? && position < replacement.length
                       substitute << replacement[position...index]
                       position = index + 1
                       dollar_val = replacement[position] || ''
                       if dollar_val == '$'
                         # literal $
                         substitute << '$'
                         position += 1
                       elsif dollar_val == '0'
                         substitute << regex_match['match']
                         position += 1
                       else
                         groups = regex_match['groups']
                         max_digits = if groups.empty?
                                        # no sub-matches; any $ followed by a digit will be replaced by an empty string
                                        1
                                      else
                                        # max number of digits to parse following the $
                                        (Math.log(groups.length) * 0.4342944819032518).floor + 1
                                      end
                         index = Utils.parse_int(replacement[position, max_digits])
                         if max_digits > 1 && !index.nil? && index > groups.length
                           index = Utils.parse_int(replacement[position, max_digits - 1])
                         end
                         if index.nil?
                           # not a capture group, treat the $ as literal
                           substitute << '$'
                         else
                           if !groups.empty? && index >= 1
                             submatch = groups[index - 1]
                             substitute << submatch unless submatch.nil?
                           end
                           position += index.to_s.length
                         end
                       end
                       index = replacement.index('$', position)
                     end
                     substitute << (replacement[position..] || '')
                     substitute
                   end
                 else
                   replacement
                 end

      result = +''
      position = 0

      if limit.nil? || limit.positive?
        count = 0
        if pattern.kind_of?(String)
          index = str.index(pattern, position)
          while !index.nil? && (limit.nil? || count < limit)
            result << str[position...index]
            result << replacement.to_s
            position = index + pattern.length
            count += 1
            index = str.index(pattern, position)
          end
          result << (str[position..] || '')
        else
          matches = evaluate_matcher(pattern, str)
          if matches.nil?
            result = str
          else
            while !matches.nil? && (limit.nil? || count < limit)
              result << (str[position...matches['start']] || '')
              replaced_with = call_function(replacer, [matches])
              # check replacedWith is a string
              unless replaced_with.kind_of?(String)
                # not a string - throw error
                raise Jsonata::Error.new('D3012', :value => replaced_with)
              end

              result << replaced_with
              position = matches['start'] + matches['match'].length
              count += 1
              matches = evaluate_matcher(matches['next'])
            end
            result << (str[position..] || '')
          end
        end
      else
        result = str
      end

      result
    end

    # Base64 encode a string
    # @param str [String] string
    # @return [String] Base 64 encoding of the binary data
    def base64encode(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      # equivalent of Buffer.from(str, 'binary').toString('base64')
      bytes = str.encode('UTF-16LE').unpack('v*').map { |unit| unit & 0xFF }
      [bytes.pack('C*')].pack('m0')
    end

    # Base64 decode a string
    # @param str [String] string
    # @return [String] Base 64 encoding of the binary data
    def base64decode(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      # equivalent of Buffer.from(str, 'base64').toString('binary')
      str.unpack1('m').bytes.pack('U*')
    end

    # Encode a string into a component for a url
    # @param str [String] String to encode
    # @return [String] Encoded string
    def encode_url_component(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      # Catch URIErrors when URI sequence is malformed
      Utils.encode_uri(str, Utils::URI_UNRESERVED)
    rescue Utils::URIError
      raise Jsonata::Error.new('D3140', :value => str, :function_name => 'encodeUrlComponent')
    end

    # Encode a string into a url
    # @param str [String] String to encode
    # @return [String] Encoded string
    def encode_url(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      # Catch URIErrors when URI sequence is malformed
      Utils.encode_uri(str, Utils::URI_UNRESERVED + Utils::URI_RESERVED)
    rescue Utils::URIError
      raise Jsonata::Error.new('D3140', :value => str, :function_name => 'encodeUrl')
    end

    # Decode a string from a component for a url
    # @param str [String] String to decode
    # @return [String] Decoded string
    def decode_url_component(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      # Catch URIErrors when URI sequence is malformed
      Utils.decode_uri(str, '')
    rescue Utils::URIError
      raise Jsonata::Error.new('D3140', :value => str, :function_name => 'decodeUrlComponent')
    end

    # Decode a string from a url
    # @param str [String] String to decode
    # @return [String] Decoded string
    def decode_url(str)
      # undefined inputs always return undefined
      return nil if str.nil?

      # Catch URIErrors when URI sequence is malformed
      Utils.decode_uri(str, Utils::URI_RESERVED)
    rescue Utils::URIError
      raise Jsonata::Error.new('D3140', :value => str, :function_name => 'decodeUrl')
    end

    # Split a string into an array of substrings
    # @param str [String] string
    # @param separator [String] the token or regex that splits the string
    # @param limit [Integer] max number of substrings
    # @return [Array] The array of string
    def split(str, separator, limit)
      # undefined inputs always return undefined
      return nil if str.nil? || separator.nil?

      # limit, if specified, must be a non-negative number
      raise Jsonata::Error.new('D3020', :value => limit, :index => 3) if !limit.nil? && limit.negative?

      result = []

      if limit.nil? || limit.positive?
        if separator.kind_of?(String)
          result = Utils.js_split(str, separator, limit)
        else
          count = 0
          matches = evaluate_matcher(separator, str)
          if matches.nil?
            result.push(str)
          else
            start = 0
            while !matches.nil? && (limit.nil? || count < limit)
              result.push(str[start...matches['start']] || '')
              start = matches['end']
              matches = evaluate_matcher(matches['next'])
              count += 1
            end
            result.push(str[start..] || '') if limit.nil? || count < limit
          end
        end
      end

      result
    end

    # Join an array of strings
    # @param strs [Array] array of string
    # @param separator [String] the token that splits the string
    # @return [String] The concatenated string
    def join(strs, separator)
      # undefined inputs always return undefined
      return nil if strs.nil?

      # if separator is not specified, default to empty string
      separator = '' if separator.nil?

      strs.join(separator)
    end

    # Formats a number into a decimal string representation using XPath 3.1 F&O fn:format-number spec
    # @param value [Numeric] number to format
    # @param picture [String] picture string definition
    # @param options [Object] override locale defaults
    # @return [String] The formatted string
    def format_number(value, picture, options)
      # undefined inputs always return undefined
      return nil if value.nil?

      defaults = {
        'decimal-separator'  => '.',
        'grouping-separator' => ',',
        'exponent-separator' => 'e',
        'infinity'           => 'Infinity',
        'minus-sign'         => '-',
        'NaN'                => 'NaN',
        'percent'            => '%',
        'per-mille'          => "\u2030",
        'zero-digit'         => '0',
        'digit'              => '#',
        'pattern-separator'  => ';'
      }

      # if `options` is specified, then its entries override defaults
      properties = defaults
      unless options.nil?
        Utils.keys(options).each do |key|
          properties[key] = options[key]
        end
      end

      zero_char_code = properties['zero-digit'].ord
      decimal_digit_family = (zero_char_code...(zero_char_code + 10)).map do |ii|
        ii.chr(Encoding::UTF_8)
      end

      active_chars = decimal_digit_family + [properties['decimal-separator'], properties['exponent-separator'],
                                             properties['grouping-separator'], properties['digit'],
                                             properties['pattern-separator']]

      sub_pictures = Utils.js_split(picture, properties['pattern-separator'])

      raise Jsonata::Error.new('D3080') if sub_pictures.length > 2

      split_parts = lambda do |subpicture|
        prefix = (lambda do
          subpicture.each_char.with_index do |ch, ii|
            if active_chars.include?(ch) && ch != properties['exponent-separator']
              return subpicture[0, ii]
            end
          end
          ''
        end).call
        suffix = (lambda do
          (subpicture.length - 1).downto(0) do |ii|
            ch = subpicture[ii]
            if active_chars.include?(ch) && ch != properties['exponent-separator']
              return subpicture[(ii + 1)..]
            end
          end
          ''
        end).call
        active_part = subpicture[prefix.length...(subpicture.length - suffix.length)]
        exponent_position = subpicture.index(properties['exponent-separator'], prefix.length)
        if exponent_position.nil? || exponent_position > subpicture.length - suffix.length
          mantissa_part = active_part
          exponent_part = nil
        else
          mantissa_part = active_part[0, exponent_position]
          exponent_part = active_part[(exponent_position + 1)..] || ''
        end
        decimal_position = mantissa_part.index(properties['decimal-separator'])
        if decimal_position.nil?
          integer_part = mantissa_part
          fractional_part = suffix
        else
          integer_part = mantissa_part[0, decimal_position]
          fractional_part = mantissa_part[(decimal_position + 1)..]
        end
        {
          :prefix          => prefix,
          :suffix          => suffix,
          :active_part     => active_part,
          :mantissa_part   => mantissa_part,
          :exponent_part   => exponent_part,
          :integer_part    => integer_part,
          :fractional_part => fractional_part,
          :subpicture      => subpicture
        }
      end

      # validate the picture string, F&O 4.7.3
      validate = lambda do |parts|
        error = nil
        subpicture = parts[:subpicture]
        decimal_pos = subpicture.index(properties['decimal-separator'])
        error = 'D3081' if decimal_pos != subpicture.rindex(properties['decimal-separator'])
        error = 'D3082' if subpicture.index(properties['percent']) != subpicture.rindex(properties['percent'])
        error = 'D3083' if subpicture.index(properties['per-mille']) != subpicture.rindex(properties['per-mille'])
        if subpicture.include?(properties['percent']) && subpicture.include?(properties['per-mille'])
          error = 'D3084'
        end
        valid = parts[:mantissa_part].each_char.any? do |ch|
          decimal_digit_family.include?(ch) || ch == properties['digit']
        end
        error = 'D3085' unless valid
        char_types = parts[:active_part].each_char.map do |char|
          active_chars.include?(char) ? 'a' : 'p'
        end.join
        error = 'D3086' if char_types.include?('p')
        if decimal_pos.nil?
          error = 'D3088' if parts[:integer_part][-1] == properties['grouping-separator']
        elsif (decimal_pos.positive? && subpicture[decimal_pos - 1] == properties['grouping-separator']) ||
              subpicture[decimal_pos + 1] == properties['grouping-separator']
          error = 'D3087'
        end
        error = 'D3089' if subpicture.include?(properties['grouping-separator'] + properties['grouping-separator'])
        optional_digit_pos = parts[:integer_part].index(properties['digit'])
        if !optional_digit_pos.nil? && parts[:integer_part][0, optional_digit_pos].each_char.any? { |char| decimal_digit_family.include?(char) }
          error = 'D3090'
        end
        optional_digit_pos = parts[:fractional_part].rindex(properties['digit'])
        if !optional_digit_pos.nil? && parts[:fractional_part][optional_digit_pos..].each_char.any? { |char| decimal_digit_family.include?(char) }
          error = 'D3091'
        end
        exponent_exists = parts[:exponent_part].kind_of?(String)
        if exponent_exists && !parts[:exponent_part].empty? &&
           (subpicture.include?(properties['percent']) || subpicture.include?(properties['per-mille']))
          error = 'D3092'
        end
        if exponent_exists && (parts[:exponent_part].empty? || parts[:exponent_part].each_char.any? { |char| !decimal_digit_family.include?(char) })
          error = 'D3093'
        end
        raise Jsonata::Error.new(error) if error
      end

      # analyse the picture string, F&O 4.7.4
      analyse = lambda do |parts|
        get_grouping_positions = lambda do |part, to_left = false|
          positions = []
          grouping_position = part.index(properties['grouping-separator'])
          until grouping_position.nil?
            chars_to_the_right = (to_left ? part[0, grouping_position] : part[grouping_position..]).each_char.count do |char|
              decimal_digit_family.include?(char) || char == properties['digit']
            end
            positions.push(chars_to_the_right)
            grouping_position = parts[:integer_part].index(properties['grouping-separator'], grouping_position + 1)
          end
          positions
        end
        integer_part_grouping_positions = get_grouping_positions.call(parts[:integer_part])
        regular = lambda do |indexes|
          # are the grouping positions regular? i.e. same interval between each of them
          return 0 if indexes.empty?

          # find the greatest common divisor of all the positions
          factor = indexes.reduce { |a, b| a.gcd(b) }
          # is every position separated by this divisor? If so, it's regular
          (1..indexes.length).each do |index|
            return 0 unless indexes.include?(index * factor)
          end
          factor
        end

        regular_grouping = regular.call(integer_part_grouping_positions)
        fractional_part_grouping_positions = get_grouping_positions.call(parts[:fractional_part], true)

        minimum_integer_part_size = parts[:integer_part].each_char.count { |char| decimal_digit_family.include?(char) }
        scaling_factor = minimum_integer_part_size

        fractional_part_array = parts[:fractional_part].chars
        minimum_factional_part_size = fractional_part_array.count { |char| decimal_digit_family.include?(char) }
        maximum_factional_part_size = fractional_part_array.count do |char|
          decimal_digit_family.include?(char) || char == properties['digit']
        end
        exponent_present = parts[:exponent_part].kind_of?(String)
        if minimum_integer_part_size.zero? && maximum_factional_part_size.zero?
          if exponent_present
            minimum_factional_part_size = 1
            maximum_factional_part_size = 1
          else
            minimum_integer_part_size = 1
          end
        end
        if exponent_present && minimum_integer_part_size.zero? && parts[:integer_part].include?(properties['digit'])
          minimum_integer_part_size = 1
        end
        minimum_factional_part_size = 1 if minimum_integer_part_size.zero? && minimum_factional_part_size.zero?
        minimum_exponent_size = 0
        if exponent_present
          minimum_exponent_size = parts[:exponent_part].each_char.count { |char| decimal_digit_family.include?(char) }
        end

        {
          :integer_part_grouping_positions    => integer_part_grouping_positions,
          :regular_grouping                   => regular_grouping,
          :minimum_integer_part_size          => minimum_integer_part_size,
          :scaling_factor                     => scaling_factor,
          :prefix                             => parts[:prefix],
          :fractional_part_grouping_positions => fractional_part_grouping_positions,
          :minimum_factional_part_size        => minimum_factional_part_size,
          :maximum_factional_part_size        => maximum_factional_part_size,
          :minimum_exponent_size              => minimum_exponent_size,
          :suffix                             => parts[:suffix],
          :picture                            => parts[:subpicture]
        }
      end

      parts = sub_pictures.map(&split_parts)
      parts.each(&validate)

      variables = parts.map(&analyse)

      minus_sign = properties['minus-sign']
      zero_digit = properties['zero-digit']
      decimal_separator = properties['decimal-separator']
      grouping_separator = properties['grouping-separator']

      if variables.length == 1
        variables.push(Marshal.load(Marshal.dump(variables[0])))
        variables[1][:prefix] = minus_sign + variables[1][:prefix]
      end

      # TODO cache the result of the analysis

      # format the number
      # bullet 1: JSON can't hold NaN or infinity, but a JavaScript caller can pass them in
      if value.kind_of?(Float) && value.nan?
        return properties['NaN']
      end

      # bullet 2:
      pic = if value >= 0
              variables[0]
            else
              variables[1]
            end
      # bullet 3:
      adjusted_number = if pic[:picture].include?(properties['percent'])
                          value * 100
                        elsif pic[:picture].include?(properties['per-mille'])
                          value * 1000
                        else
                          value
                        end
      # bullet 4: this includes a finite number that overflows when multiplied by 100 or 1000
      if adjusted_number.kind_of?(Float) && adjusted_number.infinite?
        return pic[:prefix] + properties['infinity'] + pic[:suffix]
      end

      # bullets 5 & 6 work on the decimal digits of the number rather than on the double itself,
      # so that scaling the mantissa by a power of ten and rounding it are both exact
      # bullet 5:
      mantissa = Utils.decimal_digits(adjusted_number)
      exponent = nil
      if pic[:minimum_exponent_size] != 0
        # mantissa * 10^exponent = adjustedNumber, with scalingFactor digits before the decimal point of the
        # mantissa.  If the number is zero, the mantissa and the exponent are both zero
        exponent = mantissa[:digits] == '0' ? 0 : mantissa[:digits].length + mantissa[:exponent] - pic[:scaling_factor]
        mantissa[:exponent] -= exponent
      end
      # bullet 6:
      rounded_number = Utils.round_decimal_digits(mantissa, pic[:maximum_factional_part_size])
      if !exponent.nil? && rounded_number[:digits] != '0' &&
         rounded_number[:digits].length + rounded_number[:exponent] > pic[:scaling_factor]
        # rounding has carried the mantissa up to 10^scalingFactor, so divide it by ten
        rounded_number = Utils.round_decimal_digits({:digits => rounded_number[:digits], :exponent => rounded_number[:exponent] - 1},
                                                    pic[:maximum_factional_part_size])
        exponent += 1
      end
      # bullet 7:
      make_string = lambda do |str|
        if zero_digit != '0'
          str = str.each_char.map do |digit|
            if digit.between?('0', '9')
              decimal_digit_family[digit.ord - 48]
            else
              digit
            end
          end.join
        end
        str
      end
      string_value = make_string.call(Utils.decimal_digits_to_string(rounded_number, pic[:maximum_factional_part_size]))
      decimal_pos = string_value.index('.')
      string_value = if decimal_pos.nil?
                       string_value + decimal_separator
                     else
                       string_value.sub('.', decimal_separator)
                     end
      string_value = string_value[1..] while string_value[0] == zero_digit
      string_value = string_value[0...-1] while string_value[-1] == zero_digit
      # bullets 8 & 9:
      decimal_pos = string_value.index(decimal_separator)
      pad_left = pic[:minimum_integer_part_size] - decimal_pos
      pad_right = pic[:minimum_factional_part_size] - (string_value.length - decimal_pos - 1)
      string_value = (pad_left.positive? ? zero_digit * pad_left : '') + string_value
      string_value += (pad_right.positive? ? zero_digit * pad_right : '')
      decimal_pos = string_value.index(decimal_separator)
      # bullet 10:
      if pic[:regular_grouping].positive?
        group_count = ((decimal_pos - 1) / pic[:regular_grouping]).floor
        (1..group_count).each do |group|
          pos = decimal_pos - (group * pic[:regular_grouping])
          string_value = [Utils.js_slice(string_value, 0, pos), grouping_separator, Utils.js_slice(string_value, pos)].join
        end
      else
        pic[:integer_part_grouping_positions].each do |pos|
          if decimal_pos > pos
            string_value = [Utils.js_slice(string_value, 0, decimal_pos - pos), grouping_separator,
                            Utils.js_slice(string_value, decimal_pos - pos)].join
            decimal_pos += 1
          end
        end
      end
      # bullet 11:
      decimal_pos = string_value.index(decimal_separator)
      pic[:fractional_part_grouping_positions].each do |pos|
        string_value = [Utils.js_slice(string_value, 0, pos + decimal_pos + 1), grouping_separator,
                        Utils.js_slice(string_value, pos + decimal_pos + 1)].join
      end
      # bullet 12:
      decimal_pos = string_value.index(decimal_separator)
      if !pic[:picture].include?(decimal_separator) || decimal_pos == string_value.length - 1
        string_value = string_value[0...-1]
      end
      # bullet 13:
      unless exponent.nil?
        string_exponent = make_string.call(exponent.abs.to_s)
        pad_left = pic[:minimum_exponent_size] - string_exponent.length
        string_exponent = (zero_digit * pad_left) + string_exponent if pad_left.positive?
        string_value = string_value + properties['exponent-separator'] + (exponent.negative? ? minus_sign : '') + string_exponent
      end
      # bullet 14:
      pic[:prefix] + string_value + pic[:suffix]
    end

    # Converts a number to a string using a specified number base
    # @param value [Numeric] the number to convert
    # @param radix [Numeric] the number base; must be between 2 and 36. Defaults to 10
    # @return [String] the converted string
    def format_base(value, radix)
      # undefined inputs always return undefined
      return nil if value.nil?

      value = round(value)

      radix = if radix.nil?
                10
              else
                round(radix)
              end

      raise Jsonata::Error.new('D3100', :value => radix) if radix < 2 || radix > 36

      value.to_i.to_s(radix.to_i)
    end

    # Cast argument to number
    # @param arg [Object] Argument
    # @return [Numeric] numeric value of argument
    def number(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      if arg.kind_of?(Numeric)
        # already a number
        arg
      elsif arg.kind_of?(String) && /\A-?[0-9]+(\.[0-9]+)?([Ee][-+]?[0-9]+)?\z/.match?(arg) && Float(arg).finite?
        Utils.normalize_number(Float(arg))
      elsif arg.kind_of?(String) && /\A(0[xX][0-9A-Fa-f]+)|(0[oO][0-7]+)|(0[bB][0-1]+)\z/.match?(arg)
        Utils.js_number(arg)
      elsif arg == true
        # boolean true casts to 1
        1
      elsif arg == false
        # boolean false casts to 0
        0
      else
        raise Jsonata::Error.new('D3030', :value => arg, :index => 1)
      end
    end

    # Absolute value of a number
    # @param arg [Numeric] Argument
    # @return [Numeric] absolute value of argument
    def abs(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      arg.abs
    end

    # Rounds a number down to integer
    # @param arg [Numeric] Argument
    # @return [Numeric] rounded integer
    def floor(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      Utils.normalize_number(arg.to_f.floor.to_f)
    end

    # Rounds a number up to integer
    # @param arg [Numeric] Argument
    # @return [Numeric] rounded integer
    def ceil(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      Utils.normalize_number(arg.to_f.ceil.to_f)
    end

    # Round to half even
    # @param arg [Numeric] Argument
    # @param precision [Numeric] number of decimal places
    # @return [Numeric] rounded integer
    def round(arg, precision = nil)
      # undefined inputs always return undefined
      return nil if arg.nil?

      if Utils.truthy?(precision)
        # shift the decimal place - this needs to be done in a string since multiplying
        # by a power of ten can introduce floating point precision errors which mess up
        # this rounding algorithm - See 'Decimal rounding' in
        # https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Global_Objects/Math/round
        # Shift
        value = Utils.number_to_s(arg).split('e')
        arg = Float("#{value[0]}e#{value[1] ? (value[1].to_i + precision) : precision}")
      end

      # round up to nearest int
      result = (arg.to_r + Rational(1, 2)).floor
      diff = result - arg.to_f
      if diff.abs == 0.5 && (result % 2).abs == 1 # rubocop:disable Lint/FloatComparison -- exact comparison, as in JS
        # rounded the wrong way - adjust to nearest even number
        result -= 1
      end
      if Utils.truthy?(precision)
        # Shift back
        value = Utils.number_to_s(result).split('e')
        result = Float("#{value[0]}e#{value[1] ? (value[1].to_i - precision) : -precision}")
      end
      # JSON doesn't do -0
      Utils.normalize_number(result.zero? ? 0 : result)
    end

    # Square root of number
    # @param arg [Numeric] Argument
    # @return [Numeric] square root
    def sqrt(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      raise Jsonata::Error.new('D3060', :index => 1, :value => arg) if arg.negative?

      Utils.normalize_number(Math.sqrt(arg))
    end

    # Raises number to the power of the second number
    # @param arg [Numeric] the base
    # @param exp [Numeric] the exponent
    # @return [Numeric] rounded integer
    def power(arg, exp)
      # undefined inputs always return undefined
      return nil if arg.nil?

      result = if arg.negative? && !Utils.integer?(exp)
                 Float::NAN
               else
                 arg.to_f**exp.to_f
               end

      raise Jsonata::Error.new('D3061', :index => 1, :value => arg, :exp => exp) unless result.finite?

      Utils.normalize_number(result)
    end

    # Returns a random number 0 <= n < 1
    # @return [Numeric] random number
    def random
      Kernel.rand
    end

    # Evaluate an input and return a boolean
    # @param arg [Object] Arguments
    # @return [Boolean] Boolean
    def boolean(arg)
      # cast arg to its effective boolean value
      # boolean: unchanged
      # string: zero-length -> false; otherwise -> true
      # number: 0 -> false; otherwise -> true
      # null -> false
      # array: empty -> false; length > 1 -> true
      # object: empty -> false; non-empty -> true
      # function -> false

      # undefined inputs always return undefined
      return nil if arg.nil?

      result = false
      if arg.kind_of?(Array)
        if arg.length == 1
          result = boolean(arg[0])
        elsif arg.length > 1
          trues = arg.select { |val| boolean(val) }
          result = !trues.empty?
        end
      elsif arg.kind_of?(String)
        result = true unless arg.empty?
      elsif Utils.numeric?(arg)
        result = true unless arg.zero?
      elsif arg.kind_of?(Hash)
        result = true unless Utils.keys(arg).empty?
      elsif arg == true
        result = true
      end
      result
    end

    # returns the Boolean NOT of the arg
    # @param arg [Object] argument
    # @return [Boolean] NOT arg
    def not(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      !boolean(arg)
    end

    # Helper function to build the arguments to be supplied to the function arg of the
    # HOFs map, filter, each, sift and single
    # @param func [Lambda, NativeFunction, Proc] the function to be invoked
    # @param arg1 [Object] the first (required) arg - the value
    # @param arg2 [Object] the second (optional) arg - the position (index or key)
    # @param arg3 [Object] the third (optional) arg - the whole structure (array or object)
    # @return [Array] the argument list
    def hof_func_args(func, arg1, arg2, arg3)
      func_args = [arg1] # the first arg (the value) is required
      # the other two are optional - only supply it if the function can take it
      length = Utils.get_function_arity(func)
      func_args.push(arg2) if length >= 2
      func_args.push(arg3) if length >= 3
      func_args
    end

    # Create a map from an array of arguments
    # @param arr [Array] array to map over
    # @param func [Lambda, NativeFunction, Proc] function to apply
    # @return [Array] Map array
    def map(arr, func)
      # undefined inputs always return undefined
      return nil if arr.nil?

      result = create_sequence
      # do the map - iterate over the arrays, and invoke func
      arr.each_with_index do |item, i|
        func_args = hof_func_args(func, item, i, arr)
        # invoke func
        res = call_function(func, func_args)
        result.push(res) unless res.nil?
      end

      result
    end

    # Create a map from an array of arguments
    # @param arr [Array] array to filter
    # @param func [Lambda, NativeFunction, Proc] predicate function
    # @return [Array] Map array
    def filter(arr, func)
      # undefined inputs always return undefined
      return nil if arr.nil?

      result = create_sequence

      arr.each_with_index do |entry, i|
        func_args = hof_func_args(func, entry, i, arr)
        # invoke func
        res = call_function(func, func_args)
        result.push(entry) if boolean(res)
      end

      result
    end

    # Given an array, find the single element matching a specified condition
    # Throws an exception if the number of matching elements is not exactly one
    # @param arr [Array] array to filter
    # @param func [Lambda, NativeFunction, Proc] predicate function
    # @return [Object] Matching element
    def single(arr, func)
      # undefined inputs always return undefined
      return nil if arr.nil?

      has_found_match = false
      result = nil

      arr.each_with_index do |entry, i|
        positive_result = true
        unless func.nil?
          func_args = hof_func_args(func, entry, i, arr)
          # invoke func
          res = call_function(func, func_args)
          positive_result = boolean(res)
        end
        next unless positive_result

        raise Jsonata::Error.new('D3138', :index => i) if has_found_match

        result = entry
        has_found_match = true
      end

      raise Jsonata::Error.new('D3139') unless has_found_match

      result
    end

    # Convolves (zips) each value from a set of arrays
    # @param args [Array] arrays to zip
    # @return [Array] Zipped array
    def zip(*args)
      # this can take a variable number of arguments
      result = []
      # length of the shortest array
      length = args.map { |arg| arg.kind_of?(Array) ? arg.length : 0 }.min || 0
      (0...length).each do |i|
        tuple = args.map { |arg| arg[i] }
        result.push(tuple)
      end
      result
    end

    # Fold left function
    # @param sequence [Array] Sequence
    # @param func [Lambda, NativeFunction, Proc] Function
    # @param init [Object] Initial value
    # @return [Object] Result
    def fold_left(sequence, func, init)
      # undefined inputs always return undefined
      return nil if sequence.nil?

      arity = Utils.get_function_arity(func)
      raise Jsonata::Error.new('D3050', :index => 1) if arity < 2

      if init.nil? && !sequence.empty?
        result = sequence[0]
        index = 1
      else
        result = init
        index = 0
      end

      while index < sequence.length
        args = [result, sequence[index]]
        args.push(index) if arity >= 3
        args.push(sequence) if arity >= 4
        result = call_function(func, args)
        index += 1
      end

      result
    end

    # Return keys for an object
    # @param arg [Object] Object
    # @return [Array] Array of keys
    def keys(arg)
      result = create_sequence

      if arg.kind_of?(Array)
        # merge the keys of all of the items in the array
        merge = {}
        arg.each do |item|
          keys(item).each do |key|
            merge[key] = true
          end
        end
        result = keys(merge)
      elsif arg.kind_of?(Hash)
        Utils.keys(arg).each { |key| result.push(key) }
      end
      result
    end

    # Return value from an object for a given key
    # @param input [Object] Object/Array
    # @param key [String] Key in object
    # @return [Object] Value of key in object
    def lookup(input, key)
      # lookup the 'name' item in the input
      result = nil
      if input.kind_of?(Array)
        result = create_sequence
        input.each do |item|
          res = lookup(item, key)
          next if res.nil?

          if res.kind_of?(Array)
            res.each { |val| result.push(val) }
          else
            result.push(res)
          end
        end
      elsif input.kind_of?(Hash) && input.key?(key)
        result = input[key]
      end
      result
    end

    # Append second argument to first
    # @param arg1 [Array, Object] First argument
    # @param arg2 [Array, Object] Second argument
    # @return [Object] Appended arguments
    def append(arg1, arg2)
      # disregard undefined args
      return arg2 if arg1.nil?
      return arg1 if arg2.nil?

      # if either argument is not an array, make it so
      arg1 = create_sequence(arg1) unless arg1.kind_of?(Array)
      arg2 = [arg2] unless arg2.kind_of?(Array)
      size = arg1.length + arg2.length
      raise Jsonata::Error.new('D2015', :value => size) if options && options[:sequence] && size > options[:sequence]

      Array.new(arg1).concat(arg2)
    end

    # Determines if the argument is undefined
    # @param arg [Object] argument
    # @return [Boolean] False if argument undefined, otherwise true
    def exists(arg)
      !arg.nil?
    end

    # Splits an object into an array of object with one property each
    # @param arg [Object] the object to split
    # @return [Object] the array
    def spread(arg)
      result = create_sequence

      if arg.kind_of?(Array)
        # spread all of the items in the array
        arg.each do |item|
          result = append(result, spread(item))
        end
      elsif arg.kind_of?(Hash)
        Utils.keys(arg).each do |key|
          result.push({key => arg[key]})
        end
      else
        result = arg
      end
      result
    end

    # Merges an array of objects into a single object.  Duplicate properties are
    # overridden by entries later in the array
    # @param arg [Object] the objects to merge
    # @return [Object] the object
    def merge(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      result = {}

      arg.each do |obj|
        Utils.keys(obj).each do |prop|
          result[prop] = obj[prop]
        end
      end
      result
    end

    # Reverses the order of items in an array
    # @param arr [Array] the array to reverse
    # @return [Array] the reversed array
    def reverse(arr)
      # undefined inputs always return undefined
      return nil if arr.nil?

      return arr if arr.length <= 1

      Array.new(arr).reverse
    end

    # @param obj [Object] the input object to iterate over
    # @param func [Object] the function to apply to each key/value pair
    # @return [Array] the resultant array
    def each(obj, func)
      result = create_sequence

      Utils.keys(obj).each do |key|
        func_args = hof_func_args(func, obj[key], key, obj)
        # invoke func
        val = call_function(func, func_args)
        result.push(val) unless val.nil?
      end

      result
    end

    # @param message [String] the message to attach to the error
    # @raise [Jsonata::Error] custom error with code 'D3137'
    def error(message)
      raise Jsonata::Error.new('D3137', :message => Utils.truthy?(message) ? message : '$error() function evaluated')
    end

    # @param condition [Boolean] the condition to evaluate
    # @param message [String] the message to attach to the error
    # @raise [Jsonata::Error] custom error with code 'D3137'
    # @return [nil] undefined
    def assert(condition, message)
      unless condition
        raise Jsonata::Error.new('D3141', :message => Utils.truthy?(message) ? message : '$assert() statement failed')
      end

      nil
    end

    # @param value [Object] the input to which the type will be checked
    # @return [String] the type of the input
    def type(value)
      return nil if value.nil?
      return 'null' if value == NULL
      return 'number' if Utils.numeric?(value)
      return 'string' if value.kind_of?(String)
      return 'boolean' if [true, false].include?(value)
      return 'array' if value.kind_of?(Array)
      return 'function' if Utils.function?(value)

      'object'
    end

    # Implements the merge sort (stable) with optional comparator function
    #
    # @param arr [Array] the array to sort
    # @param comparator [Object] comparator function
    # @return [Array] sorted array
    def sort(arr, comparator)
      # undefined inputs always return undefined
      return nil if arr.nil?

      return arr if arr.length <= 1

      if comparator.nil?
        # inject a default comparator - only works for numeric or string arrays
        unless Utils.array_of_numbers?(arr) || Utils.array_of_strings?(arr)
          raise Jsonata::Error.new('D3070', :index => 1)
        end

        comp = ->(a, b) { a > b }
      else
        # for internal usage of functionSort (i.e. order-by syntax)
        comp = comparator
      end

      # iterative merge: a recursive merge would hold one pending call and one copy of the remaining
      # input per element, so memory would grow quadratically with the array size
      merge = lambda do |l, r|
        merged = []
        left_index = 0
        right_index = 0
        while left_index < l.length && right_index < r.length
          if call_function(comp, [l[left_index], r[right_index]]) # invoke the comparator function
            # if it returns true - swap left and right
            merged.push(r[right_index])
            right_index += 1
          else
            # otherwise keep the same order
            merged.push(l[left_index])
            left_index += 1
          end
        end
        while left_index < l.length
          merged.push(l[left_index])
          left_index += 1
        end
        while right_index < r.length
          merged.push(r[right_index])
          right_index += 1
        end
        merged
      end

      msort = lambda do |array|
        if !array.kind_of?(Array) || array.length <= 1
          array
        else
          middle = (array.length / 2).floor
          left = array[0, middle]
          right = array[middle..]
          left = msort.call(left)
          right = msort.call(right)
          merge.call(left, right)
        end
      end

      msort.call(arr)
    end

    # Randomly shuffles the contents of an array
    # @param arr [Array] the input array
    # @return [Array] the shuffled array
    def shuffle(arr)
      # undefined inputs always return undefined
      return nil if arr.nil?

      return arr if arr.length <= 1

      # shuffle using the 'inside-out' variant of the Fisher-Yates algorithm
      result = Array.new(arr.length)
      arr.each_with_index do |item, i|
        j = (Kernel.rand * (i + 1)).floor # random integer such that 0 <= j <= i
        result[i] = result[j] if i != j
        result[j] = item
      end

      result
    end

    # Returns the values that appear in a sequence, with duplicates eliminated.
    # @param arr [Array] An array or sequence of values
    # @return [Array] sequence of distinct values
    def distinct(arr)
      # undefined inputs always return undefined
      return nil if arr.nil?

      return arr if !arr.kind_of?(Array) || arr.length <= 1

      results = Utils.sequence?(arr) ? create_sequence : []

      arr.each do |value|
        # is this value already in the result sequence?
        includes = results.any? { |result| Utils.deep_equal?(value, result) }
        results.push(value) unless includes
      end
      results
    end

    # Applies a predicate function to each key/value pair in an object, and returns an object containing
    # only the key/value pairs that passed the predicate
    #
    # @param arg [Object] the object to be sifted
    # @param func [Object] the predicate function (lambda or native)
    # @return [Object] sifted object
    def sift(arg, func)
      result = {}

      Utils.keys(arg).each do |item|
        entry = arg[item]
        func_args = hof_func_args(func, entry, item, arg)
        # invoke func
        res = call_function(func, func_args)
        result[item] = entry if boolean(res)
      end

      # empty objects should be changed to undefined
      result = nil if Utils.keys(result).empty?

      result
    end

    private

    # Equivalent of `func.apply(this, args)` in jsonata-js
    def call_function(func, args)
      if func.kind_of?(Lambda)
        func.apply(self, args)
      else
        Utils.invoke(func, args)
      end
    end
  end
end
