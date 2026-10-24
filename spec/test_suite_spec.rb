# frozen_string_literal: true

# (c) Copyright IBM Corp. 2016 All Rights Reserved
#   Project name: JSONata
#   This project is licensed under the MIT License, see LICENSE

# Port of jsonata-js test/run-test-suite.js
#
# Runs the language-neutral test suite from the jsonata-js git submodule (vendor/jsonata-js/test/test-suite).
#
# Environment variables:
#   GROUP - comma separated list of groups to run (e.g. GROUP=function-sum,hof-map)

require 'json'

TEST_SUITE_DIR = File.expand_path('../vendor/jsonata-js/test/test-suite', __dir__)

unless File.directory?(File.join(TEST_SUITE_DIR, 'groups'))
  raise "jsonata-js test suite not found at #{TEST_SUITE_DIR}; run `git submodule update --init`"
end

module TestSuite
  module_function

  # Simple function to read in JSON
  def read_json(dir, file)
    text = File.read(File.join(dir, file))
    begin
      JSON.parse(text)
    rescue JSON::ParserError
      # Ruby's JSON parser rejects lone UTF-16 surrogates, so escape them such that they are passed
      # through to the JSONata tokenizer as \uXXXX escape sequences
      escaped = text.gsub(/\\u(d[89ab]\h\h)(?!\\ud[c-f])|(?<!\\ud[89ab]\h\h)\\u(d[c-f]\h\h)/i) { "\\\\u#{$1 || $2}" }
      decode_lone_surrogates(JSON.parse(escaped))
    end
  rescue JSON::ParserError => e
    raise "Error reading #{file} in #{dir}: #{e.message}"
  end

  # Converts escaped lone surrogates (other than in the expression itself) into the representation
  # used by Jsonata (see Jsonata::Utils.from_char_code)
  def decode_lone_surrogates(value, key = nil)
    case value
    when Hash then value.to_h { |k, v| [k, decode_lone_surrogates(v, k)] }
    when Array then value.map { |v| decode_lone_surrogates(v) }
    when String
      return value if key == 'expr'

      value.gsub(/\\u(d[89a-f]\h\h)/i) { Jsonata::Utils.from_char_code(::Regexp.last_match(1).hex) }
    else value
    end
  end

  def datasets
    @datasets ||= begin
      dir = File.join(TEST_SUITE_DIR, 'datasets')
      Dir.children(dir).sort.to_h do |name|
        [name.delete_suffix('.json'), read_json(dir, name)]
      end
    end
  end

  def groups
    dir = File.join(TEST_SUITE_DIR, 'groups')
    Dir.children(dir).reject { |name| name.end_with?('.json') }.sort
  end

  def cases(group)
    dir = File.join(TEST_SUITE_DIR, 'groups', group)
    filenames = Dir.children(dir).select { |name| name.end_with?('.json') }.sort
    filenames.flat_map do |name|
      spec = read_json(dir, name)
      specs = spec.kind_of?(Array) ? spec : [spec]
      specs.each do |item|
        item['description'] ||= name
        # if the testcase references an external jsonata file, read it in
        item['expr'] = File.read(File.join(dir, item['expr-file'])) if item['expr-file']
      end
    end
  end

  # Based on the collection of datasets and the information provided as part of the testcase,
  # determine what input data to use in the case (may return undefined).
  def resolve_dataset(testcase)
    return Jsonata::Utils.from_ruby(testcase['data']) if testcase.key?('data')
    return nil if testcase['dataset'].nil?
    return Jsonata::Utils.from_ruby(datasets[testcase['dataset']]) if datasets.key?(testcase['dataset'])

    raise "Unable to find dataset #{testcase['dataset']} among known datasets, are you sure the datasets " \
          "directory has a file named #{testcase['dataset']}.json?"
  end

  # Protect the process from a runaway expression
  # i.e. Infinite loop (tail recursion), or excessive stack growth
  #
  # @param expr - expression to protect
  # @param timeout - max time in ms
  # @param max_depth - max stack depth
  def timebox_expression(expr, timeout, max_depth)
    depth = 0
    time = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)

    check_runaway = lambda do
      if max_depth.positive? && depth > max_depth
        # stack too deep
        raise Jsonata::Error.new(
          'U1001',
          :message => 'Stack overflow error: Check for non-terminating recursive function.  ' \
                      'Consider rewriting as tail-recursive.'
        )
      end
      if Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - time > timeout
        # expression has run for too long
        raise Jsonata::Error.new('U1001', :message => 'Expression evaluation timeout: Check for infinite loop')
      end
    end

    # register callbacks
    expr.assign(:'jsonata.__evaluate_entry', lambda do |_expr, _input, env|
      next if env.is_parallel_call

      depth += 1
      check_runaway.call
    end)
    expr.assign(:'jsonata.__evaluate_exit', lambda do |_expr, _input, env, _result|
      next if env.is_parallel_call

      depth -= 1
      check_runaway.call
    end)
  end
end

RSpec.describe 'JSONata Test Suite' do
  selected = ENV['GROUP']&.split(',')

  # Iterate over all groups of tests
  TestSuite.groups.each do |group|
    next if selected && !selected.include?(group)

    describe "Group: #{group}" do
      # Iterate over all cases
      TestSuite.cases(group).each do |testcase|
        # Create a test based on the data in this testcase
        it "#{testcase['description']}: #{testcase['expr']}" do
          expr = nil
          # Start by trying to compile the expression associated with this test case
          begin
            expr = Jsonata.expression(testcase['expr'])
            # If there is a timelimit and depth limit for this case, use the
            # `timebox_expression` function to limit evaluation
            if testcase.key?('timelimit') && testcase.key?('depth')
              TestSuite.timebox_expression(expr, testcase['timelimit'], testcase['depth'])
            end
          rescue Jsonata::Error => e
            # If we get here, an error was thrown.  So check to see if this particular
            # testcase expects an exception (as indicated by the presence of the
            # `code` field in the testcase)
            raise "Got an unexpected exception: #{e.message}" unless testcase['code']

            # See if we go the code we expected
            expect(e.code).to eq(testcase['code'])
            # If a token was specified, check for that too
            expect(e.token).to eq(testcase['token']) if testcase.key?('token')
          end
          # If we managed to compile the expression...
          next unless expr

          # Load the input data set.  First, check to see if the test case defines its own input
          # data (testcase.data).  If not, then look for a dataset number.  If it is -1, then that
          # means there is no data (so use undefined).  If there is a dataset number, look up the
          # input data in the datasets array.
          dataset = TestSuite.resolve_dataset(testcase)

          # Test cases have three possible outcomes from evaluation...
          if testcase.key?('undefinedResult')
            # First is that we have an undefined result.  So, check
            # to see if the result we get from evaluation is undefined
            expect(expr.evaluate_raw(dataset, testcase['bindings'])).to be_nil
          elsif testcase.key?('result')
            # Second is that a (defined) result was provided.  In this case,
            # we do a deep equality check against the expected result.
            result = expr.evaluate_raw(dataset, testcase['bindings'])
            expect(result).to eq(Jsonata::Utils.from_ruby(testcase['result']))
          elsif testcase.key?('error')
            # If an error was expected,
            # we do a deep equality check against the expected error structure.
            expect { expr.evaluate_raw(dataset, testcase['bindings']) }.to raise_error(Jsonata::Error) { |e|
              expect(e.to_h).to include(testcase['error'])
            }
          elsif testcase.key?('code')
            # Finally, if a `code` field was specified, we expected the
            # evaluation to fail and include the specified code in the
            # thrown exception.
            expect { expr.evaluate_raw(dataset, testcase['bindings']) }.to raise_error(Jsonata::Error) { |e|
              expect(e.code).to eq(testcase['code'])
            }
          else
            # If we get here, it means there is something wrong with
            # the test case data because there was nothing to check.
            raise 'Nothing to test in this test case'
          end
        end
      end
    end
  end
end
