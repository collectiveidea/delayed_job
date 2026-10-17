Gem::Specification.new do |spec|
  spec.add_dependency 'activesupport', ['>= 3.0', '< 9.0']
  spec.add_dependency 'benchmark'
  spec.add_dependency 'logger'
  spec.authors        = ['Brandon Keepers', 'Brian Ryckbost', 'Chris Gaffney', 'David Genord II', 'Erik Berlin', 'Matt Griffin', 'Steve Richert', 'Tobias Lütke']
  spec.description    = 'Delayed_job (or DJ) encapsulates the common pattern of asynchronously executing longer tasks in the background. It is a direct extraction from Shopify where the job table is responsible for a multitude of core tasks.'
  spec.email          = ['brian@collectiveidea.com']
  spec.files          = %w[CHANGELOG.md CONTRIBUTING.md LICENSE.md README.md Rakefile delayed_job.gemspec]
  spec.files          += Dir.glob('{contrib,lib,recipes,spec}/**/*') # rubocop:disable Layout/SpaceAroundOperators
  spec.homepage       = 'http://github.com/collectiveidea/delayed_job'
  spec.licenses       = ['MIT']
  spec.name           = 'delayed_job'
  spec.require_paths  = ['lib']
  spec.required_ruby_version = '>= 3.2'
  spec.summary        = 'Database-backed asynchronous priority queue system -- Extracted from Shopify'
  spec.version        = '4.2.0'
  spec.metadata       = {
    'changelog_uri' => 'https://github.com/collectiveidea/delayed_job/blob/master/CHANGELOG.md',
    'bug_tracker_uri' => 'https://github.com/collectiveidea/delayed_job/issues',
    'source_code_uri' => 'https://github.com/collectiveidea/delayed_job',
    'rubygems_mfa_required' => 'true'
  }
end
