# JSONata-RB

A Ruby port of [jsonata-js](https://github.com/jsonata-js/jsonata), the reference implementation of
[JSONata](http://jsonata.org/) - a lightweight query and transformation language for JSON data.

This is a faithful, file-by-file port of the JavaScript implementation, and it is tested against the
jsonata-js test suite itself (included as a git submodule), so it supports the full JSONata language and
function library.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'jsonata'
```

And then execute:

```bash
bundle install
```

## Usage

```ruby
require 'jsonata'

data = {
  example: [
    { value: 4 },
    { value: 7 },
    { value: 13 }
  ]
}

# Compile an expression, then evaluate it
expression = Jsonata.expression('$sum(example.value)')
expression.evaluate(data)  # => 24

# Or use the convenience method
Jsonata.evaluate('$sum(example.value)', data)  # => 24
```

See the [JSONata documentation](http://docs.jsonata.org/) for the language and function library.

### Variable bindings

```ruby
Jsonata.evaluate('value > $threshold', { value: 150 }, { threshold: 100 })  # => true

expr = Jsonata.expression('value > $threshold')
expr.assign('threshold', 100)
expr.evaluate({ value: 150 })  # => true
```

### Custom functions

Any Ruby callable can be bound as a function, optionally with a
[signature](http://docs.jsonata.org/embedding-extending#function-signature-syntax) to validate its arguments:

```ruby
expr = Jsonata.expression('$double(value)')
expr.assign('double', ->(x) { x * 2 })
expr.evaluate({ value: 21 })  # => 42

expr = Jsonata.expression('$add(1, 2)')
expr.register_function('add', ->(a, b) { a + b }, '<nn:n>')
expr.evaluate  # => 3

expr = Jsonata.expression('$greet("World")')
expr.register_function('greet', '<s:s>') { |name| "Hello, #{name}" }
expr.evaluate  # => "Hello, World"
```

### Errors

Syntax and evaluation errors raise `Jsonata::Error`, which carries the same fields as the error objects
thrown by jsonata-js (`code`, `position`, `token`, `value`, ...):

```ruby
begin
  Jsonata.evaluate('1 +')
rescue Jsonata::Error => e
  e.code      # => "S0207"
  e.position  # => 3
  e.message   # => "Unexpected end of expression"
end
```

### Options

`Jsonata.expression(expr, options)` accepts the same options as jsonata-js:

| Option          | Description                                                                         |
|-----------------|-------------------------------------------------------------------------------------|
| `:recover`      | Attempt to recover on parse errors (see `Expression#errors`)                        |
| `:timeout`      | Evaluation timeout in milliseconds (error `D1012`)                                  |
| `:stack`        | Maximum evaluation depth (error `D1011`)                                            |
| `:sequence`     | Maximum sequence length (error `D2015`)                                             |
| `:regex_engine` | A callable `(source, flags)` returning an object that responds to `match(str, pos)` |

### Mapping between JSON and Ruby values

* JSON objects are Hashes. Symbol keys in the input are converted to Strings; results always have String keys.
* JSON `null` and JavaScript `undefined` are both returned as `nil`. In the input, a `nil` nested inside a Hash
  or Array is JSON `null`, while a top-level `nil` input means there is no input (`undefined`).
  `Expression#evaluate_raw` returns the internal representation, in which `null` is `Jsonata::NULL` and
  `undefined` is `nil`.
* Numbers are Integers when they are integral (and within the range of a JavaScript safe integer), and Floats
  otherwise. Arithmetic follows JavaScript (IEEE 754 double) semantics.
* Functions (lambdas defined in an expression, or built-in functions) are returned as `Jsonata::Lambda` and
  `Jsonata::NativeFunction` objects.

### Differences from jsonata-js

* Evaluation is synchronous (jsonata-js `evaluate` returns a Promise).
* Regular expressions use Ruby's regex engine. JavaScript regex syntax is translated where the two differ
  (e.g. `^`/`$` anchors), but some exotic constructs may behave differently.
* Strings are indexed by Unicode code point, so `$match` indexes differ from jsonata-js (which uses UTF-16 code
  units) for strings containing characters outside the Basic Multilingual Plane.

## Development

The jsonata-js repository is included as a git submodule at `vendor/jsonata-js`, so clone with:

```bash
git clone --recurse-submodules <repo-url>
# or, in an existing clone
git submodule update --init
```

Then:

```bash
bundle install
bundle exec rspec                         # run all tests
GROUP=hof-map,regex bundle exec rspec     # run specific test-suite groups
bundle exec rake console                  # interactive console
bundle exec rubocop                       # lint
```

### Structure of the port

Each Ruby file is a port of the corresponding jsonata-js source file, keeping the same structure, function
names (in snake_case), and comments, so that upstream changes can be applied to the Ruby code directly.

| jsonata-js            | jsonata-rb                                                      |
|-----------------------|-----------------------------------------------------------------|
| `src/jsonata.js`      | `lib/jsonata/evaluator.rb`                                      |
| `src/parser.js`       | `lib/jsonata/parser.rb`                                         |
| `src/functions.js`    | `lib/jsonata/functions.rb`                                      |
| `src/datetime.js`     | `lib/jsonata/datetime.rb`                                       |
| `src/signature.js`    | `lib/jsonata/signature.rb`                                      |
| `src/utils.js`        | `lib/jsonata/utils.rb` (plus helpers emulating JavaScript)      |
| `test/run-test-suite.js` | `spec/test_suite_spec.rb`                                    |

### Tracking upstream

The tests come from the jsonata-js test suite (`vendor/jsonata-js/test/test-suite`). To pick up upstream
changes:

```bash
bundle exec rake upstream:update  # move the submodule to the latest jsonata-js master, and list the new commits
bundle exec rake upstream:diff    # show the src/ and test/ changes to port
bundle exec rspec                 # port the src/ changes until the tests pass
git add vendor/jsonata-js lib     # commit the submodule bump together with the ported changes
```

## Versioning

For consistency, the gem's version follows the jsonata-js version it is ported from, so `jsonata` 2.2.2
implements the same language and passes the same test suite as jsonata-js 2.2.2. Releases that contain only
Ruby-specific changes, between upstream releases, add a fourth segment (e.g. 2.2.2.1).

## License

The gem is available as open source under the terms of the [MIT License](LICENSE).

## Acknowledgments

This is a Ruby port of the [JSONata JavaScript library](https://github.com/jsonata-js/jsonata) created by
Andrew Coleman and contributors.
