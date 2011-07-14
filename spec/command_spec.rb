require 'spec_helper'
require 'delayed/command'

RAILS_ROOT = ''

describe Delayed::Command do
  before(:each) do
    @lines   = []
    @process = lambda { |pid| @lines.empty? ? (@lines = `ps -ho uid -p #{pid}`.lines.to_a) && @lines : @lines }
  end
  
  it "should raise RuntimeError if target user specified, but parent process started from unprivileged user" do
    args    = ["--pid-dir=/tmp", "--user=daemon", "run"]
    delayed = Delayed::Command.new(args)
    
    if Process.euid == 0
      true
    else
      lambda { delayed.daemonize }.should raise_error(RuntimeError)
    end
  end
  
  it "should raise ArgumentError if no target user specified, and parent process started from superuser" do
    args    = ["--pid-dir=/tmp", "--group=nobody", "run"]
    delayed = Delayed::Command.new(args)
    
    if Process.euid == 0
      lambda { delayed.daemonize }.should raise_error(ArgumentError)
    else
      lambda { delayed.daemonize }.should raise_error(RuntimeError)
    end
  end
  
  it "should start ontop delayed_job process" do
    args    = ["--pid-dir=/tmp", "run"]
    delayed = Delayed::Command.new(args)
  
    pid = fork do
      delayed.daemonize
      Process.detach($$)
    end

    @process.call(pid).count.should == 2
    @process.call(pid).last.strip.to_i.should == Process.euid
    
    Process.kill('KILL', pid)
  end
  
  it "should start ontop delayed_job process with 'daemon' system user/group" do
    args    = ["--pid-dir=/tmp", "--user=daemon", "run"]
    delayed = Delayed::Command.new(args)
    
    if Process.euid == 0
      pid = fork do
        delayed.daemonize
        Process.detach($$)
      end
      sleep(5)

      @process.call(pid).count.should == 2
      @process.call(pid).last.strip.to_i.should == Etc.getpwnam("daemon").uid

      Process.kill('KILL', pid)
    else
      lambda { delayed.daemonize }.should raise_error(RuntimeError)
    end
  end
end