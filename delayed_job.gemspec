# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name              = 'delayed_job'
  s.version           = '2.0.7'
  s.authors           = ["Chris Gaffney", "Brandon Keepers", "Tobias L\303\274tke"]
  s.summary           = 'Database-backed asynchronous priority queue system -- Extracted from Shopify'
  s.description       = "Delayed_job (or DJ) encapsulates the common pattern of asynchronously executing longer tasks in the background. It is a direct extraction from Shopify where the job table is responsible for a multitude of core tasks.

This gem is collectiveidea's fork (http://github.com/collectiveidea/delayed_job)."
  s.email             = ['chris@collectiveidea.com', 'brandon@opensoul.org']
  s.extra_rdoc_files  = 'README.textile'
  s.files             = Dir.glob('{contrib,lib,generators,rails,recipes,spec,tasks}/**/*') +
                        %w(MIT-LICENSE README.textile)
  s.homepage          = 'http://github.com/collectiveidea/delayed_job'
  s.rdoc_options      = ["--main", "README.textile", "--inline-source", "--line-numbers"]
  s.require_paths     = ["lib"]
  s.test_files        = Dir.glob('spec/**/*')

  s.add_runtime_dependency      'daemons',        '1.0.10'
  s.add_runtime_dependency      'activesupport',  '~> 2.0'
  s.add_runtime_dependency      'rush',           '~> 0.6'

  s.add_development_dependency  'rspec',          '~> 1.0'
  s.add_development_dependency  'rake'
  s.add_development_dependency  'rails',          '~> 2.3'
  s.add_development_dependency  'sqlite3'
  s.add_development_dependency  'mysql'
  s.add_development_dependency  'mongo_mapper',   '~> 0.8.0'
  s.add_development_dependency  'dm-core'
  s.add_development_dependency  'dm-observer'
  s.add_development_dependency  'dm-aggregates'
  s.add_development_dependency  'dm-validations'
  s.add_development_dependency  'do_sqlite3'
  s.add_development_dependency  'database_cleaner'
end

