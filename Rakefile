exec(*(["bundle", "exec", $PROGRAM_NAME] + ARGV)) if ENV['BUNDLE_GEMFILE'].nil?

task default: :test
task default: :rubocop

begin
  Bundler.setup(:default, :development)
rescue Bundler::BundlerError => e
  $stderr.puts e.message
  $stderr.puts "Run `bundle install` to install missing gems"
  exit e.status_code
end

require 'yard'

task :rubocop do
  sh "rubocop"
end

YARD::Rake::YardocTask.new :doc do |yardoc|
  yardoc.files = %w{lib/**/*.rb - README.md CONTRIBUTING.md CODE_OF_CONDUCT.md}
end

desc "Run guard"
task :guard do
  sh "guard --clear"
end

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new :test do |t|
  t.pattern = "spec/**/*_spec.rb"
end

namespace :docker do
  desc "Build a new docker image"
  task :build do
    sh "docker build --pull -t womble/ddns-sd --build-arg=http_proxy=#{ENV['http_proxy']} --build-arg=GIT_REVISION=$(git rev-parse HEAD) ."
  end

  desc "Publish a new docker image"
  task publish: :build do
    sh "docker push womble/ddns-sd"
  end
end
