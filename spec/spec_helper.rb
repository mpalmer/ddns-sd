require 'bundler'
Bundler.setup(:default, :development)
require 'rspec/core'
require 'rspec/mocks'

require 'simplecov'
SimpleCov.start do
  add_filter('spec')
end
SimpleCov.refuse_coverage_drop

class ListIncompletelyCoveredFiles
  def format(result)
    incompletes = result.files.select { |f| f.covered_percent < 100 }

    unless incompletes.empty?
      puts
      puts "Files with incomplete test coverage:"
      incompletes.each do |f|
        printf "    %2.02f%%    %s", f.covered_percent, f.filename
      end
      puts; puts
    end
  end
end

SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new([
  SimpleCov::Formatter::HTMLFormatter,
  ListIncompletelyCoveredFiles
])

RSpec.configure do |config|
  config.fail_fast = true
  config.order     = :random
  #config.full_backtrace = true

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
end

# TODO: move to support dir
require_relative './matcher_methods'
require_relative './example_group_methods'
require_relative './example_methods'

Dir["./spec/support/**/*.rb"].each { |f| require f }

RSpec.configure do |config|
  config.include ExampleMethods
  config.extend  ExampleGroupMethods
  config.include PowerDNSHelper
end
