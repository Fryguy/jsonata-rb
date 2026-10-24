# frozen_string_literal: true

require 'rake'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

task :default => :spec

desc 'Run RSpec tests'
task :test => :spec

desc 'Open an interactive console'
task :console do
  require 'irb'
  require_relative 'lib/jsonata'
  ARGV.clear
  IRB.start
end

JSONATA_JS_DIR = 'vendor/jsonata-js'

namespace :jsonata_js do
  # The jsonata-js commit recorded in the superproject (HEAD, falling back to the index)
  def recorded_jsonata_js_commit
    commit = `git ls-tree HEAD #{JSONATA_JS_DIR} 2>/dev/null`.split[2]
    commit || `git ls-files -s #{JSONATA_JS_DIR}`.split[1]
  end

  desc 'Update the jsonata-js submodule to the latest jsonata-js master'
  task :update do
    sh "git -C #{JSONATA_JS_DIR} fetch origin"
    sh "git -C #{JSONATA_JS_DIR} checkout --quiet origin/master"
    sh "git -C #{JSONATA_JS_DIR} log --oneline #{recorded_jsonata_js_commit}..HEAD -- src test"
  end

  desc 'Show the jsonata-js source and test changes that have not yet been committed to this repo'
  task :diff do
    sh "git -C #{JSONATA_JS_DIR} diff #{recorded_jsonata_js_commit} HEAD -- src test"
  end
end
