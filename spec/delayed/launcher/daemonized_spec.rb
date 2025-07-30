require_relative '../../helper'
require_relative 'shared_examples'

describe Delayed::Launcher::Daemonized do
  def verify_worker_processes
    exp.each do |args|
      expect(subject).to receive(:run_process).with(*args).once
    end
    subject.launch
  end

  it_behaves_like 'launcher shared examples'
end
