# frozen_string_literal: true

module Jsonata
  # Ruby equivalent of the error objects thrown by jsonata-js, e.g.
  #   throw { code: "D1001", value: n, stack: ... }
  #
  # The message is populated from the error code catalog (see Evaluator::ERROR_CODES)
  class Error < StandardError
    FIELDS = %i[code position token value value2 index type exp function_name error remaining offset].freeze

    attr_accessor(*FIELDS)
    attr_writer :message

    def initialize(code = nil, message: nil, **fields)
      @code = code
      @message = message
      fields.each do |key, val|
        raise ArgumentError, "unknown field #{key}" unless FIELDS.include?(key)

        instance_variable_set("@#{key}", val)
      end
      super(message || code)
    end

    def message
      @message || code.to_s
    end

    def to_s
      message
    end

    # Returns the error fields keyed using the jsonata-js property names
    def to_h
      result = { 'code' => code }
      FIELDS.each do |field|
        next if field == :code

        val = public_send(field)
        next if val.nil?

        key = field == :function_name ? 'functionName' : field.to_s
        result[key] = val
      end
      result['message'] = message
      result
    end
  end

  # A lambda function defined in a JSONata expression
  # (jsonata-js: object with _jsonata_lambda: true)
  class Lambda
    attr_accessor :input, :environment, :arguments, :signature, :body, :thunk, :token, :position, :apply_proc

    def initialize(input: nil, environment: nil, arguments: [], signature: nil, body: nil, thunk: false)
      @input = input
      @environment = environment
      @arguments = arguments
      @signature = signature
      @body = body
      @thunk = thunk
    end

    # (jsonata-js: procedure.apply(self, args))
    def apply(this, args)
      raise Jsonata::Error.new('T1006') unless apply_proc

      apply_proc.call(this, args)
    end

    def inspect
      '#<Jsonata::Lambda>'
    end
  end

  # A native (Ruby) function definition with an optional signature
  # (jsonata-js: object with _jsonata_function: true)
  class NativeFunction
    attr_accessor :implementation, :signature, :token, :position

    def initialize(implementation, signature = nil)
      @implementation = implementation
      @signature = signature
    end

    def inspect
      '#<Jsonata::NativeFunction>'
    end
  end

  # A Ruby callable with an explicit arity
  # (jsonata-js: a plain JS function with an `arity` property)
  class Closure
    attr_reader :arity

    def initialize(arity, &block)
      @arity = arity
      @block = block
    end

    def call(*args)
      @block.call(*args)
    end

    def parameters
      [[:rest, :args]]
    end

    def to_proc
      @block
    end
  end
end
