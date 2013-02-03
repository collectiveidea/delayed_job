source :rubygems

gem  'rake'
gem  'ruby-debug'

platforms :ruby do
  gem 'sqlite3'
end

platforms :jruby do
  gem 'jruby-openssl'
  gem 'activerecord-jdbcsqlite3-adapter'
end

group :test do
  gem 'activerecord', '~> 3.0'
  gem 'actionmailer', '~> 3.0'
  gem 'rspec', '>= 2.11'
  gem 'simplecov'
end

gemspec
