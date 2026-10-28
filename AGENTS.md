# AGENTS.md

Guidance for agents working on jsonata-rb. Read the README first; this file covers what the README does not:
the decisions behind the port and how JavaScript semantics are emulated in Ruby.

## Ground rules

- **Port, don't invent.** Every change to `lib/` should correspond to code in `vendor/jsonata-js/src`. When a
  test fails, find how jsonata-js does it and port that, rather than writing a new solution that happens to pass.
- **Keep the structure diffable.** Ruby files mirror the JS files: same function order, same names (snake_case),
  same comments (including the JSDoc text and TODOs). Ruby-only code is marked with a comment such as
  `(Ruby specific)` or `(jsonata-js: <original construct>)`, so it is clear what is a deviation.
- **Keep the upstream copyright headers.** Each ported file starts with the IBM copyright header of the JS file it
  ports (in ASCII, `(c)` for the copyright sign), as required by the MIT license. Copy the header when porting a
  new file, and update the years if upstream changes them.
- **Tests come from upstream only.** Language behavior is tested exclusively by the jsonata-js test suite via
  `spec/test_suite_spec.rb`. Do not add hand-written specs for language features. `spec/jsonata_spec.rb` is only
  for the Ruby API (conversion of values, `assign`, `register_function`, errors, ...).
- **Never edit `vendor/jsonata-js`.** It is a git submodule tracking jsonata-js master. Bump it with
  `rake jsonata_js:update` and commit the submodule bump together with the ported `lib/` changes.
- **ASCII only.** Code, comments and commit messages must not contain non-ASCII characters, including (but not
  limited to) em-dashes and en-dashes, curly quotes, the section sign, Greek letters (e.g. lambda) and
  mathematical symbols (e.g. less-than-or-equal). Use `"\uXXXX"` escapes in string literals that
  need non-ASCII characters, and ASCII equivalents in comments.
- **LF line endings.** Enforced by `.gitattributes`; never commit CRLF.
- **Optimize within Ruby, not by changing the algorithm.** Performance work may change how the Ruby is written
  (e.g. caching in the Ruby-only helpers in `utils.rb`), but must not change the logic ported from jsonata-js.
  Algorithmic improvements should be proposed upstream first, and then ported.
- **Ruby >= 3.1.** Do not use syntax or core methods newer than 3.1.
- **Rubocop must pass.** The style is ManageIQ's (`manageiq-style` gem), with project overrides in
  `.rubocop_local.yml`. Cops that would restructure ported code away from the JS are disabled there; prefer adding
  to that list (with the reason) over rewriting ported code to satisfy a cop. Review unsafe autocorrections by
  hand - some are wrong here (e.g. `Style/HashExcept` on `#parameters`, or `Style/BitwisePredicate`).

## Porting workflow for jsonata-js changes

The `jsonata-js sync` workflow (`.github/workflows/jsonata-js-sync.yaml`) runs these steps daily with Claude, once
per jsonata-js commit (with the submodule already checked out at that commit, so step 1 is skipped), and commits
each port separately on the `jsonata-js-sync` branch; they also apply when porting by hand. Merge the sync PR with
"Rebase and merge", so that each jsonata-js commit keeps a matching commit on master: the `jsonata-js tags` workflow
(`.github/workflows/jsonata-js-tags.yaml`) gives the commit syncing a jsonata-js release tag the same tag.

1. `bundle exec rake jsonata_js:update` - moves the submodule to jsonata-js master and lists new commits.
2. `bundle exec rake jsonata_js:diff` - shows the `src/` and `test/` changes since the commit recorded in this repo.
3. Port each `src/` hunk to the corresponding Ruby file (see the mapping table in the README), at the same place
   in the file.
4. `bundle exec rspec` (or `GROUP=<group> bundle exec rspec` while iterating) and `bundle exec rubocop` until
   everything passes.
5. If `test/run-test-suite.js` changed, port that change to `spec/test_suite_spec.rb`.
6. Changes to the JS-only mocha tests (`test/*.js` other than `run-test-suite.js`) are not run by this repo;
   only port them if they reveal behavior worth covering in `spec/jsonata_spec.rb`.

## JavaScript vs Ruby: decisions made

### undefined and null

- `nil` is JavaScript `undefined`. `Jsonata::NULL` (a frozen sentinel) is JSON `null`. This was chosen because
  JS code tests for `undefined` far more often than `null`, and Ruby methods return `nil` implicitly.
- Values are converted at the API boundary only: `Utils.from_ruby` (nested `nil` -> `NULL`, Symbol keys -> String
  keys) on the way in, `Utils.to_ruby` (`NULL` -> `nil`, `JArray` -> `Array`) on the way out. A top-level `nil`
  input or binding value means `undefined`.
- `Expression#evaluate_raw` returns the internal representation; the test harness uses it to tell `null` from
  `undefined`.

### Truthiness and typeof

- JS truthiness (`if (x)`, `!x`, `x || y`) on values must use `Utils.truthy?` - in Ruby `0`, `""` and `NULL` are
  truthy. Only use plain Ruby truthiness where the JS value is known to be a boolean/object/undefined.
- `typeof x` maps to `Utils.typeof(x)`. Remember `typeof null === 'object'` and arrays are objects in JS:
  `Utils.keys` returns index strings for arrays, as `Object.keys` does (needed by the wildcard operator).

### Objects, arrays and sequences

- JSON objects are Hashes with String keys (insertion ordered, like JS objects).
- jsonata-js attaches properties to arrays (`sequence`, `keepSingleton`, `tupleStream`, `cons`, `outerWrapper`).
  These live on `Jsonata::JArray < Array`. Read them with `x.is_a?(JArray) && x.flag` (or `Utils.sequence?`),
  because many arrays are plain `Array`s. Before setting a flag on an array that may be plain, wrap it in a
  `JArray`.
- In Ruby 3, `Array#+`, `#map`, `#select`, `#[]` with ranges etc. on a `JArray` return a plain `Array`. This
  matches JS, where `concat`/`slice`/`map` do not copy the custom properties.
- `createSequence` (with the `sequence` length limit) is `Frame#create_sequence` / `Focus#create_sequence`.
  `create_sequence(nil)` pushes `nil` (as JS does with an explicit `undefined` argument), while
  `create_sequence()` creates an empty sequence - keep the distinction.
- Beware Ruby negative indexes: `arr[-1]` is the last element, whereas JS returns `undefined`. Guard indexes that
  may be negative.

### Numbers

- JS numbers are doubles; here they are Integers when integral (and within +/-2^53) and Floats otherwise.
- Do arithmetic in Float and pass results through `Utils.normalize_number`, so integer overflow/precision behaves
  like JS and integral results come back as Integers.
- Do not use `Array#sum` - it uses Kahan-Babuska summation and gives different results from JS's naive loop.
- `Math.floor` on large values: use `Utils.js_floor`, which keeps the result a Float beyond 2^53.
- Formatting: `Utils.number_to_s` (Number::toString), `Utils.to_fixed` (toFixed), `Utils.to_precision`
  (toPrecision) are exact (via Rational), including JS's round-half-up tie breaking.
- `Math.round` is `(x.to_r + 1/2).floor` (ties toward +infinity), not Ruby's `round`.
- JS parsing helpers: `Utils.parse_int` (returns `nil` for NaN), `Utils.js_number` (`Number(str)`).

### Strings

- Ruby strings are indexed by code point, JS strings by UTF-16 code unit. The port uses code points throughout
  (consistent within Ruby); this only matters for characters outside the BMP.
- Ruby cannot hold UTF-16 surrogates. The tokenizer combines `\uD8xx\uDCxx` escape pairs into one character; a
  lone surrogate is stored as invalid UTF-8 bytes (`Utils.from_char_code`), which `encode_uri` rejects and
  `json_stringify` re-escapes as `\udxxx`.
- JS string helpers with different Ruby semantics: `Utils.js_slice`, `Utils.js_split` (keeps empty strings),
  `Utils.json_stringify` (JSON.stringify, including the replacer and indentation used by `$string`),
  `Utils.encode_uri` / `Utils.decode_uri`.

### Regular expressions

- Regex literals are parsed into `Parser::RegexLiteral` (source + flags) and translated by `Utils.js_regexp`:
  `^`/`$` become `\A`/`\z` unless the `m` flag is set, `[]` and `[^]` are rewritten, and `(?a)` is prepended so
  `\w`, `\d`, `\b` are ASCII-only as in JS.
- `RegExp.lastIndex` is emulated with a `last_index` variable captured by the matcher closure in
  `evaluate_regex`.
- The jsonata-js `RegexEngine` option is the `:regex_engine` option: a callable `(source, flags)` returning an
  object that responds to `match(str, pos)`.

### Functions

- Function values: `Jsonata::Lambda` (`_jsonata_lambda`), `Jsonata::NativeFunction` (`_jsonata_function`), and
  plain callables (`Proc`, `Method`, `Jsonata::Closure` - the JS function with an `arity` property).
  `Utils.function?` covers all of them; `Utils.callable?` is `typeof x === 'function'`.
- Built-in functions are instance methods of `Jsonata::Functions` and `Jsonata::DateTime`, which are included in
  `Jsonata::Focus`. A `Focus` is the JS `this` (`environment`, `input`, `options`, `create_sequence`), so
  `fn.lookup.call(focus, ...)` becomes `focus.lookup(...)`. Built-ins are registered with
  `Focus.instance_method(:name)`.
- `Utils.invoke` calls a Ruby callable with JS semantics: missing arguments become `nil` and extra arguments are
  dropped. Within built-ins, call function arguments with `call_function`, which also handles `Lambda#apply`.
- Arity (JS `Function.length`) is the number of *required* Ruby parameters. Declare built-in parameters as
  required (no defaults) unless the JS function has a default (e.g. `string(arg, prettify = false)`), otherwise
  higher-order functions like `$map` pass the wrong number of arguments.
- Partial application of native functions reads parameter names from `#parameters` (JS parses
  `func.toString()`).
- `not` is a valid Ruby method name and is used for `$not`.
- JS `async`/`await` is dropped; evaluation is synchronous. `Promise.all` loops run sequentially but still set
  `environment.is_parallel_call`, which the evaluate entry/exit hooks rely on. `$sort`'s recursive merge is
  iterative to avoid deep Ruby recursion.
- The `Symbol.for('jsonata.__evaluate_entry')` style hook names are Ruby Symbols, e.g.
  `:'jsonata.__evaluate_entry'`; `Expression#assign` keeps such Symbols as-is.

### Errors

- JS `throw { code: ... }` is `raise Jsonata::Error.new('CODE', field: ...)`; the fields use Ruby names
  (`function_name` for `functionName`) and `Error#to_h` maps them back. Messages are filled in by
  `Evaluator.populate_message` from `ERROR_CODES`.
- JS `catch (err)` catches everything; the port rescues only `Jsonata::Error`, so Ruby bugs surface as Ruby
  exceptions instead of being annotated as JSONata errors.
- `SystemStackError` is reported as `D1011` (Ruby specific). Non-tail recursion in an expression overflows the
  Ruby stack at roughly 600-1000 levels, as each JSONata call uses about a dozen Ruby frames; tail calls are
  handled by the trampoline in `Evaluator.apply`.

### Parser

- AST nodes are Hashes with Symbol keys (`:keep_array` for `keepArray`, etc.). Symbol keys keep AST nodes
  distinguishable from user data, which has String keys (e.g. the `?` placeholder check in partial application).
- JS nodes inherit `nud`/`led`/`lbp`/`id` from the symbol table via the prototype chain; here a
  `compare_by_identity` Hash maps each node to its `Sym`. `JSON.parse(JSON.stringify(node))` is `deep_clone`,
  which drops that mapping just as the JS clone drops the prototype.
- `nud`/`led` are blocks: use `next`, not `return`, to return early from them.

### Dates

- JS `Date` is a UTC Ruby `Time`. `DateTime.date_utc` reproduces `Date.UTC` (month overflow, truncation, years
  0-99 mapping to 1900+), and `DateTime.date_parse` reproduces `Date.parse` for the ISO 8601 subset accepted by
  `$toMillis`. Timestamps without an offset are treated as UTC.

### Test harness

- `spec/test_suite_spec.rb` mirrors `run-test-suite.js`. Results are compared with `evaluate_raw` against the
  expected JSON converted with `Utils.from_ruby`, so `null` and `undefined` are distinguished.
- Ruby's JSON parser rejects lone surrogates, so test files containing them are re-parsed with the surrogates
  escaped; they reach the tokenizer as `\uXXXX` in `expr`, and are decoded with `Utils.from_char_code` elsewhere.
