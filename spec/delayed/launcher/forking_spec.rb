require_relative '../../helper'
require_relative 'shared_examples'

describe Delayed::Launcher::Forking do
  before do
    @workers = []
    allow(Delayed::Worker).to receive(:logger).and_return(Logger.new(nil))
    allow_any_instance_of(described_class).to receive(:run_loop).and_return(nil)
    allow_any_instance_of(described_class).to receive(:fork_worker) { |_, *args| @workers << args }
    allow_any_instance_of(described_class).to receive(:setup_single_worker) do
      @workers << [subject.send(:get_name, subject.send(:process_identifier)), subject.instance_variable_get(:'@options')]
    end
  end

  def verify_worker_processes
    subject.launch
    expect(@workers).to eq(exp)
  end

  it_behaves_like 'launcher shared examples'
end
