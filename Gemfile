source 'https://rubygems.org'

rails_version = ENV['RAILS_VERSION'] || ''

gem 'rake'

platforms :ruby do
  gem 'sqlite3'
end

platforms :jruby do
  gem 'jruby-openssl'
  if rails_version == 'edge' || rails_version.match(/5\.\d+\.\d+/)
    gem 'activerecord-jdbcsqlite3-adapter',
        :git => 'https://github.com/jruby/activerecord-jdbc-adapter.git',
        :branch => 'rails-5'
  else
    gem 'activerecord-jdbcsqlite3-adapter'
  end
  gem 'mime-types', ['~> 2.6', '< 2.99']
end

platforms :rbx do
  gem 'psych'
end

group :test do
  if ENV['RAILS_VERSION'] == 'edge'
    gem 'actionmailer', :github => 'rails/rails'
    gem 'activerecord', :github => 'rails/rails'
  else
    gem 'actionmailer', (ENV['RAILS_VERSION'] || ['>= 3.0', '< 5.1'])
    gem 'activerecord', (ENV['RAILS_VERSION'] || ['>= 3.0', '< 5.1'])
  end

  gem 'coveralls', :require => false
  gem 'rspec', '>= 3'
  gem 'rubocop', '>= 0.25', '< 0.49'
  gem 'simplecov', '>= 0.9'

  version = Gem::Requirement.parse(ENV['RAILS_VERSION']).last.version rescue nil
  if version == '4.2.0.beta1'
    # see https://github.com/rails/rails-deprecated_sanitizer/pull/1
    gem 'rails-deprecated_sanitizer', :github => 'rails/rails-deprecated_sanitizer'
  end

end

gemspec
