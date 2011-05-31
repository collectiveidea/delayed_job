require 'rails/generators'

class DelayedJobGenerator < Rails::Generators::Base
  
  self.source_paths << File.join(File.dirname(__FILE__), 'templates')
  
  def create_script_file
    template 'script', 'script/delayed_job'
    chmod 'script/delayed_job', 0755
  end
end