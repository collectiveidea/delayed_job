require_relative '../../helper'
require_relative 'shared_examples'

describe Delayed::Launcher::Daemonized do
  let(:options) { {} }
  subject { described_class.new(options) }

  def verify_worker_processes
    exp.each do |args|
      expect(subject).to receive(:run_process).with(*args).once
    end
    subject.launch
  end

  it_behaves_like 'launcher shared examples'

  it 'prepares for forking before spawning workers' do
    expect(subject).to receive(:prepare_for_fork).ordered
    expect(subject).to receive(:run_process).ordered
    subject.launch
  end

  it 'rejects the pid_file option, which is for forking mode' do
    expect { described_class.new(:pid_file => true) }.to raise_error(ArgumentError, /--pid-file is for --fork mode/)
  end
end
