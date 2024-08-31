require 'helper'
require 'delayed/plugins/pidfile'
require 'fileutils'

describe Delayed::Plugins::Pidfile do
  around do |example|
    original_plugins = Delayed::Worker.plugins
    begin
      example.run
    ensure
      Delayed::Worker.plugins = original_plugins
    end
  end

  it 'creates a pidfile and then removes it' do
    Delayed::Worker.plugins << Delayed::Plugins::Pidfile

    pidfile_contents = nil
    Delayed::Worker.plugins << Class.new(Delayed::Plugin) do
      callbacks do |lifecycle|
        lifecycle.around(:execute) do
          pidfile_contents = File.read(Delayed::Plugins::Pidfile.pidfile)
        end
      end
    end

    expect(File.exist?(Delayed::Plugins::Pidfile.pidfile)).to be(false)

    worker = Delayed::Worker.new
    Delayed::Worker.lifecycle.run_callbacks(:execute, worker) {}

    expect(pidfile_contents).to eq("#{Process.pid}\n")
    expect(File.exist?(Delayed::Plugins::Pidfile.pidfile)).to be(false)
  end

  it 'raises an exception if pidfile already exists' do
    Delayed::Worker.plugins << Delayed::Plugins::Pidfile

    FileUtils.touch(Delayed::Plugins::Pidfile.pidfile)
    begin
      worker = Delayed::Worker.new
      expect { Delayed::Worker.lifecycle.run_callbacks(:execute, worker) {} }.to raise_error(Errno::EEXIST)
      # Doesn't remove the file.
      expect(File.exist?(Delayed::Plugins::Pidfile.pidfile)).to be(true)
    ensure
      File.unlink(Delayed::Plugins::Pidfile.pidfile)
    end
  end
end
