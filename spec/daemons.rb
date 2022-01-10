# Fake "daemons" file on the spec load path to allow spec/delayed/command_spec.rb
# to test the Delayed::Command class without actually adding daemons as a dependency.
module Daemons
  def self.run_proc(*_args)
    yield if block_given?
  end
end
