# require File.dirname(__FILE__) + '/database'

describe Delayed::Manager do
  before do
    @manager = mock('sample manager')
  end

  it "loads bundled managers" do
    Delayed::Worker.auto_scale_manager = :local
    Delayed::Manager.init_manager.class.should == Delayed::Manager::Local
  end

  it "forwards configurations bundled to managers" do
    Delayed::Worker.auto_scale_manager = :local, { :user => 'test' }
    Delayed::Manager::Local.should_receive(:new).with(:user => 'test')
    Delayed::Manager.init_manager
  end

  it "accepts custom managers" do
    Delayed::Worker.auto_scale_manager = @manager
    Delayed::Manager.init_manager.should == @manager
  end

  it "delegates to the manager instance" do
    Delayed::Worker.auto_scale_manager = @manager
    @manager.should_receive(:something).with(:test)
    Delayed::Manager.something(:test)
  end
end

