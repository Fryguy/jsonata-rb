# frozen_string_literal: true

# Specs for the Ruby-specific API. The behavior of the JSONata language itself is
# tested by the jsonata-js test suite (see test_suite_spec.rb).

RSpec.describe Jsonata do
  it 'has a version number' do
    expect(Jsonata::VERSION).not_to be_nil
  end

  describe '.evaluate' do
    it 'evaluates an expression against data' do
      expect(described_class.evaluate('$sum(example.value)', { example: [{ value: 4 }, { value: 7 }, { value: 13 }] }))
        .to eq(24)
    end

    it 'accepts variable bindings' do
      expect(described_class.evaluate('value > $threshold', { value: 150 }, { threshold: 100 })).to be(true)
    end
  end

  describe 'input conversion' do
    it 'accepts Symbol keys' do
      expect(described_class.evaluate('a.b', { a: { b: 1 } })).to eq(1)
    end

    it 'treats nested nil as JSON null' do
      expect(described_class.evaluate('$type(a)', { a: nil })).to eq('null')
    end

    it 'treats a top-level nil input as undefined' do
      expect(described_class.evaluate('$type($)', nil)).to be_nil
    end
  end

  describe 'output conversion' do
    it 'returns JSON null as nil' do
      expect(described_class.evaluate('null')).to be_nil
    end

    it 'returns plain Arrays' do
      expect(described_class.evaluate('[1..3]').class).to eq(Array)
    end

    it 'returns integral numbers as Integers' do
      expect(described_class.evaluate('3 * 2.0')).to eql(6)
    end
  end

  describe Jsonata::Expression do
    describe '#evaluate_raw' do
      it 'distinguishes JSON null from undefined' do
        expect(described_class.new('null').evaluate_raw).to be(Jsonata::NULL)
        expect(described_class.new('nothing').evaluate_raw({})).to be_nil
      end
    end

    describe '#assign' do
      it 'binds a value' do
        expr = described_class.new('$x + 1')
        expr.assign('x', 41)
        expect(expr.evaluate).to eq(42)
      end

      it 'binds a Ruby function' do
        expr = described_class.new('$double(value)')
        expr.assign('double', ->(x) { x * 2 })
        expect(expr.evaluate({ value: 21 })).to eq(42)
      end
    end

    describe '#register_function' do
      it 'registers a function with a signature' do
        expr = described_class.new('$add(1, 2)')
        expr.register_function('add', ->(a, b) { a + b }, '<nn:n>')
        expect(expr.evaluate).to eq(3)
      end

      it 'validates arguments against the signature' do
        expr = described_class.new('$add(1, "2")')
        expr.register_function('add', ->(a, b) { a + b }, '<nn:n>')
        expect { expr.evaluate }.to raise_error(Jsonata::Error) { |e| expect(e.code).to eq('T0410') }
      end

      it 'accepts a block' do
        expr = described_class.new('$greet("World")')
        expr.register_function('greet', '<s:s>') { |name| "Hello, #{name}" }
        expect(expr.evaluate).to eq('Hello, World')
      end
    end

    describe '#ast' do
      it 'returns the parsed expression' do
        expect(described_class.new('a.b').ast).to include(type: 'path')
      end
    end
  end

  describe Jsonata::Error do
    it 'is raised for syntax errors' do
      expect { Jsonata.evaluate('1 +') }.to raise_error(Jsonata::Error) { |e|
        expect(e.code).to eq('S0207')
        expect(e.position).to eq(3)
        expect(e.message).to eq('Unexpected end of expression')
      }
    end

    it 'is raised for evaluation errors' do
      expect { Jsonata.evaluate('$error("oops")') }.to raise_error(Jsonata::Error, 'oops')
    end
  end
end
