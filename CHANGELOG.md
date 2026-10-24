# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and the version follows the jsonata-js version it is ported from (see [Versioning](README.md#versioning)).

## [Unreleased]

### Added
- Ruby port of jsonata-js: parser, evaluator, function library, date/time functions and signature validation
- The full JSONata language and function library
- `Jsonata::Error` with the jsonata-js error codes and messages
- `Expression#assign`, `#register_function`, `#ast`, `#errors` and `#evaluate_raw`
- `recover`, `timeout`, `stack`, `sequence` and `regex_engine` options
- The jsonata-js test suite, via a git submodule at `vendor/jsonata-js`
- `rake upstream:update` and `rake upstream:diff` tasks for tracking jsonata-js
