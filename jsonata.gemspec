# frozen_string_literal: true

require_relative 'lib/jsonata/version'

Gem::Specification.new do |spec|
  spec.name = 'jsonata'
  spec.version = Jsonata::VERSION
  spec.authors = ['Jason Frey']
  spec.email = ['fryguy9@gmail.com']

  spec.summary = 'JSONata query and transformation language for Ruby'
  spec.description = 'A Ruby port of jsonata-js, the reference implementation of JSONata - a lightweight query and transformation language for JSON data'
  spec.homepage = 'https://github.com/yourusername/jsonata-rb'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.1.0'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features|vendor)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end

  spec.bindir = 'exe'
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']

  # Development dependencies
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.0'
  spec.add_development_dependency 'rubocop', '~> 1.0'
end
