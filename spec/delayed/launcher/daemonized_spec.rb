require_relative '../../helper'

describe Delayed::Launcher::Daemonized do
  def verify_worker_processes
    exp.each do |args|
      args.last[:daemonized] = true
      expect(subject).to receive(:run_process).with(*args).once
    end
    subject.run
  end

  let(:options) { {} }
  subject { described_class.new(options) }

  before do
    # stub I/O methods
    allow(ObjectSpace).to receive(:each_object)
    allow(FileUtils).to receive(:mkdir_p)
    allow(Dir).to receive(:chdir)
  end

  describe 'run_worker' do
    let(:logger) { double('Logger') }

    before do
      allow(Delayed::Worker).to receive(:after_fork)
      allow_any_instance_of(Delayed::Worker).to receive(:start)
      allow(Logger).to receive(:new).and_return(logger)
      allow(Delayed::Worker).to receive(:logger=)
      allow(Delayed::Worker).to receive(:logger).and_return(nil, logger)
    end

    shared_examples_for 'uses log_dir option' do
      context 'when log_dir is specified' do
        let(:options) { {:log_dir => '/custom/log/dir'} }

        it 'creates the delayed_job.log in the specified directory' do
          expect(Logger).to receive(:new).with('/custom/log/dir/delayed_job.log')
          subject.send(:run_worker, 'delayed_job.0', {})
        end
      end
    end

    it 'sets the Delayed::Worker logger' do
      expect(Delayed::Worker).to receive(:logger=).with(logger)
      subject.send(:run_worker, 'delayed_job.0', {})
    end

    context 'when Rails root is defined' do
      let(:rails_root) { Pathname.new '/rails/root' }
      let(:rails) { double('Rails', :root => rails_root) }

      before do
        stub_const('Rails', rails)
      end

      it 'runs the Delayed::Worker process in Rails.root' do
        expect(Dir).to receive(:chdir).with(rails_root)
        subject.send(:run_worker, 'delayed_job.0', {})
      end

      context 'when --log-dir is not specified' do
        it 'creates the delayed_job.log in Rails.root/log' do
          expect(Logger).to receive(:new).with('/rails/root/log/delayed_job.log')
          subject.send(:run_worker, 'delayed_job.0', {})
        end
      end

      include_examples 'uses log_dir option'
    end

    context 'when Rails root is not defined' do
      let(:rails_without_root) { double('Rails') }

      before do
        stub_const('Rails', rails_without_root)
      end

      it 'runs the Delayed::Worker process in $PWD' do
        expect(Dir).to receive(:chdir).with(Pathname.new(Dir.pwd))
        subject.send(:run_worker, 'delayed_job.0', {})
      end

      context 'when --log-dir is not specified' do
        it 'creates the delayed_job.log in $PWD/log' do
          expect(Logger).to receive(:new).with("#{Pathname.new(Dir.pwd)}/log/delayed_job.log")
          subject.send(:run_worker, 'delayed_job.0', {})
        end
      end

      include_examples 'uses log_dir option'
    end

    context 'when an error is raised' do
      let(:test_error) { Class.new(StandardError) }

      before do
        allow(Delayed::Worker).to receive(:new).and_raise(test_error.new('An error'))
        allow(subject).to receive(:exit_with_error_status)
        allow(STDERR).to receive(:puts)
      end

      context 'using Delayed::Worker logger' do
        before do
          expect(logger).to receive(:fatal).with(test_error)
        end

        it 'prints the error message to STDERR' do
          expect(STDERR).to receive(:puts).with('An error')
          subject.send(:run_worker, 'delayed_job.0', {})
        end

        it 'exits with an error status' do
          expect(subject).to receive(:exit_with_error_status)
          subject.send(:run_worker, 'delayed_job.0', {})
        end

        context 'when Rails logger is not defined' do
          let(:rails) { double('Rails') }

          before do
            stub_const('Rails', rails)
          end

          it 'does not attempt to use the Rails logger' do
            subject.send(:run_worker, 'delayed_job.0', {})
          end
        end
      end

      context 'when Rails logger is defined' do
        let(:rails_logger) { double('Rails logger') }
        let(:rails) { double('Rails', :logger => rails_logger) }

        before do
          stub_const('Rails', rails)
          allow(Delayed::Worker).to receive(:logger).and_return(nil)
        end

        it 'logs the error to the Rails logger' do
          expect(rails_logger).to receive(:fatal).with(test_error)
          subject.send(:run_worker, 'delayed_job.0', {})
        end
      end
    end
  end

  describe 'spawning workers' do
    context 'no args' do
      let(:options) { {} }
      let(:exp) do
        [['delayed_job', {:pid_dir => './tmp/pids', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end

    context ':pools arg' do
      let(:options) { {:pools => [[[], 1], [['test_queue'], 4], [%w[mailers misc], 2]]} }
      let(:exp) do
        [
          ['delayed_job.0', {:pid_dir => './tmp/pids', :log_dir => './log', :queues => []}],
          ['delayed_job.1', {:pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.2', {:pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.3', {:pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.4', {:pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.5', {:pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}],
          ['delayed_job.6', {:pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}]
        ]
      end
      it { verify_worker_processes }
    end

    context ':queues and :worker_count args' do
      let(:options) { {:queues => %w[mailers misc], :worker_count => 4} }
      let(:exp) do
        [
          ['delayed_job.0', {:pid_dir => './tmp/pids', :log_dir => './log', :queues =>  %w[mailers misc]}],
          ['delayed_job.1', {:pid_dir => './tmp/pids', :log_dir => './log', :queues =>  %w[mailers misc]}],
          ['delayed_job.2', {:pid_dir => './tmp/pids', :log_dir => './log', :queues =>  %w[mailers misc]}],
          ['delayed_job.3', {:pid_dir => './tmp/pids', :log_dir => './log', :queues =>  %w[mailers misc]}]
        ]
      end
      it { verify_worker_processes }
    end

    context ':pid_dir and :log_dir args' do
      let(:options) { {:pid_dir => './foo/bar', :log_dir => './baz/qux', :worker_count => 2} }
      let(:exp) do
        [
          ['delayed_job.0', {:pid_dir => './foo/bar', :log_dir => './baz/qux'}],
          ['delayed_job.1', {:pid_dir => './foo/bar', :log_dir => './baz/qux'}],
        ]
      end
      it { verify_worker_processes }
    end

    context ':identifier and other args' do
      let(:options) { {:monitor => true, :prefix => 'my_prefix', :identifier => 'my_identifier', :worker_count => 2, :args => {:foo => 'bar', :baz => 'qux'}} }
      let(:exp) do
        [['delayed_job.my_identifier', {:pid_dir => './tmp/pids', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end
  end
end
