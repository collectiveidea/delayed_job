require_relative 'lib/delayed/version'

Gem::Specification.new do |spec|
  spec.add_dependency 'activesupport', ['>= 3.0', '< 6.2']
  spec.authors        = ['Brandon Keepers', 'Brian Ryckbost', 'Chris Gaffney', 'David Genord II', 'Erik Michaels-Ober', 'Matt Griffin', 'Steve Richert', 'Tobias Lütke']
  spec.description    = 'Delayed Job encapsulates the common pattern of asynchronously executing longer tasks in the background. It is a direct extraction from Shopify where the job table is responsible for a multitude of core tasks.'
  spec.email          = ['brian@collectiveidea.com']
  spec.files          = %w[CHANGELOG.md CONTRIBUTING.md LICENSE.txt README.md Rakefile delayed_job.gemspec]
  spec.files          += Dir.glob('{contrib,bin,lib,recipes,spec}/**/*') # rubocop:disable SpaceAroundOperators
  spec.executables    = ['delayed_job']
  spec.homepage       = 'http://github.com/collectiveidea/delayed_job'
  spec.licenses       = ['MIT']
  spec.name           = 'delayed_job'
  spec.require_paths  = ['lib']
  spec.summary        = 'Database-backed asynchronous priority queue system -- Extracted from Shopify'
  spec.test_files     = Dir.glob('spec/**/*')
  spec.version        = Delayed::VERSION
  spec.metadata       = {
    'changelog_uri'   => 'https://github.com/collectiveidea/delayed_job/blob/master/CHANGELOG.md',
    'bug_tracker_uri' => 'https://github.com/collectiveidea/delayed_job/issues',
    'source_code_uri' => 'https://github.com/collectiveidea/delayed_job'
  }
end
