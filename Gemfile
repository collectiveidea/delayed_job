source 'https://rubygems.org'

gem 'rake'

platforms :ruby do
  # Rails 7.2 is the first to work with sqlite3 2.x
  if ENV['RAILS_VERSION'] && ENV['RAILS_VERSION'] < '7.2'
    gem 'sqlite3', '~> 1.4'
  else
    gem 'sqlite3'
  end
end

platforms :jruby do
  case ENV.fetch('RAILS_VERSION', nil)
  when '6.0.0'
    gem 'activerecord-jdbcsqlite3-adapter', '~> 60.0'
  when '6.1.0'
    gem 'activerecord-jdbcsqlite3-adapter', '~> 61.0'
  when nil
    # Without a Rails pin the resolver would otherwise pair a modern
    # Active Record with an ancient 1.x adapter that has no upper bound
    # on activerecord
    gem 'activerecord-jdbcsqlite3-adapter', '~> 72.1'
  else
    gem 'activerecord-jdbcsqlite3-adapter'
  end
  gem 'jruby-openssl'
  gem 'mime-types', ['~> 2.6', '< 2.99']

  # rdoc 8 depends on rbs, whose native extension does not build on JRuby;
  # railties pulls rdoc in via irb
  gem 'rdoc', '< 8'

  if ENV['RAILS_VERSION'] == 'edge'
    gem 'railties', :github => 'rails/rails'
  elsif ENV['RAILS_VERSION']
    gem 'railties', "~> #{ENV['RAILS_VERSION']}"
  else
    gem 'railties', ['>= 3.0', '< 9.0']
  end
end

platforms :rbx do
  gem 'psych'
end

group :test do
  if ENV['RAILS_VERSION'] == 'edge'
    gem 'actionmailer', :github => 'rails/rails'
    gem 'activejob',    :github => 'rails/rails'
    gem 'activerecord', :github => 'rails/rails'
  elsif ENV['RAILS_VERSION']
    gem 'actionmailer', "~> #{ENV['RAILS_VERSION']}"
    gem 'activerecord', "~> #{ENV['RAILS_VERSION']}"

    if ENV['RAILS_VERSION'] < '5.1'
      gem 'loofah', '2.3.1'
      gem 'nokogiri', '< 1.11.0'
      gem 'rails-html-sanitizer', '< 1.4.0'
    end
  else
    gem 'actionmailer', ['>= 3.0', '< 9.0']
    gem 'activerecord', ['>= 3.0', '< 9.0']
  end
  gem 'net-smtp'
  gem 'rspec', '>= 3'
  gem 'simplecov', '>= 1', :require => false
  gem 'simplecov-lcov', :require => false
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0')
    # New dependencies with a deprecation notice in Ruby 3.3 and required in Ruby 3.4
    # Probably won't get released in rails 7.0
    gem 'base64'
    gem 'bigdecimal'
    gem 'mutex_m'
    gem 'ostruct'
  end
  gem 'concurrent-ruby'
  gem 'zeitwerk', :require => false if ENV['RAILS_VERSION'].nil? || ENV['RAILS_VERSION'] >= '6.0.0'
end

group :rubocop do
  gem 'rubocop', '~> 1.88'
end

gemspec
