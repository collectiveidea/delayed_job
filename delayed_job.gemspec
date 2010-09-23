# -*- encoding: utf-8 -*-

Gem::Specification.new do |s|
  s.name              = 'delayed_job'
  s.version           = '2.0.4'
  s.authors           = ["Brandon Keepers", "Tobias L\303\274tke"]
  s.summary           = 'Database-backed asynchronous priority queue system -- Extracted from Shopify'
  s.description       = "Delayed_job (or DJ) encapsulates the common pattern of asynchronously executing longer tasks in the background. It is a direct extraction from Shopify where the job table is responsible for a multitude of core tasks.

This gem is collectiveidea's fork (http://github.com/collectiveidea/delayed_job)."
  s.email             = 'brandon@collectiveidea.com'
  s.extra_rdoc_files  = 'README.textile'
  s.files             = Dir.glob('{contrib,generators,lib,rails,recipes,spec,tasks}/**/*') +
                        %w(init.rb MIT-LICENSE README.textile)
  s.homepage          = 'http://github.com/collectiveidea/delayed_job'
  s.rdoc_options      = ["--main", "README.textile", "--inline-source", "--line-numbers"]
  s.require_paths     = ["lib"]
  s.test_files        = Dir.glob('spec/**/*')
  
  s.add_runtime_dependency      'daemons'
  s.add_runtime_dependency      'activesupport', '~>2.3'
  s.add_development_dependency  'rspec'
  s.add_development_dependency  'sqlite3-ruby'
  s.add_development_dependency  'activerecord'
end

