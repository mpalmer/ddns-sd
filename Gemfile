source 'https://rubygems.org'

gem 'docker-api', '~> 1.33'
# See https://github.com/swipely/docker-api/issues/409
gem 'excon', '~> 0.59'
gem 'frankenstein', '~> 1.0'

group :development do
  gem 'byebug'
  gem 'guard-rspec'
  gem 'guard-rubocop'
  gem 'pry-byebug'
  gem 'rake', '>= 11'
  gem 'redcarpet'
  gem 'rspec'
  gem 'rubocop'
  gem 'simplecov'
  gem 'yard'
end

group :azure_backend do
  gem 'azure_mgmt_dns', '~> 0.16'
end

group :route53_backend do
  gem 'aws-sdk', '~> 2.10'
end

group :psql_backend do
  gem 'sequel'
end

group :psql_sqlite do
  gem 'sqlite3'
end

group :psql_pg do
  gem 'pg'
end
