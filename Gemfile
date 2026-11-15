source 'https://rubygems.org'

rails_version = ENV.fetch('RAILS_VERSION', nil)
# Default to the newest Rails the JDBC adapters support. Without a pin
# the resolver would pair a modern Active Record with an ancient 1.x
# adapter, which has no upper bound on activerecord. JRuby 10.1
# removed the Java APIs the stable 72.x adapters were compiled
# against, so only the Rails 8 prerelease adapter works there.
if RUBY_ENGINE == 'jruby'
  rails_version ||= Gem::Version.new(JRUBY_VERSION) >= Gem::Version.new('10.1') ? '8.0.0' : '7.2.0'
end

gem 'rake'
gem 'rake-compiler', :platforms => :ruby # rake compile: the C extension (ext/delayed_job)

platforms :ruby do
  # Rails 5.1 is the first to work with sqlite 1.4
  # Rails 6 now requires sqlite 1.4
  # Rails 7.2 is the first to work with sqlite3 2.x
  if rails_version && rails_version < '5.1'
    gem 'sqlite3', '< 1.4'
  elsif rails_version && rails_version < '7.2'
    gem 'sqlite3', '~> 1.4'
  else
    gem 'sqlite3'
  end
end

platforms :jruby do
  case rails_version
  when '4.2.0'
    gem 'activerecord-jdbcsqlite3-adapter', '< 50.0'
  when '5.0.0'
    gem 'activerecord-jdbcsqlite3-adapter', '~> 50.0'
  when '5.1.0'
    gem 'activerecord-jdbcsqlite3-adapter', '~> 51.0'
  when '5.2.0'
    gem 'activerecord-jdbcsqlite3-adapter', '~> 52.0'
  when '6.0.0'
    gem 'activerecord-jdbcsqlite3-adapter', '~> 60.0'
  when '6.1.0'
    gem 'activerecord-jdbcsqlite3-adapter', '~> 61.0'
  when '8.0.0'
    # Rails 8 support is prerelease-only so far, and the resolver never
    # picks prereleases without an explicit pin
    gem 'activerecord-jdbcsqlite3-adapter', '80.0.pre1'
  else
    gem 'activerecord-jdbcsqlite3-adapter'
  end
  gem 'jruby-openssl'
  gem 'mime-types', ['~> 2.6', '< 2.99']

  # railties pulls rdoc in via irb. rdoc 6.4+ depends on the psych gem,
  # and Bundler installs its own copy of psych even though JRuby ships it
  # as a default gem. psych-java declares a Maven jar (snakeyaml-engine),
  # so installing it runs jar-dependencies' Maven post-install hook, which
  # intermittently crashes on JRuby 10.0 and breaks `bundle install`.
  # rdoc < 6.4 has no psych dependency, which also rules out rdoc 8, whose
  # rbs dependency has a native extension that does not build on JRuby.
  # Nothing in the specs loads rdoc.
  gem 'rdoc', '< 6.4'

  if rails_version == 'edge'
    gem 'railties', :github => 'rails/rails'
  elsif rails_version
    gem 'railties', "~> #{rails_version}"
  else
    gem 'railties', ['>= 3.0', '< 9.0']
  end
end

platforms :rbx do
  gem 'psych'
end

group :test do
  if rails_version == 'edge'
    gem 'actionmailer', :github => 'rails/rails'
    gem 'activejob',    :github => 'rails/rails'
    gem 'activerecord', :github => 'rails/rails'
  elsif rails_version
    gem 'actionmailer', "~> #{rails_version}"
    gem 'activerecord', "~> #{rails_version}"

    if rails_version < '5.1'
      gem 'loofah', '2.3.1'
      gem 'nokogiri', '< 1.11.0'
      gem 'rails-html-sanitizer', '< 1.4.0'
    end
  else
    gem 'actionmailer', ['>= 3.0', '< 9.0']
    gem 'activerecord', ['>= 3.0', '< 9.0']
  end
  gem 'net-smtp' if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.1.0')
  gem 'rspec', '>= 3'
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0')
    gem 'simplecov', '~> 1.3', :require => false
  elsif Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.2.0')
    # SimpleCov 1.3 requires Ruby 3.3
    gem 'simplecov', '~> 1.2.0', :require => false
  else
    # SimpleCov 1.0 requires Ruby 3.2
    gem 'simplecov', :require => false
  end
  if /\A2.[12]/ =~ RUBY_VERSION
    # 0.8.0 doesn't work with simplecov < 0.18.0 and older ruby can't run 0.18.0
    gem 'simplecov-lcov', '< 0.8.0', :require => false
  else
    gem 'simplecov-lcov', :require => false
  end
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new('3.3.0')
    # New dependencies with a deprecation notice in Ruby 3.3 and required in Ruby 3.4
    # Probably won't get released in rails 7.0
    gem 'base64'
    gem 'bigdecimal'
    gem 'mutex_m'
    gem 'ostruct'
  elsif Gem::Version.new(RUBY_VERSION) <= Gem::Version.new('2.2.100')
    gem 'logger', '< 1.3'
  end
  gem 'concurrent-ruby'
  gem 'zeitwerk', :require => false if rails_version.nil? || rails_version >= '6.0.0'
end

group :rubocop do
  gem 'rubocop', '~> 1.88'
end

gemspec
