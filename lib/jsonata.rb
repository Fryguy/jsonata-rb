# frozen_string_literal: true

require_relative "jsonata/version"

class Jsonata
  class Error < StandardError; end

  def initialize(expr)
    @expr = expr
  end

  def evaluate(dataset, bindings)
  end
end
