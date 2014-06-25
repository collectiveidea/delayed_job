source 'https://rubygems.org'

gem 'rake'

platforms :ruby, :mingw do
  gem 'sqlite3'
end

platforms :jruby do
  gem 'jruby-openssl'
  gem 'activerecord-jdbcsqlite3-adapter'
end

group :test do
  gem 'activerecord', (ENV['RAILS_VERSION'] || ['>= 3.0', '< 4.2'])
  gem 'actionmailer', (ENV['RAILS_VERSION'] || ['>= 3.0', '< 4.2'])
  gem 'coveralls', :require => false
  gem 'rspec', '>= 3'
  gem 'simplecov', :require => false
end

gemspec
