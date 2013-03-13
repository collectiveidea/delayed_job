require 'rails/generators'
require File.expand_path(File.join(File.dirname(__FILE__), '..', '..', 'delayed', 'compatibility'))

class DelayedJobGenerator < Rails::Generators::Base

  self.source_paths << File.join(File.dirname(__FILE__), 'templates')

  def create_executable_file
    template Delayed::Compatibility.executable_prefix, "#{Delayed::Compatibility.executable_prefix}/delayed_job"
    chmod "#{Delayed::Compatibility.executable_prefix}/delayed_job", 0755
  end
end
