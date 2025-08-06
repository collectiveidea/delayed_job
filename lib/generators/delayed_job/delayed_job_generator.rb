require 'rails/generators/base'
require 'delayed/compatibility'

class DelayedJobGenerator < Rails::Generators::Base
  source_paths << File.join(File.dirname(__FILE__), 'templates')

  def create_executable_file
    template 'script', 'bin/delayed_job'
    chmod 'bin/delayed_job', 0o755
  end
end
