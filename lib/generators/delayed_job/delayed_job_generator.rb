require 'rails/generators'

class DelayedJobGenerator < Rails::Generators::Base

  self.source_paths << File.join(File.dirname(__FILE__), 'templates')

  def create_script_file
    scripts_dir = (ActiveSupport::VERSION::MAJOR >= 4) ? 'bin' : 'script'
    template 'script', "#{scripts_dir}/delayed_job"
    chmod "#{scripts_dir}/delayed_job", 0755
  end
end
