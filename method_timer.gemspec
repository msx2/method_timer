# frozen_string_literal: true

require_relative 'lib/method_timer/version'

Gem::Specification.new do |spec|
  spec.name = 'method_timer'
  spec.version = MethodTimer::VERSION
  spec.authors = ['Konrad Jurkowski']
  spec.email = ['konrad@jurkowski.me']

  spec.summary = 'Low-overhead per-method timing for Ruby code, made for profiling from a console.'
  spec.description = 'Instruments every method under a class or namespace and reports self/total time, ' \
                     'SQL time, GC time, allocations and call counts, with allocation-free wrappers and ' \
                     'an estimate of its own overhead.'
  spec.required_ruby_version = '>= 3.4'
  spec.homepage = 'https://github.com/msx2/method_timer'
  spec.license = 'MIT'

  spec.files = Dir['lib/**/*.rb', 'README.md', 'LICENSE.txt']
  spec.require_paths = ['lib']
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['rubygems_mfa_required'] = 'true'
end
