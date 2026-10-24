# frozen_string_literal: true

# (c) Copyright IBM Corp. 2016, 2017 All Rights Reserved
#   Project name: JSONata
#   This project is licensed under the MIT License, see LICENSE

# Port of jsonata-js src/jsonata.js
#
# The JavaScript implementation is asynchronous (async/await); this port is synchronous.

require 'json'

module Jsonata
  # Environment frame (jsonata-js: createFrame)
  class Frame
    attr_accessor :timestamp, :async, :is_parallel_call, :global, :base,
                  # the following are only set on the base (execution) environment
                  :depth, :options, :guardrails, :regex_engine

    def initialize(enclosing_environment)
      @bindings = {}
      @enclosing_environment = enclosing_environment
      @timestamp = enclosing_environment&.timestamp
      @async = enclosing_environment ? enclosing_environment.async : false
      @is_parallel_call = enclosing_environment ? enclosing_environment.is_parallel_call : false
      @global = enclosing_environment ? enclosing_environment.global : { ancestry: [nil] }

      return unless enclosing_environment

      frame_push_callback = enclosing_environment.lookup(:'jsonata.__createFrame_push')
      frame_push_callback&.call(enclosing_environment, self)
      @base = enclosing_environment.base
    end

    def bind(name, value)
      @bindings[name] = value
    end

    def lookup(name)
      frame = self
      while frame
        bindings = frame.instance_variable_get(:@bindings)
        return bindings[name] if bindings.key?(name)

        frame = frame.instance_variable_get(:@enclosing_environment)
      end
      nil
    end

    # (jsonata-js: exec_env.createSequence)
    def create_sequence(*args)
      sequence = JArray.new
      sequence.max_length = options[:sequence] if options && options[:sequence]
      sequence.sequence = true
      sequence.push(args[0]) if args.length == 1
      sequence
    end
  end

  # The `this` object that native functions are invoked with (jsonata-js: the `focus` object)
  class Focus
    include Functions
    include DateTime

    attr_reader :environment, :input

    def initialize(environment = nil, input = nil)
      @environment = environment
      @input = input
    end

    def options
      @environment&.base&.options
    end

    def create_sequence(*args)
      base = @environment&.base
      if base
        base.create_sequence(*args)
      else
        sequence = JArray.new
        sequence.sequence = true
        sequence.push(args[0]) if args.length == 1
        sequence
      end
    end

    # parses and evaluates the supplied expression
    # @param expr - expression to evaluate
    # @returns result of evaluating the expression
    def function_eval(expr, focus)
      # undefined inputs always return undefined
      return nil if expr.nil?

      input = self.input
      unless focus.nil?
        input = focus
        # if the input is a JSON array, then wrap it in a singleton sequence so it gets treated as a single input
        if input.is_a?(Array) && !Utils.sequence?(input)
          input = create_sequence(input)
          input.outer_wrapper = true
        end
      end

      begin
        ast = Parser.parse(expr, false)
      rescue Jsonata::Error => e
        # error parsing the expression passed to $eval
        Evaluator.populate_message(e)
        raise Jsonata::Error.new('D3120', value: e.message, error: e)
      end
      begin
        result = Evaluator.evaluate(ast, input, environment)
      rescue Jsonata::Error => e
        # error evaluating the expression passed to $eval
        Evaluator.populate_message(e)
        raise Jsonata::Error.new('D3121', value: e.message, error: e)
      end

      result
    end

    # Clones an object
    # @param arg - object to clone (deep copy)
    # @returns the cloned object
    def function_clone(arg)
      # undefined inputs always return undefined
      return nil if arg.nil?

      Utils.from_ruby(JSON.parse(string(arg)))
    end
  end

  module Evaluator
    module_function

    # Evaluate expression against input data
    # @param expr - JSONata expression
    # @param input - Input data to evaluate against
    # @param environment - Environment
    # @returns Evaluated input data
    def evaluate(expr, input, environment)
      environment.base.depth += 1
      environment.base.guardrails.call
      entry_callback = environment.lookup(:'jsonata.__evaluate_entry')
      entry_callback&.call(expr, input, environment)

      result = case expr[:type]
               when 'path'
                 evaluate_path(expr, input, environment)
               when 'binary'
                 evaluate_binary(expr, input, environment)
               when 'unary'
                 evaluate_unary(expr, input, environment)
               when 'name'
                 evaluate_name(expr, input, environment)
               when 'string', 'number', 'value'
                 evaluate_literal(expr)
               when 'wildcard'
                 evaluate_wildcard(expr, input, environment)
               when 'descendant'
                 evaluate_descendants(expr, input, environment)
               when 'parent'
                 environment.lookup(expr[:slot][:label])
               when 'condition'
                 evaluate_condition(expr, input, environment)
               when 'block'
                 evaluate_block(expr, input, environment)
               when 'bind'
                 evaluate_bind_expression(expr, input, environment)
               when 'regex'
                 evaluate_regex(expr, input, environment)
               when 'function'
                 evaluate_function(expr, input, environment)
               when 'variable'
                 evaluate_variable(expr, input, environment)
               when 'lambda'
                 evaluate_lambda(expr, input, environment)
               when 'partial'
                 evaluate_partial_application(expr, input, environment)
               when 'apply'
                 evaluate_apply_expression(expr, input, environment)
               when 'transform'
                 evaluate_transform_expression(expr, input, environment)
               end

      if expr.key?(:predicate)
        expr[:predicate].each do |predicate|
          result = evaluate_filter(predicate[:expr], result, environment)
        end
      end

      if expr[:type] != 'path' && expr.key?(:group)
        result = evaluate_group_expression(expr[:group], result, environment)
      end

      exit_callback = environment.lookup(:'jsonata.__evaluate_exit')
      exit_callback&.call(expr, input, environment, result)

      if Utils.sequence?(result) && !result.tuple_stream
        result.keep_singleton = true if expr[:keep_array]
        if result.empty?
          result = nil
        elsif result.length == 1
          result = result.keep_singleton ? result : result[0]
        end
      end

      environment.base.depth -= 1

      result
    end

    # Evaluate path expression against input data
    def evaluate_path(expr, input, environment)
      # expr is an array of steps
      # if the first step is a variable reference ($...), including root reference ($$),
      #   then the path is absolute rather than relative
      input_sequence = if input.is_a?(Array) && expr[:steps][0][:type] != 'variable'
                         input
                       else
                         # if input is not an array, make it so
                         environment.base.create_sequence(input)
                       end

      result_sequence = nil
      is_tuple_stream = false
      tuple_bindings = nil

      # evaluate each step in turn
      expr[:steps].each_with_index do |step, ii|
        is_tuple_stream = true if step[:tuple]

        # if the first step is an explicit array constructor, then just evaluate that (i.e. don't iterate over a context array)
        if ii.zero? && step[:consarray]
          result_sequence = evaluate(step, input_sequence, environment)
        elsif is_tuple_stream
          tuple_bindings = evaluate_tuple_step(step, input_sequence, tuple_bindings, environment)
        else
          result_sequence = evaluate_step(step, input_sequence, environment, ii == expr[:steps].length - 1)
        end

        break if !is_tuple_stream && (result_sequence.nil? || (result_sequence.is_a?(Array) && result_sequence.empty?))

        input_sequence = result_sequence unless step.key?(:focus)
      end

      if is_tuple_stream
        if expr[:tuple]
          # tuple stream is carrying ancestry information - keep this
          result_sequence = tuple_bindings
        else
          result_sequence = environment.base.create_sequence
          tuple_bindings.each do |tuple|
            result_sequence.push(tuple['@'])
          end
        end
      end

      if expr[:keep_singleton_array]
        # if the array is explicitly constructed in the expression and marked to promote singleton sequences to array
        if result_sequence.is_a?(JArray) && result_sequence.cons && !result_sequence.sequence
          result_sequence = environment.base.create_sequence(result_sequence)
        end
        if result_sequence.is_a?(Array)
          result_sequence = JArray.new(result_sequence) unless result_sequence.is_a?(JArray)
          result_sequence.keep_singleton = true
        end
      end

      if expr.key?(:group)
        result_sequence = evaluate_group_expression(expr[:group], is_tuple_stream ? tuple_bindings : result_sequence,
                                                    environment)
      end

      result_sequence
    end

    def create_frame_from_tuple(environment, tuple)
      frame = create_frame(environment)
      Utils.keys(tuple).each do |prop|
        frame.bind(prop, tuple[prop])
      end
      frame
    end

    # Evaluate a step within a path
    # @param last_step - flag the last step in a path
    def evaluate_step(expr, input, environment, last_step)
      if expr[:type] == 'sort'
        result = evaluate_sort_expression(expr, input, environment)
        result = evaluate_stages(expr[:stages], result, environment) if expr[:stages]
        return result
      end

      result = environment.base.create_sequence

      input.each do |item|
        res = evaluate(expr, item, environment)
        expr[:stages]&.each do |stage|
          res = evaluate_filter(stage[:expr], res, environment)
        end
        result.push(res) unless res.nil?
      end

      result_sequence = environment.base.create_sequence
      if last_step && result.length == 1 && result[0].is_a?(Array) && !Utils.sequence?(result[0])
        result_sequence = result[0]
      else
        # flatten the sequence
        result.each do |res|
          if !res.is_a?(Array) || (res.is_a?(JArray) && res.cons)
            # it's not an array - just push into the result sequence
            result_sequence.push(res)
          else
            # res is a sequence - flatten it into the parent sequence
            res.each { |val| result_sequence.push(val) }
          end
        end
      end

      result_sequence
    end

    def evaluate_stages(stages, input, environment)
      result = input
      stages.each do |stage|
        case stage[:type]
        when 'filter'
          result = evaluate_filter(stage[:expr], result, environment)
        when 'index'
          result.each_with_index do |tuple, ee|
            tuple[stage[:value]] = ee
          end
        end
      end
      result
    end

    # Evaluate a step within a path
    # @param tuple_bindings - The tuple stream
    def evaluate_tuple_step(expr, input, tuple_bindings, environment)
      if expr[:type] == 'sort'
        if tuple_bindings
          result = evaluate_sort_expression(expr, tuple_bindings, environment)
        else
          sorted = evaluate_sort_expression(expr, input, environment)
          result = environment.base.create_sequence
          result.tuple_stream = true
          sorted.each_with_index do |item, ss|
            tuple = { '@' => item }
            tuple[expr[:index]] = ss
            result.push(tuple)
          end
        end
        result = evaluate_stages(expr[:stages], result, environment) if expr[:stages]
        return result
      end

      result = environment.base.create_sequence
      result.tuple_stream = true
      tuple_bindings = input.map { |item| { '@' => item } } if tuple_bindings.nil?

      tuple_bindings.each do |binding|
        step_env = create_frame_from_tuple(environment, binding)
        res = evaluate(expr, binding['@'], step_env)
        # res is the binding sequence for the output tuple stream
        next if res.nil?

        res = [res] unless res.is_a?(Array)
        res.each_with_index do |item, bb|
          tuple = {}
          tuple.merge!(binding)
          if res.is_a?(JArray) && res.tuple_stream
            tuple.merge!(item)
          else
            if expr[:focus]
              tuple[expr[:focus]] = item
              tuple['@'] = binding['@']
            else
              tuple['@'] = item
            end
            tuple[expr[:index]] = bb if expr[:index]
            tuple[expr[:ancestor][:label]] = binding['@'] if expr[:ancestor]
          end
          result.push(tuple)
        end
      end

      result = evaluate_stages(expr[:stages], result, environment) if expr[:stages]

      result
    end

    # Apply filter predicate to input data
    # @param predicate - filter expression
    # @param input - Input data to apply predicates against
    # @returns Result after applying predicates
    def evaluate_filter(predicate, input, environment)
      results = environment.base.create_sequence
      results.tuple_stream = true if input.is_a?(JArray) && input.tuple_stream
      input = environment.base.create_sequence(input) unless input.is_a?(Array)
      if predicate[:type] == 'number'
        index = predicate[:value].floor # round it down
        if index.negative?
          # count in from end of array
          index = input.length + index
        end
        item = index.negative? ? nil : input[index]
        unless item.nil?
          if item.is_a?(Array)
            results = item
          else
            results.push(item)
          end
        end
      else
        input.each_with_index do |item, index|
          context = item
          env = environment
          if input.is_a?(JArray) && input.tuple_stream
            context = item['@']
            env = create_frame_from_tuple(environment, item)
          end
          res = evaluate(predicate, context, env)
          res = [res] if Utils.numeric?(res)
          if Utils.array_of_numbers?(res)
            res.each do |ires|
              # round it down
              ii = ires.floor
              if ii.negative?
                # count in from end of array
                ii = input.length + ii
              end
              results.push(item) if ii == index
            end
          elsif FN.boolean(res) # truthy
            results.push(item)
          end
        end
      end
      results
    end

    # Evaluate binary expression against input data
    def evaluate_binary(expr, input, environment)
      lhs = evaluate(expr[:lhs], input, environment)
      op = expr[:value]

      # defer evaluation of RHS to allow short-circuiting
      evalrhs = -> { evaluate(expr[:rhs], input, environment) }
      if op == 'and' || op == 'or'
        begin
          return evaluate_boolean_expression(lhs, evalrhs, op)
        rescue Jsonata::Error => e
          e.position = expr[:position]
          e.token = op
          raise
        end
      end

      rhs = evalrhs.call
      begin
        case op
        when '+', '-', '*', '/', '%'
          evaluate_numeric_expression(lhs, rhs, op)
        when '=', '!='
          evaluate_equality_expression(lhs, rhs, op)
        when '<', '<=', '>', '>='
          evaluate_comparison_expression(lhs, rhs, op)
        when '&'
          evaluate_string_concat(lhs, rhs)
        when '..'
          evaluate_range_expression(lhs, rhs, environment)
        when 'in'
          evaluate_includes_expression(lhs, rhs)
        end
      rescue Jsonata::Error => e
        e.position = expr[:position]
        e.token = op
        raise
      end
    end

    # Evaluate unary expression against input data
    def evaluate_unary(expr, input, environment)
      result = nil

      focus = Focus.new(environment)
      case expr[:value]
      when '-'
        result = evaluate(expr[:expression], input, environment)
        if result.nil?
          result = nil
        elsif Utils.numeric?(result)
          result = -result
        else
          raise Jsonata::Error.new('D1002', position: expr[:position], token: expr[:value], value: result)
        end
      when '['
        # array constructor - evaluate each item
        result = JArray.new
        generators = expr[:expressions].each_with_index.map do |item, idx|
          environment.is_parallel_call = idx.positive?
          [item, evaluate(item, input, environment)]
        end
        generators.each do |item, value|
          next if value.nil?

          if item[:value] == '['
            result.push(value)
          else
            result = focus.append(result, value)
          end
        end
        if expr[:consarray]
          result = JArray.new(result) unless result.is_a?(JArray)
          result.cons = true
        end
      when '{'
        # object constructor - apply grouping
        result = evaluate_group_expression(expr, input, environment)
      end
      result
    end

    # Evaluate name object against input data
    def evaluate_name(expr, input, environment)
      # lookup the 'name' item in the input
      Focus.new(environment).lookup(input, expr[:value])
    end

    # Evaluate literal against input data
    def evaluate_literal(expr)
      expr[:value]
    end

    # Evaluate wildcard against input data
    def evaluate_wildcard(_expr, input, environment)
      focus = Focus.new(environment)
      results = focus.create_sequence
      input = input[0] if input.is_a?(JArray) && input.outer_wrapper && !input.empty?
      if input.is_a?(Hash) || input.is_a?(Array)
        Utils.keys(input).each do |key|
          value = input.is_a?(Array) ? input[key.to_i] : input[key]
          if value.is_a?(Array)
            value = flatten(value)
            results = focus.append(results, value)
          else
            results.push(value)
          end
        end
      end

      #        result = normalizeSequence(results);
      results
    end

    # Returns a flattened array
    # @param arg - the array to be flatten
    # @param flattened - carries the flattened array - if not defined, will initialize to []
    def flatten(arg, flattened = [])
      if arg.is_a?(Array)
        arg.each do |item|
          flatten(item, flattened)
        end
      else
        flattened.push(arg)
      end
      flattened
    end

    # Evaluate descendants against input data
    def evaluate_descendants(_expr, input, environment)
      result = nil
      result_sequence = environment.base.create_sequence
      unless input.nil?
        # traverse all descendants of this object/array
        recurse_descendants(input, result_sequence)
        result = if result_sequence.length == 1
                   result_sequence[0]
                 else
                   result_sequence
                 end
      end
      result
    end

    # Recurse through descendants
    def recurse_descendants(input, results)
      # this is the equivalent of //* in XPath
      results.push(input) unless input.is_a?(Array)
      if input.is_a?(Array)
        input.each do |member|
          recurse_descendants(member, results)
        end
      elsif input.is_a?(Hash)
        Utils.keys(input).each do |key|
          recurse_descendants(input[key], results)
        end
      end
    end

    # Evaluate numeric expression against input data
    def evaluate_numeric_expression(lhs, rhs, op)
      raise Jsonata::Error.new('T2001', value: lhs) if !lhs.nil? && !Utils.numeric?(lhs)
      raise Jsonata::Error.new('T2002', value: rhs) if !rhs.nil? && !Utils.numeric?(rhs)

      # if either side is undefined, the result is undefined
      return nil if lhs.nil? || rhs.nil?

      lhs = lhs.to_f
      rhs = rhs.to_f
      result = case op
               when '+' then lhs + rhs
               when '-' then lhs - rhs
               when '*' then lhs * rhs
               when '/' then lhs / rhs
               when '%' then rhs.zero? ? Float::NAN : lhs.remainder(rhs)
               end
      Utils.normalize_number(result)
    end

    # Evaluate equality expression against input data
    def evaluate_equality_expression(lhs, rhs, op)
      # if either side is undefined, the result is false
      return false if lhs.nil? || rhs.nil?

      case op
      when '='
        Utils.deep_equal?(lhs, rhs)
      when '!='
        !Utils.deep_equal?(lhs, rhs)
      end
    end

    # Evaluate comparison expression against input data
    def evaluate_comparison_expression(lhs, rhs, op)
      # type checks
      ltype = Utils.typeof(lhs)
      rtype = Utils.typeof(rhs)

      lcomparable = %w[undefined string number].include?(ltype)
      rcomparable = %w[undefined string number].include?(rtype)

      # if either aa or bb are not comparable (string or numeric) values, then throw an error
      unless lcomparable && rcomparable
        raise Jsonata::Error.new('T2010', value: %w[string number].include?(ltype) ? rhs : lhs)
      end

      # if either side is undefined, the result is undefined
      return nil if ltype == 'undefined' || rtype == 'undefined'

      # if aa and bb are not of the same type
      raise Jsonata::Error.new('T2009', value: lhs, value2: rhs) if ltype != rtype

      case op
      when '<' then lhs < rhs
      when '<=' then lhs <= rhs
      when '>' then lhs > rhs
      when '>=' then lhs >= rhs
      end
    end

    # Inclusion operator - in
    # @returns true if lhs is a member of rhs
    def evaluate_includes_expression(lhs, rhs)
      # if either side is undefined, the result is false
      return false if lhs.nil? || rhs.nil?

      rhs = [rhs] unless rhs.is_a?(Array)

      rhs.any? { |item| Utils.strict_equal?(item, lhs) }
    end

    # Evaluate boolean expression against input data
    # @param evalrhs - function to evaluate RHS value
    def evaluate_boolean_expression(lhs, evalrhs, op)
      l_bool = boolize(lhs)

      case op
      when 'and'
        l_bool && boolize(evalrhs.call)
      when 'or'
        l_bool || boolize(evalrhs.call)
      end
    end

    def boolize(value)
      booled_value = FN.boolean(value)
      booled_value.nil? ? false : booled_value
    end

    # Evaluate string concatenation against input data
    def evaluate_string_concat(lhs, rhs)
      lstr = ''
      rstr = ''
      lstr = FN.string(lhs) unless lhs.nil?
      rstr = FN.string(rhs) unless rhs.nil?

      lstr + rstr
    end

    # Evaluate group expression against input data
    def evaluate_group_expression(expr, input, environment)
      result = {}
      groups = {}
      reduce = input.is_a?(JArray) && input.tuple_stream ? true : false
      focus = Focus.new(environment)
      # group the input sequence by 'key' expression
      input = focus.create_sequence(input) unless input.is_a?(Array)
      # if the array is empty, add an undefined entry to enable literal JSON object to be generated
      input.push(nil) if input.empty? && !reduce

      input.each do |item|
        env = reduce ? create_frame_from_tuple(environment, item) : environment
        expr[:lhs].each_with_index do |pair, pair_index|
          key = evaluate(pair[0], reduce ? item['@'] : item, env)
          # key has to be a string
          if !key.is_a?(String) && !key.nil?
            raise Jsonata::Error.new('T1003', position: expr[:position], value: key)
          end

          next if key.nil?

          entry = { data: item, expr_index: pair_index }
          if groups.key?(key)
            # a value already exists in this slot
            if groups[key][:expr_index] != pair_index
              # this key has been generated by another expression in this group
              # when multiple key expressions evaluate to the same key, then error D1009 must be thrown
              raise Jsonata::Error.new('D1009', position: expr[:position], value: key)
            end

            # append it as an array
            groups[key][:data] = focus.append(groups[key][:data], item)
          else
            groups[key] = entry
          end
        end
      end

      # iterate over the groups to evaluate the 'value' expression
      generators = groups.keys.each_with_index.map do |key, idx|
        entry = groups[key]
        context = entry[:data]
        env = environment
        if reduce
          tuple = reduce_tuple_stream(entry[:data], environment)
          context = tuple.delete('@')
          env = create_frame_from_tuple(environment, tuple)
        end
        environment.is_parallel_call = idx.positive?
        [key, evaluate(expr[:lhs][entry[:expr_index]][1], context, env)]
      end

      generators.each do |key, value|
        result[key] = value unless value.nil?
      end

      result
    end

    def reduce_tuple_stream(tuple_stream, environment)
      return tuple_stream unless tuple_stream.is_a?(Array)

      result = {}
      focus = Focus.new(environment)
      result.merge!(tuple_stream[0])
      tuple_stream.drop(1).each do |tuple|
        Utils.keys(tuple).each do |prop|
          result[prop] = focus.append(result[prop], tuple[prop])
        end
      end
      result
    end

    # Evaluate range expression against input data
    # @returns Resultant array
    def evaluate_range_expression(lhs, rhs, environment)
      raise Jsonata::Error.new('T2003', value: lhs) if !lhs.nil? && !Utils.integer?(lhs)
      raise Jsonata::Error.new('T2004', value: rhs) if !rhs.nil? && !Utils.integer?(rhs)

      # if either side is undefined, the result is undefined
      return nil if lhs.nil? || rhs.nil?

      # if the lhs is greater than the rhs, return undefined
      return nil if lhs > rhs

      # limit the size of the array to ten million entries (1e7)
      # this is an implementation defined limit to protect against
      # memory and performance issues.  This value may increase in the future.
      size = (rhs - lhs + 1).to_i
      raise Jsonata::Error.new('D2014', value: size) if size > 1e7

      options = environment.base.options
      if options && options[:sequence] && size > options[:sequence]
        raise Jsonata::Error.new('D2015', value: size)
      end

      result = JArray.new((lhs.to_i..rhs.to_i).to_a)
      result.sequence = true
      result
    end

    # Evaluate bind expression against input data
    def evaluate_bind_expression(expr, input, environment)
      # The RHS is the expression to evaluate
      # The LHS is the name of the variable to bind to - should be a VARIABLE token (enforced by parser)
      value = evaluate(expr[:rhs], input, environment)
      environment.bind(expr[:lhs][:value], value)
      value
    end

    # Evaluate condition against input data
    def evaluate_condition(expr, input, environment)
      result = nil
      condition = evaluate(expr[:condition], input, environment)
      if FN.boolean(condition)
        result = evaluate(expr[:then], input, environment)
      elsif expr.key?(:else)
        result = evaluate(expr[:else], input, environment)
      end
      result
    end

    # Evaluate block against input data
    def evaluate_block(expr, input, environment)
      result = nil
      # create a new frame to limit the scope of variable assignments
      # TODO, only do this if the post-parse stage has flagged this as required
      frame = create_frame(environment)
      # invoke each expression in turn
      # only return the result of the last one
      expr[:expressions].each do |expression|
        result = evaluate(expression, input, frame)
      end

      result
    end

    # Prepare a regex
    # @param expr - expression containing regex
    # @returns Higher order function representing prepared regex
    def evaluate_regex(expr, _input, environment)
      engine = environment.base.regex_engine
      re = engine ? engine.call(expr[:value].source, expr[:value].flags) : expr[:value].regexp
      last_index = 0
      closure = nil
      closure = lambda do |str, from_index = nil|
        result = nil
        last_index = from_index || 0
        match = last_index > str.length ? nil : re.match(str, last_index)
        if match.nil?
          last_index = 0
        else
          last_index = match.end(0)
          result = {
            'match' => match[0],
            'start' => match.begin(0),
            'end' => match.end(0),
            'groups' => match.captures
          }
          result['next'] = lambda do
            if last_index >= str.length
              nil
            else
              nxt = closure.call(str, last_index)
              if nxt && nxt['match'] == ''
                # matches zero length string; this will never progress
                raise Jsonata::Error.new('D1004', position: expr[:position], value: expr[:value].source)
              end

              nxt
            end
          end
        end

        result
      end
      closure
    end

    # Evaluate variable against input data
    def evaluate_variable(expr, input, environment)
      # lookup the variable value in the environment
      # if the variable name is empty string, then it refers to context value
      if expr[:value] == ''
        input.is_a?(JArray) && input.outer_wrapper ? input[0] : input
      else
        environment.lookup(expr[:value])
      end
    end

    # sort / order-by operator
    # @param expr - AST for operator
    # @returns Ordered sequence
    def evaluate_sort_expression(expr, input, environment)
      # evaluate the lhs, then sort the results in order according to rhs expression
      lhs = input
      is_tuple_sort = input.is_a?(JArray) && input.tuple_stream ? true : false

      # sort the lhs array
      # use comparator function
      comparator = lambda do |a, b|
        # expr.terms is an array of order-by in priority order
        comp = 0
        expr[:terms].each do |term|
          break unless comp.zero?

          # evaluate the sort term in the context of a
          context = a
          env = environment
          if is_tuple_sort
            context = a['@']
            env = create_frame_from_tuple(environment, a)
          end
          aa = evaluate(term[:expression], context, env)
          # evaluate the sort term in the context of b
          context = b
          env = environment
          if is_tuple_sort
            context = b['@']
            env = create_frame_from_tuple(environment, b)
          end
          bb = evaluate(term[:expression], context, env)

          # type checks
          atype = Utils.typeof(aa)
          btype = Utils.typeof(bb)
          # undefined should be last in sort order
          if atype == 'undefined'
            # swap them, unless btype is also undefined
            comp = btype == 'undefined' ? 0 : 1
            next
          end
          if btype == 'undefined'
            comp = -1
            next
          end

          # if aa or bb are not string or numeric values, then throw an error
          unless %w[string number].include?(atype) && %w[string number].include?(btype)
            raise Jsonata::Error.new('T2008', position: expr[:position],
                                              value: %w[string number].include?(atype) ? bb : aa)
          end

          # if aa and bb are not of the same type
          raise Jsonata::Error.new('T2007', position: expr[:position], value: aa, value2: bb) if atype != btype

          # both the same - move on to next term
          next if aa == bb

          comp = aa < bb ? -1 : 1
          comp = -comp if term[:descending] == true
        end
        # only swap a & b if comp equals 1
        comp == 1
      end

      focus = Focus.new(environment, input)
      # the `focus` is passed in as the `this` for the invoked function
      focus.sort(lhs, comparator)
    end

    # create a transformer function
    # @param expr - AST for operator
    # @returns tranformer function
    def evaluate_transform_expression(expr, _input, environment)
      # create a function to implement the transform definition
      transformer = lambda do |obj| # signature <(oa):o>
        # undefined inputs always return undefined
        next nil if obj.nil?

        # this function returns a copy of obj with changes specified by the pattern/operation
        clone_function = environment.lookup('clone')
        unless Utils.function?(clone_function)
          # throw type error
          raise Jsonata::Error.new('T2013', position: expr[:position])
        end
        result = apply(clone_function, [obj], nil, environment)
        matches = evaluate(expr[:pattern], result, environment)
        unless matches.nil?
          matches = [matches] unless matches.is_a?(Array)
          matches.each do |match|
            # evaluate the update value for each match
            update = evaluate(expr[:update], match, environment)
            # update must be an object
            unless update.nil?
              unless update.is_a?(Hash)
                # throw type error
                raise Jsonata::Error.new('T2011', position: expr[:update][:position], value: update)
              end

              # merge the update
              if match.is_a?(Hash)
                Utils.keys(update).each do |prop|
                  match[prop] = update[prop]
                end
              end
            end

            # delete, if specified, must be an array of strings (or single string)
            next unless expr.key?(:delete)

            deletions = evaluate(expr[:delete], match, environment)
            next if deletions.nil?

            val = deletions
            deletions = [deletions] unless deletions.is_a?(Array)
            unless Utils.array_of_strings?(deletions)
              # throw type error
              raise Jsonata::Error.new('T2012', position: expr[:delete][:position], value: val)
            end
            deletions.each do |deletion|
              match.delete(deletion) if match.is_a?(Hash)
            end
          end
        end

        result
      end

      define_function(transformer, '<(oa):o>')
    end

    # Apply the function on the RHS using the sequence on the LHS as the first argument
    def evaluate_apply_expression(expr, input, environment)
      lhs = evaluate(expr[:lhs], input, environment)
      if expr[:rhs][:type] == 'function'
        # this is a function _invocation_; invoke it with lhs expression as the first argument
        evaluate_function(expr[:rhs], input, environment, { context: lhs })
      else
        func = evaluate(expr[:rhs], input, environment)

        raise Jsonata::Error.new('T2006', position: expr[:position], value: func) unless Utils.function?(func)

        if Utils.function?(lhs)
          # this is function chaining (func1 ~> func2)
          # function($f, $g) { function($x){ $g($f($x)) } }
          chain = evaluate(CHAIN_AST, nil, environment)
          apply(chain, [lhs, func], nil, environment)
        else
          apply(func, [lhs], nil, environment)
        end
      end
    end

    # Evaluate function against input data
    def evaluate_function(expr, input, environment, applyto = nil)
      # create the procedure
      # can't assume that expr.procedure is a lambda type directly
      # could be an expression that evaluates to a function (e.g. variable reference, parens expr etc.
      # evaluate it generically first, then check that it is a function.  Throw error if not.
      proc = evaluate(expr[:procedure], input, environment)

      if proc.nil? && expr[:procedure][:type] == 'path' &&
         Utils.truthy?(environment.lookup(expr[:procedure][:steps][0][:value]))
        # help the user out here if they simply forgot the leading $
        raise Jsonata::Error.new('T1005', position: expr[:position], token: expr[:procedure][:steps][0][:value])
      end

      evaluated_args = []
      evaluated_args.push(applyto[:context]) unless applyto.nil?
      # eager evaluation - evaluate the arguments
      expr[:arguments].each do |argument|
        arg = evaluate(argument, input, environment)
        if Utils.function?(arg)
          # wrap this in a closure
          closure = Closure.new(Utils.get_function_arity(arg)) do |*params|
            # invoke func
            apply(arg, params, nil, environment)
          end
          evaluated_args.push(closure)
        else
          evaluated_args.push(arg)
        end
      end
      # apply the procedure
      proc_name = expr[:procedure][:type] == 'path' ? expr[:procedure][:steps][0][:value] : expr[:procedure][:value]
      begin
        if proc.is_a?(Lambda) || proc.is_a?(NativeFunction)
          proc.token = proc_name
          proc.position = expr[:position]
        end
        apply(proc, evaluated_args, input, environment)
      rescue Jsonata::Error => e
        # add the position field to the error
        e.position = expr[:position] unless Utils.truthy?(e.position)
        # and the function identifier
        e.token = proc_name unless Utils.truthy?(e.token)
        raise
      end
    end

    # Apply procedure or function
    # @param proc - Procedure
    # @param args - Arguments
    # @returns Result of procedure
    def apply(proc, args, input, environment)
      result = apply_inner(proc, args, input, environment)
      while Utils.lambda?(result) && result.thunk == true
        # trampoline loop - this gets invoked as a result of tail-call optimization
        # the function returned a tail-call thunk
        # unpack it, evaluate its arguments, and apply the tail call
        nxt = evaluate(result.body[:procedure], result.input, result.environment)
        if nxt.is_a?(Lambda) || nxt.is_a?(NativeFunction)
          nxt.token = result.body[:procedure][:value] if result.body[:procedure][:type] == 'variable'
          nxt.position = result.body[:procedure][:position]
        end
        evaluated_args = result.body[:arguments].map do |argument|
          evaluate(argument, result.input, result.environment)
        end

        result = apply_inner(nxt, evaluated_args, input, environment)
      end
      result
    end

    # Apply procedure or function
    # @param proc - Procedure
    # @param args - Arguments
    # @returns Result of procedure
    def apply_inner(proc, args, input, environment)
      validated_args = args
      if Utils.truthy?(proc) && (proc.is_a?(Lambda) || proc.is_a?(NativeFunction))
        validated_args = validate_arguments(proc.signature, args, input)
      end

      if Utils.lambda?(proc)
        apply_procedure(proc, validated_args)
      elsif proc.is_a?(NativeFunction)
        focus = Focus.new(environment, input)
        # the `focus` is passed in as the `this` for the invoked function
        Utils.invoke(proc.implementation, validated_args, focus)
      elsif Utils.callable?(proc)
        # typically these are functions that are returned by the invocation of plugin functions
        Utils.invoke(proc, validated_args)
      else
        raise Jsonata::Error.new('T1006')
      end
    rescue Jsonata::Error => e
      if proc.is_a?(Lambda) || proc.is_a?(NativeFunction)
        e.token = proc.token if e.token.nil? && !proc.token.nil?
        e.position = proc.position if Utils.truthy?(proc.position)
      end
      raise
    end

    # Evaluate lambda against input data
    def evaluate_lambda(expr, input, environment)
      # make a function (closure)
      procedure = Lambda.new(
        input: input,
        environment: environment,
        arguments: expr[:arguments],
        signature: expr[:signature],
        body: expr[:body]
      )
      procedure.thunk = true if expr[:thunk] == true
      procedure.apply_proc = lambda do |this, args|
        apply(procedure, args, input, this ? this.environment : environment)
      end
      procedure
    end

    # Evaluate partial application
    def evaluate_partial_application(expr, input, environment)
      # partially apply a function
      # evaluate the arguments
      evaluated_args = expr[:arguments].map do |arg|
        if arg[:type] == 'operator' && arg[:value] == '?'
          arg
        else
          evaluate(arg, input, environment)
        end
      end
      # lookup the procedure
      proc = evaluate(expr[:procedure], input, environment)
      if proc.nil? && expr[:procedure][:type] == 'path' &&
         Utils.truthy?(environment.lookup(expr[:procedure][:steps][0][:value]))
        # help the user out here if they simply forgot the leading $
        raise Jsonata::Error.new('T1007', position: expr[:position], token: expr[:procedure][:steps][0][:value])
      end
      if Utils.lambda?(proc)
        partial_apply_procedure(proc, evaluated_args, environment)
      elsif proc.is_a?(NativeFunction)
        partial_apply_native_function(proc.implementation, evaluated_args, environment)
      elsif Utils.callable?(proc)
        partial_apply_native_function(proc, evaluated_args, environment)
      else
        raise Jsonata::Error.new('T1008', position: expr[:position],
                                          token: if expr[:procedure][:type] == 'path'
                                                   expr[:procedure][:steps][0][:value]
                                                 else
                                                   expr[:procedure][:value]
                                                 end)
      end
    end

    # Validate the arguments against the signature validator (if it exists)
    # @param signature - validator function
    # @param args - function arguments
    # @param context - context value
    # @returns validated arguments
    def validate_arguments(signature, args, context)
      # nothing to validate
      return args if signature.nil?

      signature.validate(args, context)
    end

    # Apply procedure
    def apply_procedure(proc, args)
      env = create_frame(proc.environment)
      proc.arguments.each_with_index do |param, index|
        env.bind(param[:value], args[index])
      end
      if proc.body.is_a?(Hash)
        evaluate(proc.body, proc.input, env)
      else
        # this is a lambda that wraps a native function - generated by partially evaluating a native
        apply_native_function(proc.body, env)
      end
    end

    # Partially apply procedure
    # @param proc - Procedure (a Lambda, or the AST of a lambda wrapping a native function)
    # @returns Result of partially applied procedure
    def partial_apply_procedure(proc, args, environment)
      proc = Lambda.new(arguments: proc[:arguments], body: proc[:body]) if proc.is_a?(Hash)
      # create a closure, bind the supplied parameters and return a function that takes the remaining (?) parameters
      env = create_frame(proc.environment || environment)
      unbound_args = []
      proc.arguments.each_with_index do |param, index|
        arg = args[index]
        if arg.is_a?(Hash) && arg[:type] == 'operator' && arg[:value] == '?'
          unbound_args.push(param)
        else
          env.bind(param[:value], arg)
        end
      end
      Lambda.new(
        input: proc.input,
        environment: env,
        arguments: unbound_args,
        body: proc.body
      )
    end

    # Partially apply native function
    # @param native - Native function
    # @returns Result of partially applying native function
    def partial_apply_native_function(native, args, environment)
      # create a lambda function that wraps and invokes the native function
      # get the list of declared arguments from the native function
      sig_args = get_native_function_arguments(native)
      sig_args = sig_args.map { |sig_arg| "$#{sig_arg.strip}" }
      body = "function(#{sig_args.join(', ')}){ _ }"

      body_ast = Parser.parse(body)
      body_ast[:body] = native

      partial_apply_procedure(body_ast, args, environment)
    end

    # Apply native function
    def apply_native_function(proc, env)
      sig_args = get_native_function_arguments(proc)
      # generate the array of arguments for invoking the function - look them up in the environment
      args = sig_args.map { |sig_arg| env.lookup(sig_arg.strip) }

      focus = Focus.new(env)
      Utils.invoke(proc, args, focus)
    end

    # Get native function arguments
    # @param func - Function
    # @returns Native function arguments
    def get_native_function_arguments(func)
      Utils.parameter_names(func)
    end

    # Creates a function definition
    # @param func - function implementation in Ruby
    # @param signature - JSONata function signature definition
    # @returns function definition
    def define_function(func, signature = nil)
      NativeFunction.new(func, signature.nil? ? nil : Signature.new(signature))
    end

    # Create frame
    # @param enclosing_environment - Enclosing environment
    # @returns Created frame
    def create_frame(enclosing_environment)
      Frame.new(enclosing_environment)
    end

    # lookup a message template from the catalog and substitute the inserts.
    # Populates `err.message` with the substituted message. Leaves `err.message`
    # untouched if code lookup fails.
    # @param err - error to populate
    def populate_message(err)
      template = ERROR_CODES[err.code]
      return if template.nil?

      field = lambda do |name|
        name = 'function_name' if name == 'functionName'
        err.respond_to?(name) ? err.public_send(name) : nil
      end
      # if there are any handlebars, replace them with the field references
      # triple braces - replace with value
      # double braces - replace with json stringified value
      message = template.gsub(/\{\{\{([^}]+)}}}/) do
        val = field.call(Regexp.last_match(1))
        val.nil? ? 'undefined' : val.to_s
      end
      message = message.gsub(/\{\{([^}]+)}}/) do
        Utils.json_stringify(field.call(Regexp.last_match(1))) || 'undefined'
      end
      err.message = message
      # Otherwise retain the original `err.message`
    end

    # Error codes
    #
    # Sxxxx    - Static errors (compile time)
    # Txxxx    - Type errors
    # Dxxxx    - Dynamic errors (evaluate time)
    #  01xx    - tokenizer
    #  02xx    - parser
    #  03xx    - regex parser
    #  04xx    - function signature parser/evaluator
    #  10xx    - evaluator
    #  20xx    - operators
    #  3xxx    - functions (blocks of 10 for each function)
    ERROR_CODES = {
      'S0101' => 'String literal must be terminated by a matching quote',
      'S0102' => 'Number out of range: {{token}}',
      'S0103' => 'Unsupported escape sequence: \\{{token}}',
      'S0104' => 'The escape sequence \\u must be followed by 4 hex digits',
      'S0105' => 'Quoted property name must be terminated with a backquote (`)',
      'S0106' => 'Comment has no closing tag',
      'S0201' => 'Syntax error: {{token}}',
      'S0202' => 'Expected {{value}}, got {{token}}',
      'S0203' => 'Expected {{value}} before end of expression',
      'S0204' => 'Unknown operator: {{token}}',
      'S0205' => 'Unexpected token: {{token}}',
      'S0206' => 'Unknown expression type: {{token}}',
      'S0207' => 'Unexpected end of expression',
      'S0208' => 'Parameter {{value}} of function definition must be a variable name (start with $)',
      'S0209' => 'A predicate cannot follow a grouping expression in a step',
      'S0210' => 'Each step can only have one grouping expression',
      'S0211' => 'The symbol {{token}} cannot be used as a unary operator',
      'S0212' => 'The left side of := must be a variable name (start with $)',
      'S0213' => 'The literal value {{value}} cannot be used as a step within a path expression',
      'S0214' => 'The right side of {{token}} must be a variable name (start with $)',
      'S0215' => 'A context variable binding must precede any predicates on a step',
      'S0216' => "A context variable binding must precede the 'order-by' clause on a step",
      'S0217' => "The object representing the 'parent' cannot be derived from this expression",
      'S0301' => 'Empty regular expressions are not allowed',
      'S0302' => 'No terminating / in regular expression',
      'S0402' => 'Choice groups containing parameterized types are not supported',
      'S0401' => 'Type parameters can only be applied to functions and arrays',
      'S0500' => 'Attempted to evaluate an expression containing syntax error(s)',
      'T0410' => 'Argument {{index}} of function {{token}} does not match function signature',
      'T0411' => 'Context value is not a compatible type with argument {{index}} of function {{token}}',
      'T0412' => 'Argument {{index}} of function {{token}} must be an array of {{type}}',
      'D1001' => 'Number out of range: {{value}}',
      'D1002' => 'Cannot negate a non-numeric value: {{value}}',
      'T1003' => 'Key in object structure must evaluate to a string; got: {{value}}',
      'D1004' => 'Regular expression matches zero length string',
      'T1005' => 'Attempted to invoke a non-function. Did you mean ${{{token}}}?',
      'T1006' => 'Attempted to invoke a non-function',
      'T1007' => 'Attempted to partially apply a non-function. Did you mean ${{{token}}}?',
      'T1008' => 'Attempted to partially apply a non-function',
      'D1009' => 'Multiple key definitions evaluate to same key: {{value}}',
      'T1010' => 'The matcher function argument passed to function {{token}} does not return the correct object structure',
      'D1011' => 'Stack overflow. Check for non-terminating recursive function.  Consider rewriting as tail-recursive',
      'D1012' => 'Evaluation timeout after {{value}} milliseconds. Check for infinite loop',
      'D1013' => 'Object property names starting with _jsonata_ are reserved for internal use: {{value}}',
      'T2001' => 'The left side of the {{token}} operator must evaluate to a number',
      'T2002' => 'The right side of the {{token}} operator must evaluate to a number',
      'T2003' => 'The left side of the range operator (..) must evaluate to an integer',
      'T2004' => 'The right side of the range operator (..) must evaluate to an integer',
      'D2005' => 'The left side of := must be a variable name (start with $)', # defunct - replaced by S0212 parser error
      'T2006' => 'The right side of the function application operator ~> must be a function',
      'T2007' => 'Type mismatch when comparing values {{value}} and {{value2}} in order-by clause',
      'T2008' => 'The expressions within an order-by clause must evaluate to numeric or string values',
      'T2009' => 'The values {{value}} and {{value2}} either side of operator {{token}} must be of the same data type',
      'T2010' => 'The expressions either side of operator {{token}} must evaluate to numeric or string values',
      'T2011' => 'The insert/update clause of the transform expression must evaluate to an object: {{value}}',
      'T2012' => 'The delete clause of the transform expression must evaluate to a string or array of strings: {{value}}',
      'T2013' => 'The transform expression clones the input object using the $clone() function.  This has been overridden in the current scope by a non-function.',
      'D2014' => 'The size of the sequence allocated by the range operator (..) must not exceed 1e7.  Attempted to allocate {{value}}.',
      'D2015' => 'The maximum sequence length of {{value}} was exceeded.',
      'D2016' => 'The size of the string requested by the $pad function must not exceed 1e7.  Attempted to allocate {{value}}.',
      'D3001' => 'Attempting to invoke string function on Infinity or NaN',
      'D3010' => 'Second argument of replace function cannot be an empty string',
      'D3011' => 'Fourth argument of replace function must evaluate to a positive number',
      'D3012' => 'Attempted to replace a matched string with a non-string value',
      'D3020' => 'Third argument of split function must evaluate to a positive number',
      'D3030' => 'Unable to cast value to a number: {{value}}',
      'D3040' => 'Third argument of match function must evaluate to a positive number',
      'D3050' => 'The second argument of reduce function must be a function with at least two arguments',
      'D3060' => 'The sqrt function cannot be applied to a negative number: {{value}}',
      'D3061' => 'The power function has resulted in a value that cannot be represented as a JSON number: base={{value}}, exponent={{exp}}',
      'D3070' => 'The single argument form of the sort function can only be applied to an array of strings or an array of numbers.  Use the second argument to specify a comparison function',
      'D3080' => 'The picture string must only contain a maximum of two sub-pictures',
      'D3081' => "The sub-picture must not contain more than one instance of the 'decimal-separator' character",
      'D3082' => "The sub-picture must not contain more than one instance of the 'percent' character",
      'D3083' => "The sub-picture must not contain more than one instance of the 'per-mille' character",
      'D3084' => "The sub-picture must not contain both a 'percent' and a 'per-mille' character",
      'D3085' => "The mantissa part of a sub-picture must contain at least one character that is either an 'optional digit character' or a member of the 'decimal digit family'",
      'D3086' => 'The sub-picture must not contain a passive character that is preceded by an active character and that is followed by another active character',
      'D3087' => "The sub-picture must not contain a 'grouping-separator' character that appears adjacent to a 'decimal-separator' character",
      'D3088' => "The sub-picture must not contain a 'grouping-separator' at the end of the integer part",
      'D3089' => "The sub-picture must not contain two adjacent instances of the 'grouping-separator' character",
      'D3090' => "The integer part of the sub-picture must not contain a member of the 'decimal digit family' that is followed by an instance of the 'optional digit character'",
      'D3091' => "The fractional part of the sub-picture must not contain an instance of the 'optional digit character' that is followed by a member of the 'decimal digit family'",
      'D3092' => "A sub-picture that contains a 'percent' or 'per-mille' character must not contain a character treated as an 'exponent-separator'",
      'D3093' => "The exponent part of the sub-picture must comprise only of one or more characters that are members of the 'decimal digit family'",
      'D3100' => 'The radix of the formatBase function must be between 2 and 36.  It was given {{value}}',
      'D3110' => 'The argument of the toMillis function must be an ISO 8601 formatted timestamp. Given {{value}}',
      'D3120' => 'Syntax error in expression passed to function eval: {{value}}',
      'D3121' => 'Dynamic error evaluating the expression passed to function eval: {{value}}',
      'D3130' => 'Formatting or parsing an integer as a sequence starting with {{value}} is not supported by this implementation',
      'D3131' => 'In a decimal digit pattern, all digits must be from the same decimal group',
      'D3132' => 'Unknown component specifier {{value}} in date/time picture string',
      'D3133' => "The 'name' modifier can only be applied to months and days in the date/time picture string, not {{value}}",
      'D3134' => 'The timezone integer format specifier cannot have more than four digits',
      'D3135' => "No matching closing bracket ']' in date/time picture string",
      'D3136' => 'The date/time picture string is missing specifiers required to parse the timestamp',
      'D3137' => '{{{message}}}',
      'D3138' => 'The $single() function expected exactly 1 matching result.  Instead it matched more.',
      'D3139' => 'The $single() function expected exactly 1 matching result.  Instead it matched 0.',
      'D3140' => 'Malformed URL passed to ${{{functionName}}}(): {{value}}',
      'D3141' => '{{{message}}}'
    }.freeze

    # A focus object for invoking functions that don't require one
    FN = Focus.new

    CHAIN_AST = Parser.parse('function($f, $g) { function($x){ $g($f($x)) } }')

    STATIC_FRAME = Frame.new(nil)

    # Function registration
    {
      'sum' => [:sum, '<a<n>:n>'],
      'count' => [:count, '<a:n>'],
      'max' => [:max, '<a<n>:n>'],
      'min' => [:min, '<a<n>:n>'],
      'average' => [:average, '<a<n>:n>'],
      'string' => [:string, '<x-b?:s>'],
      'substring' => [:substring, '<s-nn?:s>'],
      'substringBefore' => [:substring_before, '<s-s:s>'],
      'substringAfter' => [:substring_after, '<s-s:s>'],
      'lowercase' => [:lowercase, '<s-:s>'],
      'uppercase' => [:uppercase, '<s-:s>'],
      'length' => [:length, '<s-:n>'],
      'trim' => [:trim, '<s-:s>'],
      'pad' => [:pad, '<s-ns?:s>'],
      'match' => [:match, '<s-f<s:o>n?:a<o>>'],
      'contains' => [:contains, '<s-(sf):b>'], # TODO <s-(sf<s:o>):b>
      'replace' => [:replace, '<s-(sf)(sf)n?:s>'], # TODO <s-(sf<s:o>)(sf<o:s>)n?:s>
      'split' => [:split, '<s-(sf)n?:a<s>>'], # TODO <s-(sf<s:o>)n?:a<s>>
      'join' => [:join, '<a<s>s?:s>'],
      'formatNumber' => [:format_number, '<n-so?:s>'],
      'formatBase' => [:format_base, '<n-n?:s>'],
      'formatInteger' => [:format_integer, '<n-s:s>'],
      'parseInteger' => [:parse_integer, '<s-s:n>'],
      'number' => [:number, '<(nsb)-:n>'],
      'floor' => [:floor, '<n-:n>'],
      'ceil' => [:ceil, '<n-:n>'],
      'round' => [:round, '<n-n?:n>'],
      'abs' => [:abs, '<n-:n>'],
      'sqrt' => [:sqrt, '<n-:n>'],
      'power' => [:power, '<n-n:n>'],
      'random' => [:random, '<:n>'],
      'boolean' => [:boolean, '<x-:b>'],
      'not' => [:not, '<x-:b>'],
      'map' => [:map, '<af>'],
      'zip' => [:zip, '<a+>'],
      'filter' => [:filter, '<af>'],
      'single' => [:single, '<af?>'],
      'reduce' => [:fold_left, '<afj?:j>'], # TODO <f<jj:j>a<j>j?:j>
      'sift' => [:sift, '<o-f?:o>'],
      'keys' => [:keys, '<x-:a<s>>'],
      'lookup' => [:lookup, '<x-s:x>'],
      'append' => [:append, '<xx:a>'],
      'exists' => [:exists, '<x:b>'],
      'spread' => [:spread, '<x-:a<o>>'],
      'merge' => [:merge, '<a<o>:o>'],
      'reverse' => [:reverse, '<a:a>'],
      'each' => [:each, '<o-f:a>'],
      'error' => [:error, '<s?:x>'],
      'assert' => [:assert, '<bs?:x>'],
      'type' => [:type, '<x:s>'],
      'sort' => [:sort, '<af?:a>'],
      'shuffle' => [:shuffle, '<a:a>'],
      'distinct' => [:distinct, '<x:x>'],
      'base64encode' => [:base64encode, '<s-:s>'],
      'base64decode' => [:base64decode, '<s-:s>'],
      'encodeUrlComponent' => [:encode_url_component, '<s-:s>'],
      'encodeUrl' => [:encode_url, '<s-:s>'],
      'decodeUrlComponent' => [:decode_url_component, '<s-:s>'],
      'decodeUrl' => [:decode_url, '<s-:s>'],
      'eval' => [:function_eval, '<sx?:x>'],
      'toMillis' => [:to_millis, '<s-s?:n>'],
      'fromMillis' => [:from_millis, '<n-s?s?:s>'],
      'clone' => [:function_clone, '<(oa)-:o>']
    }.each do |name, (method, signature)|
      STATIC_FRAME.bind(name, define_function(Focus.instance_method(method), signature))
    end
  end

  # A compiled JSONata expression (jsonata-js: the object returned by `jsonata(expr, options)`)
  class Expression
    # @param expr - JSONata expression
    # @param options
    # @option options [Boolean] :recover attempt to recover on parse error
    # @option options [Proc] :regex_engine callable(source, flags) returning an object that responds to `match(str, pos)`
    # @option options [Integer] :timeout evaluation timeout (milliseconds)
    # @option options [Integer] :stack max stack depth
    # @option options [Integer] :sequence max sequence length
    def initialize(expr, options = nil)
      @options = options
      begin
        @ast = Parser.parse(expr, options && options[:recover])
        @errors = @ast.delete(:errors)
      rescue Jsonata::Error => e
        # insert error message into structure
        Evaluator.populate_message(e) # possible side-effects on `err`
        raise
      end
      @environment = Evaluator.create_frame(Evaluator::STATIC_FRAME)

      @timestamp = current_time # will be overridden on each call to evalute()
      @environment.bind('now', Evaluator.define_function(lambda do |picture, timezone|
        Evaluator::FN.from_millis(millis(@timestamp), picture, timezone)
      end, '<s?s?:s>'))
      @environment.bind('millis', Evaluator.define_function(lambda do
        millis(@timestamp)
      end, '<:n>'))
    end

    # Evaluates the expression against the input, returning plain Ruby values
    # (JSON null and undefined are both returned as nil)
    # @param input - Input data to evaluate against
    # @param bindings - Hash of variable bindings
    def evaluate(input = nil, bindings = nil, &callback)
      Utils.to_ruby(evaluate_raw(input.nil? ? nil : Utils.from_ruby(input), bindings, &callback))
    end

    # Evaluates the expression, returning the internal representation of the result, in which JSON null is
    # represented by Jsonata::NULL and undefined by nil.
    # Nested nils in the input are treated as JSON null, a top-level nil input is treated as undefined.
    def evaluate_raw(input = nil, bindings = nil, &callback)
      # throw if the expression compiled with syntax errors
      unless @errors.nil?
        err = Jsonata::Error.new('S0500', position: 0)
        Evaluator.populate_message(err) # possible side-effects on `err`
        raise err
      end

      exec_env = Evaluator.create_frame(@environment)

      # add any variable bindings may have been passed in
      bindings&.each do |name, value|
        exec_env.bind(name.is_a?(Symbol) ? name.to_s : name, value.nil? ? nil : Utils.from_ruby(value))
      end

      # put the input document into the environment as the root object
      exec_env.bind('$', input)

      # capture the timestamp and put it in the execution environment
      # the $now() and $millis() functions will return this value - whenever it is called
      @timestamp = current_time
      exec_env.timestamp = @timestamp
      exec_env.options = @options

      exec_env.base = exec_env

      # if the input is a JSON array, then wrap it in a singleton sequence so it gets treated as a single input
      if input.is_a?(Array) && !Utils.sequence?(input)
        input = exec_env.create_sequence(input)
        input.outer_wrapper = true
      end

      exec_env.guardrails = if @options && (@options[:timeout] || @options[:stack])
                              time = current_millis
                              options = @options
                              lambda do
                                if options[:stack].to_i.positive? && exec_env.depth > options[:stack]
                                  # stack too deep
                                  raise Jsonata::Error.new('D1011', value: options[:stack])
                                end
                                if options[:timeout].to_i.positive? && current_millis - time > options[:timeout]
                                  # expression has run for too long
                                  raise Jsonata::Error.new('D1012', value: options[:timeout])
                                end
                              end
                            else
                              -> {}
                            end
      exec_env.depth = 0

      exec_env.regex_engine = @options && @options[:regex_engine]

      begin
        it = Evaluator.evaluate(@ast, input, exec_env)
        callback&.call(nil, it)
        it
      rescue Jsonata::Error => e
        # insert error message into structure
        Evaluator.populate_message(e) # possible side-effects on `err`
        raise
      rescue SystemStackError
        # (Ruby specific) report exhaustion of the Ruby stack as a JSONata stack overflow error
        err = Jsonata::Error.new('D1011')
        Evaluator.populate_message(err)
        raise err
      end
    end

    def assign(name, value)
      @environment.bind(name.is_a?(Symbol) && !name.to_s.start_with?('jsonata.') ? name.to_s : name,
                        value.nil? ? nil : Utils.from_ruby(value))
    end

    # Registers a Ruby function, which may be given as a callable or a block
    # @example
    #   expr.register_function('add', ->(a, b) { a + b }, '<nn:n>')
    #   expr.register_function('greet', '<s:s>') { |name| "Hello, #{name}" }
    def register_function(name, implementation = nil, signature = nil, &block)
      implementation, signature = block, implementation if block && (implementation.nil? || implementation.is_a?(String))
      func = Evaluator.define_function(implementation, signature)
      @environment.bind(name.to_s, func)
    end

    def ast
      @ast
    end

    def errors
      @errors
    end

    private

    def current_time
      Time.at(Rational(current_millis, 1000), in: 'UTC')
    end

    def current_millis
      Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond)
    end

    def millis(time)
      (time.to_r * 1000).floor
    end
  end
end
