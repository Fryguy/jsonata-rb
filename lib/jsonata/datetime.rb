# frozen_string_literal: true

# (c) Copyright IBM Corp. 2018 All Rights Reserved
#   Project name: JSONata
#   This project is licensed under the MIT License, see LICENSE

# Port of jsonata-js src/datetime.js
#
# DateTime formatting and parsing functions
# Implements the xpath-functions format-date-time specification
#
# JavaScript Date objects are represented by UTC Ruby Time objects.

module Jsonata
  module DateTime
    FEW = %w[Zero One Two Three Four Five Six Seven Eight Nine Ten
             Eleven Twelve Thirteen Fourteen Fifteen Sixteen Seventeen Eighteen Nineteen].freeze
    ORDINALS = %w[Zeroth First Second Third Fourth Fifth Sixth Seventh Eighth Ninth Tenth
                  Eleventh Twelfth Thirteenth Fourteenth Fifteenth Sixteenth Seventeenth Eighteenth Nineteenth].freeze
    DECADES = %w[Twenty Thirty Forty Fifty Sixty Seventy Eighty Ninety Hundred].freeze
    MAGNITUDES = %w[Thousand Million Billion Trillion].freeze

    # converts a number into english words
    # @param value - the value to format
    # @param ordinal - ordinal or cardinal form
    # @returns representation in words
    def number_to_words(value, ordinal)
      lookup = nil
      lookup = lambda do |num, prev, ord|
        words = +''
        if num <= 19
          words = (prev ? ' and ' : '') + (ord ? ORDINALS[num] : FEW[num])
        elsif num < 100
          tens = Utils.js_floor(num / 10.0)
          remainder = num % 10
          words = (prev ? ' and ' : '') + DECADES[tens - 2]
          if remainder.positive?
            words += "-#{lookup.call(remainder, false, ord)}"
          elsif ord
            words = "#{words[0...-1]}ieth"
          end
        elsif num < 1000
          hundreds = Utils.js_floor(num / 100.0)
          remainder = num % 100
          words = "#{', ' if prev}#{FEW[hundreds]} Hundred"
          if remainder.positive?
            words += lookup.call(remainder, true, ord)
          elsif ord
            words += 'th'
          end
        else
          mag = (Math.log10(num) / 3).floor
          mag = MAGNITUDES.length if mag > MAGNITUDES.length # the largest word
          factor = 10.0**(mag * 3)
          mant = Utils.js_floor(num / factor)
          remainder = Utils.normalize_number(num - (mant * factor))
          words = "#{', ' if prev}#{lookup.call(mant, false, false)} #{MAGNITUDES[mag - 1]}"
          if remainder.positive?
            words += lookup.call(remainder, true, ord)
          elsif ord
            words += 'th'
          end
        end
        words
      end

      lookup.call(value, false, ordinal)
    end

    WORD_VALUES = {}.tap do |word_values|
      FEW.each_with_index do |word, index|
        word_values[word.downcase] = index
      end
      ORDINALS.each_with_index do |word, index|
        word_values[word.downcase] = index
      end
      DECADES.each_with_index do |word, index|
        lword = word.downcase
        word_values[lword] = (index + 2) * 10
        word_values["#{lword[0, word.length - 1]}ieth"] = word_values[lword]
      end
      word_values['hundredth'] = 100
      MAGNITUDES.each_with_index do |word, index|
        lword = word.downcase
        val = 10**((index + 1) * 3)
        word_values[lword] = val
        word_values["#{lword}th"] = val
      end
    end.freeze

    # Converts a number in english words to numeric value
    # @param text - the number in words
    # @returns the numeric value
    def words_to_number(text)
      parts = text.split(/,\s|\sand\s|[\s\\-]/, -1)
      values = parts.map { |part| WORD_VALUES[part] }
      segs = [0]
      values.each do |value|
        if !value.nil? && value < 100
          top = segs.pop
          if top >= 1000
            segs.push(top)
            top = 0
          end
          segs.push(top + value)
        else
          segs.push(value.nil? ? Float::NAN : segs.pop * value.to_f)
        end
      end
      Utils.normalize_number(segs.reduce(0) { |a, b| a + b })
    end

    ROMAN_NUMERALS = [
      [1000, 'm'],
      [900, 'cm'],
      [500, 'd'],
      [400, 'cd'],
      [100, 'c'],
      [90, 'xc'],
      [50, 'l'],
      [40, 'xl'],
      [10, 'x'],
      [9, 'ix'],
      [5, 'v'],
      [4, 'iv'],
      [1, 'i']
    ].freeze

    ROMAN_VALUES = {'M' => 1000, 'D' => 500, 'C' => 100, 'L' => 50, 'X' => 10, 'V' => 5, 'I' => 1}.freeze

    # converts a number to roman numerals
    # @param value - the number
    # @returns the number in roman numerals
    def decimal_to_roman(value)
      ROMAN_NUMERALS.each do |numeral|
        return numeral[1] + decimal_to_roman(value - numeral[0]) if value >= numeral[0]
      end
      ''
    end

    # converts roman numerals to a number
    # @param roman - roman number
    # @returns the numeric value
    def roman_to_decimal(roman)
      decimal = 0
      max = 1
      (roman.length - 1).downto(0) do |i|
        digit = roman[i]
        value = ROMAN_VALUES[digit]
        if value < max
          decimal -= value
        else
          max = value
          decimal += value
        end
      end
      decimal
    end

    # converts a number to spreadsheet style letters
    # @param value - the number
    # @param a_char - the character representing the start of the sequence, e.g. 'A'
    # @returns the letters
    def decimal_to_letters(value, a_char)
      letters = []
      a_code = a_char.ord
      while value.positive?
        letters.unshift((((value - 1) % 26) + a_code).chr(Encoding::UTF_8))
        value = ((value - 1) / 26).floor
      end
      letters.join
    end

    # converts spreadsheet style letters to a number
    # @param letters - the letters
    # @param a_char - the character representing the start of the sequence, e.g. 'A'
    # @returns the numeric value
    def letters_to_decimal(letters, a_char)
      a_code = a_char.ord
      decimal = 0
      letters.length.times do |i|
        decimal += (letters[letters.length - i - 1].ord - a_code + 1) * (26**i)
      end
      decimal
    end

    # Formats an integer as specified by the XPath fn:format-integer function
    # See https://www.w3.org/TR/xpath-functions-31/#func-format-integer
    # @param value - the number to be formatted
    # @param picture - the picture string that specifies the format
    # @returns the formatted number
    def format_integer(value, picture)
      return nil if value.nil?

      value = Utils.js_floor(value)

      format = analyse_integer_picture(picture)
      _format_integer(value, format)
    end

    FORMATS = {
      :DECIMAL  => 'decimal',
      :LETTERS  => 'letters',
      :ROMAN    => 'roman',
      :WORDS    => 'words',
      :SEQUENCE => 'sequence'
    }.freeze

    TCASE = {
      :UPPER => 'upper',
      :LOWER => 'lower',
      :TITLE => 'title'
    }.freeze

    # formats an integer using a preprocessed representation of the picture string
    # @param value - the number to be formatted
    # @param format - the preprocessed representation of the pucture string
    # @returns the formatted number
    def _format_integer(value, format)
      formatted_integer = nil
      negative = value.negative?
      value = value.abs
      case format[:primary]
      when FORMATS[:LETTERS]
        formatted_integer = decimal_to_letters(value, format[:case] == TCASE[:UPPER] ? 'A' : 'a')
      when FORMATS[:ROMAN]
        formatted_integer = decimal_to_roman(value)
        formatted_integer = formatted_integer.upcase if format[:case] == TCASE[:UPPER]
      when FORMATS[:WORDS]
        formatted_integer = number_to_words(value, format[:ordinal])
        if format[:case] == TCASE[:UPPER]
          formatted_integer = formatted_integer.upcase
        elsif format[:case] == TCASE[:LOWER]
          formatted_integer = formatted_integer.downcase
        end
      when FORMATS[:DECIMAL]
        formatted_integer = Utils.number_to_s(value)
        # TODO use functionPad
        pad_length = format[:mandatory_digits] - formatted_integer.length
        if pad_length.positive?
          padding = '0' * pad_length
          formatted_integer = padding + formatted_integer
        end
        if format[:zero_code] != 0x30
          formatted_integer = Utils.string_to_array(formatted_integer).map do |code|
            (code.ord + format[:zero_code] - 0x30).chr(Encoding::UTF_8)
          end.join
        end
        # insert the grouping-separator-signs, if any
        if format[:regular]
          n = ((formatted_integer.length - 1) / format[:grouping_separators][:position]).floor
          n.downto(1) do |ii|
            pos = formatted_integer.length - (ii * format[:grouping_separators][:position])
            formatted_integer = formatted_integer[0, pos] + format[:grouping_separators][:character] +
                                formatted_integer[pos..]
          end
        else
          format[:grouping_separators].reverse_each do |separator|
            pos = formatted_integer.length - separator[:position]
            formatted_integer = formatted_integer[0, pos] + separator[:character] + formatted_integer[pos..]
          end
        end

        if format[:ordinal]
          suffix123 = {'1' => 'st', '2' => 'nd', '3' => 'rd'}
          last_digit = formatted_integer[-1]
          suffix = suffix123[last_digit]
          suffix = 'th' if !suffix || (formatted_integer.length > 1 && formatted_integer[-2] == '1')
          formatted_integer += suffix
        end
      when FORMATS[:SEQUENCE]
        raise Jsonata::Error.new('D3130', :value => format[:token])
      end
      formatted_integer = "-#{formatted_integer}" if negative

      formatted_integer
    end

    # TODO what about decimal groups in the unicode supplementary planes (surrogate pairs) ???
    DECIMAL_GROUPS = [0x30, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, 0x0B66, 0x0BE6, 0x0C66, 0x0CE6,
                      0x0D66, 0x0DE6, 0x0E50, 0x0ED0, 0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80,
                      0x1A90, 0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, 0xA9D0, 0xA9F0, 0xAA50, 0xABF0,
                      0xFF10].freeze

    # preprocesses the picture string
    # @param picture - picture string
    # @returns analysed picture
    def analyse_integer_picture(picture)
      format = {
        :type    => 'integer',
        :primary => FORMATS[:DECIMAL],
        :case    => TCASE[:LOWER],
        :ordinal => false
      }

      semicolon = picture.rindex(';')
      if semicolon.nil?
        primary_format = picture
      else
        primary_format = picture[0, semicolon]
        format_modifier = picture[(semicolon + 1)..]
        format[:ordinal] = true if format_modifier[0] == 'o'
      end

      case primary_format
      when 'A', 'a'
        format[:case] = TCASE[:UPPER] if primary_format == 'A'
        format[:primary] = FORMATS[:LETTERS]
      when 'I', 'i'
        format[:case] = TCASE[:UPPER] if primary_format == 'I'
        format[:primary] = FORMATS[:ROMAN]
      when 'W'
        format[:case] = TCASE[:UPPER]
        format[:primary] = FORMATS[:WORDS]
      when 'Ww'
        format[:case] = TCASE[:TITLE]
        format[:primary] = FORMATS[:WORDS]
      when 'w'
        format[:primary] = FORMATS[:WORDS]
      else
        # this is a decimal-digit-pattern if it contains a decimal digit (from any unicode decimal digit group)
        zero_code = nil
        mandatory_digits = 0
        optional_digits = 0
        grouping_separators = []
        separator_position = 0
        # reverse the array to determine positions of grouping-separator-signs
        format_codepoints = Utils.string_to_array(primary_format).map(&:ord).reverse
        format_codepoints.each do |code_point|
          # step though each char in the picture to determine the digit group
          digit = false
          DECIMAL_GROUPS.each do |group|
            next unless code_point.between?(group, group + 9)

            # codepoint is part of this decimal group
            digit = true
            mandatory_digits += 1
            separator_position += 1
            if zero_code.nil?
              zero_code = group
            elsif group != zero_code
              # error! different decimal groups in the same pattern
              raise Jsonata::Error.new('D3131')
            end
            break
          end
          next if digit

          if code_point == 0x23 # # - optional-digit-sign
            separator_position += 1
            optional_digits += 1
          else
            # neither a decimal-digit-sign ot optional-digit-sign, assume it is a grouping-separator-sign
            grouping_separators.push({
                                       :position  => separator_position,
                                       :character => code_point.chr(Encoding::UTF_8)
                                     })
          end
        end
        if mandatory_digits.positive?
          format[:primary] = FORMATS[:DECIMAL]
          # TODO validate decimal-digit-pattern

          # the decimal digit family (codepoint offset)
          format[:zero_code] = zero_code
          # the number of mandatory digits
          format[:mandatory_digits] = mandatory_digits
          # the number of optional digits
          format[:optional_digits] = optional_digits
          # grouping separator template
          # are the grouping-separator-signs 'regular'?
          regular_repeat = lambda do |separators|
            # are the grouping positions regular? i.e. same interval between each of them
            # is there at least one separator?
            return 0 if separators.empty?

            # are all the characters the same?
            sep_char = separators[0][:character]
            separators.drop(1).each do |separator|
              return 0 if separator[:character] != sep_char
            end
            # are they equally spaced?
            indexes = separators.map { |separator| separator[:position] }
            # find the greatest common divisor of all the positions
            factor = indexes.reduce { |a, b| a.gcd(b) }
            # is every position separated by this divisor? If so, it's regular
            (1..indexes.length).each do |index|
              return 0 unless indexes.include?(index * factor)
            end
            factor
          end

          regular = regular_repeat.call(grouping_separators)
          if regular.positive?
            format[:regular] = true
            format[:grouping_separators] = {
              :position  => regular,
              :character => grouping_separators[0][:character]
            }
          else
            format[:regular] = false
            format[:grouping_separators] = grouping_separators
          end

        else
          # this is a 'numbering sequence' which the spec says is implementation-defined
          # this implementation doesn't support any numbering sequences at the moment.
          format[:primary] = FORMATS[:SEQUENCE]
          format[:token] = primary_format
        end
      end

      format
    end

    DEFAULT_PRESENTATION_MODIFIERS = {
      'Y' => '1', 'M' => '1', 'D' => '1', 'd' => '1', 'F' => 'n', 'W' => '1', 'w' => '1', 'X' => '1', 'x' => '1',
      'H' => '1', 'h' => '1', 'P' => 'n', 'm' => '01', 's' => '01', 'f' => '1', 'Z' => '01:01', 'z' => '01:01',
      'C' => 'n', 'E' => 'n'
    }.freeze

    # Section 9.8.4.1 the format specifier is an array of string literals and variable markers
    # analyse the date-time picture string
    # @param picture - picture string
    # @returns the analysed string
    def analyse_date_time_picture(picture)
      spec = []
      format = {
        :type  => 'datetime',
        :parts => spec
      }
      add_literal = lambda do |start, end_pos|
        if end_pos > start
          literal = picture[start...end_pos]
          # replace any doubled ]] with single ]
          # what if there are instances of single ']' ? - the spec doesn't say
          literal = literal.gsub(']]', ']')
          spec.push({:type => 'literal', :value => literal})
        end
      end

      start = 0
      pos = 0
      while pos < picture.length
        if picture[pos] == '['
          # check it's not a doubled [[
          if picture[pos + 1] == '['
            # literal [
            add_literal.call(start, pos)
            spec.push({:type => 'literal', :value => '['})
            pos += 2
            start = pos
            next
          end
          # start of variable marker
          # push the string literal (if there is one) onto the array
          add_literal.call(start, pos)
          start = pos
          # search forward to closing ]
          pos = picture.index(']', start)
          # TODO handle error case if pos === -1
          if pos.nil?
            # error - no closing bracket
            raise Jsonata::Error.new('D3135')
          end

          marker = picture[(start + 1)...pos]
          # whitespace within a variable marker is ignored (i.e. remove it)
          marker = marker.gsub(/\s+/, '')
          defn = {
            :type      => 'marker',
            :component => marker[0] || '' # 1. The component specifier is always present and is always a single letter.
          }
          comma = marker.rindex(',') # 2. The width modifier may be recognized by the presence of a comma
          pres_mod = nil # the presentation modifiers
          if comma.nil?
            pres_mod = marker[1..] || ''
          else
            # Section 9.8.4.2 The Width Modifier
            width_mod = marker[(comma + 1)..]
            dash = width_mod.index('-')
            min = nil
            max = nil
            parse_width = lambda do |wm|
              if wm.nil? || wm == '*'
                nil
              else
                # TODO validate wm is an unsigned int
                Utils.parse_int(wm)
              end
            end
            if dash.nil?
              min = width_mod
            else
              min = width_mod[0, dash]
              max = width_mod[(dash + 1)..]
            end
            width_def = {
              :min => parse_width.call(min),
              :max => parse_width.call(max)
            }
            defn[:width] = width_def
            pres_mod = marker[1...comma] || ''
          end
          if pres_mod.length == 1
            defn[:presentation1] = pres_mod # first presentation modifier
            # TODO validate the first presentation modifier - it's either N, n, Nn or it passes analyseIntegerPicture
          elsif pres_mod.length > 1
            last_char = pres_mod[-1]
            if 'atco'.include?(last_char)
              defn[:presentation2] = last_char
              defn[:ordinal] = true if last_char == 'o'
              # 'c' means 'cardinal' and is the default (i.e. not 'ordinal')
              # 'a' & 't' are ignored (not sure of their relevance to English numbering)
              defn[:presentation1] = pres_mod[0...-1]
            else
              defn[:presentation1] = pres_mod
              # TODO validate the first presentation modifier - it's either N, n, Nn or it passes analyseIntegerPicture,
              # doesn't use ] as grouping separator, and if grouping separator is , then must have width modifier
            end
          else
            # no presentation modifier specified - apply the default;
            defn[:presentation1] = DEFAULT_PRESENTATION_MODIFIERS[defn[:component]]
          end
          if defn[:presentation1].nil?
            # unknown component specifier
            raise Jsonata::Error.new('D3132', :value => defn[:component])
          end

          if defn[:presentation1][0] == 'n'
            defn[:names] = TCASE[:LOWER]
          elsif defn[:presentation1][0] == 'N'
            defn[:names] = if defn[:presentation1][1] == 'n'
                             TCASE[:TITLE]
                           else
                             TCASE[:UPPER]
                           end
          elsif 'YMDdFWwXxHhmsf'.include?(defn[:component])
            integer_pattern = defn[:presentation1]
            integer_pattern += ";#{defn[:presentation2]}" if defn[:presentation2]
            defn[:integer_format] = analyse_integer_picture(integer_pattern)
            if defn[:width] && !defn[:width][:min].nil? && (defn[:integer_format][:mandatory_digits] < defn[:width][:min])
              defn[:integer_format][:mandatory_digits] = defn[:width][:min]
            end
            if defn[:component] == 'Y'
              # Section 9.8.4.4
              defn[:n] = -1
              if defn[:width] && !defn[:width][:max].nil?
                defn[:n] = defn[:width][:max]
                defn[:integer_format][:mandatory_digits] = defn[:n]
              else
                w = defn[:integer_format][:mandatory_digits].to_i + defn[:integer_format][:optional_digits].to_i
                defn[:n] = w if w >= 2
              end
            end
            # if the previous part is also an integer with no intervening markup, then its width for parsing must be precisely defined
            previous_part = spec[-1]
            if previous_part && previous_part[:integer_format]
              previous_part[:integer_format][:parse_width] = previous_part[:integer_format][:mandatory_digits]
            end
          end
          if defn[:component] == 'Z' || defn[:component] == 'z'
            defn[:integer_format] = analyse_integer_picture(defn[:presentation1])
          end
          spec.push(defn)
          start = pos + 1
        end
        pos += 1
      end
      add_literal.call(start, pos)
      format
    end

    DAYS = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'].freeze
    MONTHS = %w[January February March April May June July August September October November December].freeze
    MILLIS_IN_A_DAY = 1000 * 60 * 60 * 24

    # Equivalent of Date.UTC(year, month, day, hours, minutes, seconds, millis)
    def self.date_utc(year, month = 0, day = 1, hours = 0, minutes = 0, seconds = 0, millis = 0)
      values = [year, month, day, hours, minutes, seconds, millis]
      return Float::NAN if values.any? { |v| v.nil? || (v.kind_of?(Float) && !v.finite?) }

      year, month, day, hours, minutes, seconds, millis = values.map(&:truncate)
      year += 1900 if year.between?(0, 99)
      year += month.div(12)
      month %= 12
      days = days_from_civil(year, month + 1, 1) + day - 1
      (days * MILLIS_IN_A_DAY) + (hours * 3_600_000) + (minutes * 60_000) + (seconds * 1000) + millis
    end

    # number of days since 1970-01-01 of the given proleptic Gregorian date
    def self.days_from_civil(year, month, day)
      year -= 1 if month <= 2
      era = year.div(400)
      yoe = year - (era * 400)
      doy = (((153 * (month + (month > 2 ? -3 : 9))) + 2) / 5) + day - 1
      doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy
      (era * 146_097) + doe - 719_468
    end

    # Equivalent of new Date(millis)
    def self.new_date(millis)
      Time.at(Rational(millis.truncate, 1000), :in => 'UTC')
    end

    # Equivalent of date.getTime()
    def self.get_time(date)
      (date.to_r * 1000).floor
    end

    # Equivalent of date.getUTCDay() - 0 is Sunday
    def self.get_utc_day(date)
      date.wday
    end

    def start_of_first_week(ym)
      # ISO 8601 defines the first week of the year to be the week that contains the first Thursday
      # XPath F&O extends this same definition for the first week of a month
      # the week starts on a Monday - calculate the millis for the start of the first week
      # millis for given 1st Jan of that year (at 00:00 UTC)
      jan1 = DateTime.date_utc(ym[:year], ym[:month])
      day_of_jan1 = DateTime.get_utc_day(DateTime.new_date(jan1))
      day_of_jan1 = 7 if day_of_jan1.zero?
      # if Jan 1 is Fri, Sat or Sun, then add the number of days (in millis) to jan1 to get the start of week 1
      day_of_jan1 > 4 ? jan1 + ((8 - day_of_jan1) * MILLIS_IN_A_DAY) : jan1 - ((day_of_jan1 - 1) * MILLIS_IN_A_DAY)
    end

    def year_month(year, month)
      {
        :year           => year,
        :month          => month,
        :next_month     => -> { month == 11 ? year_month(year + 1, 0) : year_month(year, month + 1) },
        :previous_month => -> { month.zero? ? year_month(year - 1, 11) : year_month(year, month - 1) },
        :next_year      => -> { year_month(year + 1, month) },
        :previous_year  => -> { year_month(year - 1, month) }
      }
    end

    def delta_weeks(start, end_pos)
      ((end_pos - start) / (MILLIS_IN_A_DAY * 7.0)) + 1
    end

    def get_date_time_fragment(date, component)
      component_value = nil
      case component
      when 'Y' # year
        component_value = date.year
      when 'M' # month in year
        component_value = date.month
      when 'D' # day in month
        component_value = date.day
      when 'd' # day in year
        # millis for given date (at 00:00 UTC)
        today = DateTime.date_utc(date.year, date.month - 1, date.day)
        # millis for given 1st Jan of that year (at 00:00 UTC)
        first_jan = DateTime.date_utc(date.year, 0)
        component_value = ((today - first_jan) / MILLIS_IN_A_DAY) + 1
      when 'F' # day of week
        component_value = DateTime.get_utc_day(date)
        # ISO 8601 defines days 1-7: Mon-Sun
        component_value = 7 if component_value.zero?
      when 'W' # week in year
        this_year = year_month(date.year, 0)
        start_of_week1 = start_of_first_week(this_year)
        today = DateTime.date_utc(this_year[:year], date.month - 1, date.day)
        week = delta_weeks(start_of_week1, today)
        if week > 52
          # might be first week of the following year
          start_of_following_year = start_of_first_week(this_year[:next_year].call)
          week = 1 if today >= start_of_following_year
        elsif week < 1
          # must be end of the previous year
          start_of_previous_year = start_of_first_week(this_year[:previous_year].call)
          week = delta_weeks(start_of_previous_year, today)
        end
        component_value = week.floor
      when 'w' # week in month
        this_month = year_month(date.year, date.month - 1)
        start_of_week1 = start_of_first_week(this_month)
        today = DateTime.date_utc(this_month[:year], this_month[:month], date.day)
        week = delta_weeks(start_of_week1, today)
        if week > 4
          # might be first week of the following month
          start_of_following_month = start_of_first_week(this_month[:next_month].call)
          week = 1 if today >= start_of_following_month
        elsif week < 1
          # must be end of the previous month
          start_of_previous_month = start_of_first_week(this_month[:previous_month].call)
          week = delta_weeks(start_of_previous_month, today)
        end
        component_value = week.floor
      when 'X' # ISO week-numbering year
        # Extension: The F&O spec says nothing about how to access the year associated with the week-of-the-year
        # e.g. Sat 1 Jan 2005 is in the 53rd week of 2004.
        # The 'W' component specifier gives 53, but 'Y' will give 2005.
        # I propose to add 'X' as the component specifier to give the ISO week-numbering year (2004 in this example)
        this_year = year_month(date.year, 0)
        start_of_iso_year = start_of_first_week(this_year)
        end_of_iso_year = start_of_first_week(this_year[:next_year].call)
        now = DateTime.get_time(date)
        component_value = if now < start_of_iso_year
                            this_year[:year] - 1
                          elsif now >= end_of_iso_year
                            this_year[:year] + 1
                          else
                            this_year[:year]
                          end
      when 'x' # ISO week-numbering month
        # Extension: The F&O spec says nothing about how to access the month associated with the week-of-the-month
        # e.g. Sat 1 Jan 2005 is in the 5th week of December 2004.
        # The 'w' component specifier gives 5, but 'W' will give January and 'Y' will give 2005.
        # I propose to add 'x' as the component specifier to give the 'week-numbering' month (December in this example)
        this_month = year_month(date.year, date.month - 1)
        start_of_iso_month = start_of_first_week(this_month)
        next_month = this_month[:next_month].call
        end_of_iso_month = start_of_first_week(next_month)
        now = DateTime.get_time(date)
        component_value = if now < start_of_iso_month
                            this_month[:previous_month].call[:month] + 1
                          elsif now >= end_of_iso_month
                            next_month[:month] + 1
                          else
                            this_month[:month] + 1
                          end
      when 'H' # hour in day (24 hours)
        component_value = date.hour
      when 'h' # hour in half-day (12 hours)
        component_value = date.hour
        component_value %= 12
        component_value = 12 if component_value.zero?
      when 'P' # am/pm marker
        component_value = date.hour >= 12 ? 'pm' : 'am'
      when 'm' # minute in hour
        component_value = date.min
      when 's' # second in minute
        component_value = date.sec
      when 'f' # fractional seconds
        component_value = date.nsec / 1_000_000
      when 'Z', 'z' # timezone
        # since the date object is constructed from epoch millis, the TZ component is always be UTC.
      when 'C' # calendar name
        component_value = 'ISO'
      when 'E' # era
        component_value = 'ISO'
      end
      component_value
    end

    ISO8601_PICTURE = '[Y0001]-[M01]-[D01]T[H01]:[m01]:[s01].[f001][Z01:01t]'

    # formats the date/time as specified by the XPath fn:format-dateTime function
    # @param millis - the timestamp to be formatted, in millis since the epoch
    # @param picture - the picture string that specifies the format
    # @param timezone - the timezone to use
    # @returns the formatted timestamp
    def format_date_time(millis, picture, timezone)
      offset_hours = 0
      offset_minutes = 0

      unless timezone.nil?
        # parse the hour and minute offsets
        # assume for now the format supplied is +hhmm
        offset = Utils.parse_int(timezone) || 0
        offset_hours = (offset / 100.0).floor
        offset_minutes = offset.remainder(100)
      end

      format_component = lambda do |date, marker_spec|
        component_value = get_date_time_fragment(date, marker_spec[:component])

        # Section 9.8.4.3 Formatting Integer-Valued Date/Time Components
        if 'YMDdFWwXxHhms'.include?(marker_spec[:component])
          if marker_spec[:component] == 'Y' && marker_spec[:n] != -1
            # Section 9.8.4.4 Formatting the Year Component
            component_value = marker_spec[:n].nil? ? Float::NAN : component_value % (10**marker_spec[:n])
          end
          if marker_spec[:names]
            if marker_spec[:component] == 'M' || marker_spec[:component] == 'x'
              component_value = MONTHS[component_value - 1]
            elsif marker_spec[:component] == 'F'
              component_value = DAYS[component_value]
            else
              raise Jsonata::Error.new('D3133', :value => marker_spec[:component])
            end
            if marker_spec[:names] == TCASE[:UPPER]
              component_value = component_value.upcase
            elsif marker_spec[:names] == TCASE[:LOWER]
              component_value = component_value.downcase
            end
            if marker_spec[:width] && !marker_spec[:width][:max].nil? &&
               component_value.length > marker_spec[:width][:max]
              component_value = component_value[0, marker_spec[:width][:max]]
            end
          else
            component_value = _format_integer(component_value, marker_spec[:integer_format])
          end
        elsif marker_spec[:component] == 'f'
          # TODO Section 9.8.4.5 Formatting Fractional Seconds
          component_value = _format_integer(component_value, marker_spec[:integer_format])
        elsif marker_spec[:component] == 'Z' || marker_spec[:component] == 'z'
          # Section 9.8.4.6 Formatting timezones
          offset = (offset_hours * 100) + offset_minutes
          if marker_spec[:integer_format][:regular]
            component_value = _format_integer(offset, marker_spec[:integer_format])
          else
            num_digits = marker_spec[:integer_format][:mandatory_digits]
            if [1, 2].include?(num_digits)
              component_value = _format_integer(offset_hours, marker_spec[:integer_format])
              component_value += ":#{format_integer(offset_minutes, '00')}" if offset_minutes != 0
            elsif [3, 4].include?(num_digits)
              component_value = _format_integer(offset, marker_spec[:integer_format])
            else
              raise Jsonata::Error.new('D3134', :value => num_digits)
            end
          end
          component_value = "+#{component_value}" if offset >= 0
          component_value = "GMT#{component_value}" if marker_spec[:component] == 'z'
          component_value = 'Z' if offset.zero? && marker_spec[:presentation2] == 't'
        elsif marker_spec[:component] == 'P'
          # Section 9.8.4.7 Formatting Other Components
          # Formatting P for am/pm
          # getDateTimeFragment() always returns am/pm lower case so check for UPPER here
          component_value = component_value.upcase if marker_spec[:names] == TCASE[:UPPER]
        end
        component_value
      end

      format_spec = if picture.nil?
                      # default to ISO 8601 format
                      analyse_date_time_picture(ISO8601_PICTURE)
                    else
                      analyse_date_time_picture(picture)
                    end

      offset_millis = ((60 * offset_hours) + offset_minutes) * 60 * 1000
      date_time = DateTime.new_date(millis + offset_millis)

      result = +''
      format_spec[:parts].each do |part|
        result << if part[:type] == 'literal'
                    part[:value]
                  else
                    format_component.call(date_time, part).to_s
                  end
      end

      result
    end

    # Generate a regex to parse integers or timestamps
    # @param format_spec - object representing the format
    # @returns regex
    def generate_regex(format_spec)
      matcher = {}
      if format_spec[:type] == 'datetime'
        matcher[:type] = 'datetime'
        matcher[:parts] = format_spec[:parts].map do |part|
          res = {}
          if part[:type] == 'literal'
            res[:regex] = part[:value].gsub(/[.*+?^${}()|\[\]\\]/) { |m| "\\#{m}" }
          elsif part[:component] == 'Z' || part[:component] == 'z'
            # timezone
            separator = nil
            separator = part[:integer_format][:grouping_separators] unless part[:integer_format][:grouping_separators].kind_of?(Array)
            res[:regex] = +''
            res[:regex] << 'GMT' if part[:component] == 'z'
            res[:regex] << '[-+][0-9]+'
            res[:regex] << "#{separator[:character]}[0-9]+" if separator
            res[:parse] = lambda do |value|
              value = value[3..] if part[:component] == 'z' # remove the leading GMT
              offset_hours = 0
              offset_minutes = 0
              if separator
                offset_hours = Utils.parse_int(value[0, value.index(separator[:character])])
                offset_minutes = Utils.parse_int(value[(value.index(separator[:character]) + 1)..])
              else
                # depends on number of digits
                numdigits = value.length - 1
                if numdigits <= 2
                  # just hour offset
                  offset_hours = Utils.parse_int(value)
                else
                  offset_hours = Utils.parse_int(value[0, 3])
                  offset_minutes = Utils.parse_int(value[3..])
                end
              end
              (offset_hours * 60) + offset_minutes
            end
          elsif part[:component] == 'f'
            res[:regex] = '[0-9]+'
            res[:parse] = lambda do |value|
              Float("0.#{value[0, 3]}") * 1000
            end
          elsif part[:integer_format]
            res = generate_regex(part[:integer_format])
          else
            # must be a month or day name
            res[:regex] = '[a-zA-Z]+'
            lookup = {}
            if part[:component] == 'M' || part[:component] == 'x'
              # months
              MONTHS.each_with_index do |name, index|
                if part[:width] && part[:width][:max]
                  lookup[name[0, part[:width][:max]]] = index + 1
                else
                  lookup[name] = index + 1
                end
              end
            elsif part[:component] == 'F'
              # days
              DAYS.each_with_index do |name, index|
                next unless index.positive?

                if part[:width] && part[:width][:max]
                  lookup[name[0, part[:width][:max]]] = index
                else
                  lookup[name] = index
                end
              end
            elsif part[:component] == 'P'
              lookup = {'am' => 0, 'AM' => 0, 'pm' => 1, 'PM' => 1}
            else
              # unsupported 'name' option for this component
              raise Jsonata::Error.new('D3133', :value => part[:component])
            end
            res[:parse] = ->(value) { lookup[value] }
          end
          res[:component] = part[:component]
          res
        end
      else # type === 'integer'
        matcher[:type] = 'integer'
        is_upper = format_spec[:case] == TCASE[:UPPER]

        case format_spec[:primary]
        when FORMATS[:LETTERS]
          matcher[:regex] = is_upper ? '[A-Z]+' : '[a-z]+'
          matcher[:parse] = lambda do |value|
            letters_to_decimal(value, is_upper ? 'A' : 'a')
          end
        when FORMATS[:ROMAN]
          matcher[:regex] = is_upper ? '[MDCLXVI]+' : '[mdclxvi]+'
          matcher[:parse] = lambda do |value|
            roman_to_decimal(is_upper ? value : value.upcase)
          end
        when FORMATS[:WORDS]
          matcher[:regex] = "(?:#{(WORD_VALUES.keys + ['and', '[\\-, ]']).join('|')})+"
          matcher[:parse] = lambda do |value|
            words_to_number(value.downcase)
          end
        when FORMATS[:DECIMAL]
          matcher[:regex] = +'[0-9]'
          matcher[:regex] << if format_spec[:parse_width]
                               "{#{format_spec[:parse_width]}}"
                             else
                               '+'
                             end
          if format_spec[:ordinal]
            # ordinals
            matcher[:regex] << '(?:th|st|nd|rd)'
          end
          matcher[:parse] = lambda do |value|
            digits = value
            if format_spec[:ordinal]
              # strip off the suffix
              digits = value[0...-2]
            end
            # strip out the separators
            if format_spec[:regular]
              digits = digits.split(',', -1).join
            else
              format_spec[:grouping_separators].each do |sep|
                digits = digits.split(sep[:character], -1).join
              end
            end
            if format_spec[:zero_code] != 0x30
              # apply offset
              digits = digits.each_char.map { |char| (char.ord - format_spec[:zero_code] + 0x30).chr(Encoding::UTF_8) }.join
            end
            Utils.parse_int(digits)
          end
        when FORMATS[:SEQUENCE]
          raise Jsonata::Error.new('D3130', :value => format_spec[:token])
        end

      end
      matcher
    end

    # parse a string containing an integer as specified by the picture string
    # @param value - the string to parse
    # @param picture - the picture string
    # @returns the parsed number
    def parse_integer(value, picture)
      return nil if value.nil?

      format_spec = analyse_integer_picture(picture)
      match_spec = generate_regex(format_spec)
      # const fullRegex = '^' + matchSpec.regex + '$';
      # const matcher = new RegExp(fullRegex);
      # TODO validate input based on the matcher regex
      match_spec[:parse].call(value)
    end

    # parse a string containing a timestamp as specified by the picture string
    # @param timestamp - the string to parse
    # @param picture - the picture string
    # @returns the parsed timestamp in millis since the epoch
    def parse_date_time(timestamp, picture)
      format_spec = analyse_date_time_picture(picture)
      match_spec = generate_regex(format_spec)
      full_regex = "\\A#{match_spec[:parts].map { |part| "(#{part[:regex]})" }.join}\\z"

      matcher = Regexp.new(full_regex, Regexp::IGNORECASE) # TODO can cache this against the picture
      info = matcher.match(timestamp)
      return nil if info.nil?

      # validate what we've just parsed - do we have enough information to create a timestamp?
      # rules:
      # The date is specified by one of:
      #    {Y, M, D}    (dateA)
      # or {Y, d}       (dateB)
      # or {Y, x, w, F} (dateC)
      # or {X, W, F}    (dateD)
      # The time is specified by one of:
      #    {H, m, s, f}    (timeA)
      # or {P, h, m, s, f} (timeB)
      # All sets can have an optional Z
      # To create a timestamp (epoch millis) we need both date and time, but we can default missing
      # information according to the following rules:
      # - line up one combination of the above from date, and one from time, most significant value (MSV) to least significant (LSV
      # - for the values that have been captured, if there are any gaps between MSV and LSV, then throw an error
      #     (e.g.) if hour and seconds, but not minutes is given - throw
      #     (e.g.) if month, hour and minutes, but not day-of-month is given - throw
      # - anything right of the LSV should be defaulted to zero
      #     (e.g.) if hour and minutes given, default seconds and fractional seconds to zero
      #     (e.g.) if date only given, default the time to 0:00:00.000 (midnight)
      # - anything left of the MSV should be defaulted to the value of that component returned by $now()
      #     (e.g.) if time only given, default the date to today
      #     (e.g.) if month and date given, default to this year (and midnight, by previous rule)
      #   -- default values for X, x, W, w, F will be derived from the values returned by $now()

      # implement the above rules
      # determine which of the above date/time combinations we have by using bit masks

      #        Y X M x W w d D F P H h m s f Z
      # dateA  1 0 1 0 0 0 0 1 ?                     0 - must not appear
      # dateB  1 0 0 0 0 0 1 0 ?                     1 - can appear - relevant
      # dateC  0 1 0 1 0 1 0 0 1                     ? - can appear - ignored
      # dateD  0 1 0 0 1 0 0 0 1
      # timeA                    0 1 0 1 1 1
      # timeB                    1 0 1 1 1 1

      # create bitmasks based on the above
      #    date mask             YXMxWwdD
      dm_a = 161 # binary 10100001
      dm_b = 130 # binary 10000010
      dm_c = 84 # binary 01010100
      dm_d = 72 # binary 01001000
      #    time mask             PHhmsf
      tm_a = 23 # binary 010111
      tm_b = 47 # binary 101111

      components = {}
      (1...info.size).each do |i|
        mpart = match_spec[:parts][i - 1]
        components[mpart[:component]] = mpart[:parse].call(info[i]) if mpart[:parse]
      end

      # nothing specified
      return nil if components.empty?

      mask = 0

      shift = lambda do |bit|
        mask <<= 1
        mask += Utils.truthy?(bit) ? 1 : 0
      end

      is_type = lambda do |type|
        # shouldn't match any 0's, must match at least one 1
        type.allbits?(mask) && type.anybits?(mask)
      end

      'YXMxWwdD'.each_char { |part| shift.call(components[part]) }

      date_a = is_type.call(dm_a)
      date_b = !date_a && is_type.call(dm_b)
      date_c = is_type.call(dm_c)
      date_d = !date_c && is_type.call(dm_d)

      mask = 0
      'PHhmsf'.each_char { |part| shift.call(components[part]) }

      time_a = is_type.call(tm_a)
      time_b = !time_a && is_type.call(tm_b)

      # should only be zero or one date type and zero or one time type

      date_comps = if date_b
                     'YD'
                   elsif date_c
                     'XxwF'
                   elsif date_d
                     'XWF'
                   else
                     'YMD'
                   end
      time_comps = time_b ? 'Phmsf' : 'Hmsf'

      comps = date_comps + time_comps

      # step through the candidate parts from most significant to least significant
      # default the most significant unspecified parts to current timestamp component
      # default the least significant unspecified parts to zero
      # if any gaps in between the specified parts, throw an error

      now = environment.timestamp # must get the fixed timestamp from jsonata

      start_specified = false
      end_specified = false
      comps.each_char do |part|
        if components[part].nil?
          if start_specified
            # past the specified block - default to zero
            components[part] = 'MDd'.include?(part) ? 1 : 0
            end_specified = true
          else
            # haven't hit the specified block yet, default to current timestamp
            components[part] = get_date_time_fragment(now, part)
          end
        else
          start_specified = true
          raise Jsonata::Error.new('D3136') if end_specified
        end
      end

      # validate and fill in components
      if !components['M'].nil? && components['M'].positive?
        components['M'] -= 1 # Date.UTC requires a zero-indexed month
      else
        components['M'] = 0 # default to January
      end
      if date_b
        # millis for given 1st Jan of that year (at 00:00 UTC)
        first_jan = DateTime.date_utc(components['Y'], 0)
        offset_millis = (components['d'] - 1) * 1000 * 60 * 60 * 24
        derived_date = DateTime.new_date(first_jan + offset_millis)
        components['M'] = derived_date.month - 1
        components['D'] = derived_date.day
      end
      if date_c
        # TODO implement this
        # parsing this format not currently supported
        raise Jsonata::Error.new('D3136')
      end
      if date_d
        # TODO implement this
        # parsing this format (ISO week date) not currently supported
        raise Jsonata::Error.new('D3136')
      end

      if time_b
        # 12hr to 24hr
        components['H'] = components['h'] == 12 ? 0 : components['h']
        components['H'] += 12 if components['P'] == 1
      end

      millis = DateTime.date_utc(components['Y'], components['M'], components['D'], components['H'], components['m'],
                                 components['s'], components['f'])
      if Utils.truthy?(components['Z']) || Utils.truthy?(components['z'])
        # adjust for timezone
        millis -= (Utils.truthy?(components['Z']) ? components['Z'] : components['z']) * 60 * 1000
      end
      millis
    end

    # Regular expression to match an ISO 8601 formatted timestamp
    ISO8601_REGEX = /\A\d{4}(-[01]\d)?(-[0-3]\d)?(T[0-2]\d:[0-5]\d:[0-5]\d)?(\.\d+)?([+-][0-2]\d:?[0-5]\d|Z)?\z/

    # Equivalent of Date.parse for the ISO 8601 subset accepted by ISO8601_REGEX
    def self.date_parse(timestamp)
      m = /\A(\d{4})(?:-(\d\d))?(?:-(\d\d))?(?:T(\d\d):(\d\d):(\d\d))?(?:\.(\d+))?(Z|([+-])(\d\d):?(\d\d))?\z/.match(timestamp)
      return Float::NAN if m.nil?

      year = m[1].to_i
      month = (m[2] || '01').to_i
      day = (m[3] || '01').to_i
      hours = m[4].to_i
      minutes = m[5].to_i
      seconds = m[6].to_i
      millis = m[7] ? m[7][0, 3].ljust(3, '0').to_i : 0
      if month < 1 || month > 12 || day < 1 || day > 31 || hours > 24 || (hours == 24 && (minutes + seconds + millis).positive?)
        return Float::NAN
      end

      # time values are relative to UTC unless an offset is specified
      result = (days_from_civil(year, month, day) * MILLIS_IN_A_DAY) + (hours * 3_600_000) + (minutes * 60_000) +
               (seconds * 1000) + millis
      if m[9]
        offset = (m[10].to_i * 60) + m[11].to_i
        result -= (m[9] == '-' ? -offset : offset) * 60_000
      end
      result
    end

    # Converts an ISO 8601 timestamp to milliseconds since the epoch
    #
    # @param timestamp - the timestamp to be converted
    # @param picture - the picture string defining the format of the timestamp (defaults to ISO 8601)
    # @returns milliseconds since the epoch
    def to_millis(timestamp, picture)
      # undefined inputs always return undefined
      return nil if timestamp.nil?

      if picture.nil?
        raise Jsonata::Error.new('D3110', :value => timestamp) unless ISO8601_REGEX.match?(timestamp)

        DateTime.date_parse(timestamp)
      else
        parse_date_time(timestamp, picture)
      end
    end

    # Converts milliseconds since the epoch to an ISO 8601 timestamp
    # @param millis - milliseconds since the epoch to be converted
    # @param picture - the picture string defining the format of the timestamp (defaults to ISO 8601)
    # @param timezone - the timezone to format the timestamp in (defaults to UTC)
    # @returns the formatted timestamp
    def from_millis(millis, picture, timezone)
      # undefined inputs always return undefined
      return nil if millis.nil?

      format_date_time(millis, picture, timezone)
    end
  end
end
