# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name              = 'delayed_job'
  s.version           = '3.0.4'
  s.authors           = ["Matt Griffin", "Brian Ryckbost", "Steve Richert", "Chris Gaffney", "Brandon Keepers", "Tobias L\303\274tke", "David Genord II"]
  s.summary           = 'Database-backed asynchronous priority queue system -- Extracted from Shopify'
  s.description       = "Delayed_job (or DJ) encapsulates the common pattern of asynchronously executing longer tasks in the background. It is a direct extraction from Shopify where the job table is responsible for a multitude of core tasks.

This gem is collectiveidea's fork (http://github.com/collectiveidea/delayed_job)."
  s.email             = ['brian@collectiveidea.com']
  s.extra_rdoc_files  = 'README.textile'
  s.files             = Dir.glob('{contrib,lib,recipes,spec}/**/*') +
                        %w(MIT-LICENSE README.textile)
  s.homepage          = 'http://github.com/collectiveidea/delayed_job'
  s.rdoc_options      = ["--main", "README.textile", "--inline-source", "--line-numbers"]
  s.require_paths     = ["lib"]
  s.test_files        = Dir.glob('spec/**/*')

  s.add_runtime_dependency      'activesupport',  '~> 3.0'

  s.add_development_dependency  'activerecord',   '~> 3.0'
  s.add_development_dependency  'actionmailer',   '~> 3.0'
  s.add_development_dependency  'rspec',          '~> 2.11'
  s.add_development_dependency  'rake'
  s.add_development_dependency  'simplecov'
end
