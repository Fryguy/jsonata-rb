# frozen_string_literal: true

require_relative 'jsonata/version'
require_relative 'jsonata/error'
require_relative 'jsonata/utils'
require_relative 'jsonata/signature'
require_relative 'jsonata/parser'
require_relative 'jsonata/functions'
require_relative 'jsonata/datetime'
require_relative 'jsonata/evaluator'

# JSONata - JSON query and transformation language
#
# This is a Ruby port of jsonata-js (https://github.com/jsonata-js/jsonata).
#
# @example Basic usage
#   require 'jsonata'
#
#   data = { example: [{ value: 4 }, { value: 7 }, { value: 13 }] }
#   expression = Jsonata.expression('$sum(example.value)')
#   result = expression.evaluate(data)  # => 24
#
# @see http://jsonata.org/ JSONata official website
# @see http://docs.jsonata.org/ JSONata documentation
module Jsonata
  class << self
    # Compile a JSONata expression (jsonata-js: `jsonata(expr, options)`)
    #
    # @param expr [String] the JSONata expression
    # @param options [Hash] see Jsonata::Expression#initialize
    # @return [Expression] a compiled JSONata expression
    # @raise [Jsonata::Error] if the expression is invalid
    def expression(expr, options = nil)
      Expression.new(expr, options)
    end

    # Evaluate a JSONata expression against data (convenience method)
    #
    # @param expr [String] the JSONata expression
    # @param data [Hash, Array, Object] the data to query
    # @param bindings [Hash] variable bindings
    # @return [Object] the result of the evaluation
    def evaluate(expr, data = nil, bindings = nil)
      expression(expr).evaluate(data, bindings)
    end
  end
end
