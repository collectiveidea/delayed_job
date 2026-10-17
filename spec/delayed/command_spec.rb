require 'helper'
require 'delayed/command'
require 'open3'

describe Delayed::Command do
  let(:options) { [] }
  let(:logger) { double('Logger') }

  subject { Delayed::Command.new options }

  before do
    allow(Delayed::Worker).to receive(:after_fork)
    allow(Dir).to receive(:chdir)
    allow(Logger).to receive(:new).and_return(logger)
    allow_any_instance_of(Delayed::Worker).to receive(:start)
    allow(Delayed::Worker).to receive(:logger=)
    allow(Delayed::Worker).to receive(:logger).and_return(nil, logger)
  end

  shared_examples_for 'uses --log-dir option' do
    context 'when --log-dir is specified' do
      let(:options) { ['--log-dir=/custom/log/dir'] }

      it 'creates the delayed_job.log in the specified directory' do
        expect(Logger).to receive(:new).with('/custom/log/dir/delayed_job.log')
        subject.run
      end
    end
  end

  describe 'run' do
    it 'sets the Delayed::Worker logger' do
      expect(Delayed::Worker).to receive(:logger=).with(logger)
      subject.run
    end

    context 'when Rails root is defined' do
      let(:rails_root) { Pathname.new '/rails/root' }
      let(:rails) { double('Rails', :root => rails_root) }

      before do
        stub_const('Rails', rails)
      end

      it 'runs the Delayed::Worker process in Rails.root' do
        expect(Dir).to receive(:chdir).with(rails_root)
        subject.run
      end

      context 'when --log-dir is not specified' do
        it 'creates the delayed_job.log in Rails.root/log' do
          expect(Logger).to receive(:new).with('/rails/root/log/delayed_job.log')
          subject.run
        end
      end

      include_examples 'uses --log-dir option'
    end

    context 'when Rails root is not defined' do
      let(:rails_without_root) { double('Rails') }

      before do
        stub_const('Rails', rails_without_root)
      end

      it 'runs the Delayed::Worker process in $PWD' do
        expect(Dir).to receive(:chdir).with(Delayed::Command::DIR_PWD)
        subject.run
      end

      context 'when --log-dir is not specified' do
        it 'creates the delayed_job.log in $PWD/log' do
          expect(Logger).to receive(:new).with("#{Delayed::Command::DIR_PWD}/log/delayed_job.log")
          subject.run
        end
      end

      include_examples 'uses --log-dir option'
    end

    context 'when an error is raised' do
      let(:test_error) { Class.new(StandardError) }

      before do
        allow(Delayed::Worker).to receive(:new).and_raise(test_error.new('An error'))
        allow(subject).to receive(:exit_with_error_status)
        allow(STDERR).to receive(:puts)
      end

      it 'prints the error message to STDERR' do
        expect(STDERR).to receive(:puts).with('An error')
        subject.run
      end

      it 'exits with an error status' do
        expect(subject).to receive(:exit_with_error_status)
        subject.run
      end

      context 'when Rails logger is not defined' do
        let(:rails) { double('Rails') }

        before do
          stub_const('Rails', rails)
        end

        it 'does not attempt to use the Rails logger' do
          subject.run
        end
      end

      context 'when Rails logger is defined' do
        let(:rails_logger) { double('Rails logger') }
        let(:rails) { double('Rails', :logger => rails_logger) }

        before do
          stub_const('Rails', rails)
        end

        it 'logs the error to the Rails logger' do
          expect(rails_logger).to receive(:fatal).with(test_error)
          subject.run
        end
      end
    end
  end

  describe 'parsing --pool argument' do
    it 'should parse --pool correctly' do
      command = Delayed::Command.new(['--pool=*:1', '--pool=test_queue:4', '--pool=mailers,misc:2'])

      expect(command.worker_pools).to eq [
        [[], 1],
        [['test_queue'], 4],
        [%w[mailers misc], 2]
      ]
    end

    it 'should allow * or blank to specify any pools' do
      command = Delayed::Command.new(['--pool=*:4'])
      expect(command.worker_pools).to eq [
        [[], 4],
      ]

      command = Delayed::Command.new(['--pool=:4'])
      expect(command.worker_pools).to eq [
        [[], 4],
      ]
    end

    it 'should default to one worker if not specified' do
      command = Delayed::Command.new(['--pool=mailers'])
      expect(command.worker_pools).to eq [
        [['mailers'], 1],
      ]
    end
  end

  describe 'loading' do
    # A separate process, because loading the file again would reset its coverage
    it 'asks for the daemons gem outside the test environment when it is missing' do
      lib = File.expand_path('../../lib', __dir__)
      _out, err, status = Open3.capture3({'RAILS_ENV' => 'development'}, RbConfig.ruby, '-I', lib, '-e', "require 'delayed/command'")
      expect(status).not_to be_success
      expect(err).to include("You need to add gem 'daemons' to your Gemfile if you wish to use it.")
    end
  end

  describe 'parsing options' do
    def parsed_options(args)
      Delayed::Command.new(args).instance_variable_get(:@options)
    end

    it 'prints usage and exits with --help' do
      expect { Delayed::Command.new(['--help']) }.to raise_error(SystemExit).and output(/Usage: .* start\|stop\|restart\|run/).to_stdout
    end

    it 'warns that --environment is deprecated' do
      expect { Delayed::Command.new(['--environment=production']) }.to output(/deprecated and has no effect/).to_stderr_from_any_process
    end

    it 'parses worker options' do
      options = parsed_options(%w[--min-priority 1 --max-priority 5 --pid-dir=/pids --identifier=3 --sleep-delay 9 --read-ahead 4 --prefix pre --queues=a,b --exit-on-complete])
      expect(options).to include(
        :min_priority => '1', :max_priority => '5', :pid_dir => '/pids', :identifier => '3', :sleep_delay => 9,
        :read_ahead => '4', :prefix => 'pre', :queues => %w[a b], :exit_on_complete => true
      )
    end

    it 'parses --queue' do
      expect(parsed_options(['--queue=mailers'])).to include(:queues => ['mailers'])
    end

    it 'parses the number of workers' do
      expect(Delayed::Command.new(['-n', '3']).worker_count).to eq(3)
    end
  end

  describe 'daemonize' do
    before do
      allow(FileUtils).to receive(:mkdir_p)
    end

    it 'runs a single worker' do
      command = Delayed::Command.new([])
      expect(command).to receive(:run_process).with('delayed_job', hash_including(:pid_dir => './tmp/pids'))
      command.daemonize
    end

    it 'runs when the pid dir already exists' do
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('./tmp/pids').and_return(true)
      command = Delayed::Command.new([])
      expect(command).to receive(:run_process).with('delayed_job', hash_including(:pid_dir => './tmp/pids'))
      command.daemonize
    end

    it 'runs numbered workers' do
      command = Delayed::Command.new(['-n', '2'])
      expect(command).to receive(:run_process).with('delayed_job.0', anything).ordered
      expect(command).to receive(:run_process).with('delayed_job.1', anything).ordered
      command.daemonize
    end

    it 'runs a worker with an identifier' do
      command = Delayed::Command.new(['--identifier=7'])
      expect(command).to receive(:run_process).with('delayed_job.7', hash_including(:identifier => '7'))
      command.daemonize
    end

    it 'refuses both an identifier and multiple workers' do
      command = Delayed::Command.new(['--identifier=7', '-n', '2'])
      expect { command.daemonize }.to raise_error(ArgumentError, 'Cannot specify both --number-of-workers and --identifier')
    end
  end

  describe 'run_process' do
    let(:daemons) { Daemons }

    before do
      allow(Delayed::Worker).to receive(:before_fork)
    end

    it 'runs the worker in a daemon' do
      command = Delayed::Command.new(['--monitor', 'start', '--daemon-options', 'a,b'])
      expect(daemons).to receive(:run_proc).
        with('delayed_job', :dir => './tmp/pids', :dir_mode => :normal, :monitor => true, :ARGV => %w[start a b]).
        and_yield
      options = {:pid_dir => './tmp/pids'}
      expect(command).to receive(:run).with('delayed_job', options)
      command.run_process('delayed_job', :pid_dir => './tmp/pids')
      expect(Delayed::Worker).to have_received(:before_fork)
    end

    it 'prefixes the process name' do
      program_name = $PROGRAM_NAME
      begin
        command = Delayed::Command.new(['--prefix', 'app'])
        allow(daemons).to receive(:run_proc).and_yield
        allow(command).to receive(:run)
        command.run_process('delayed_job', :prefix => 'app')
        expect($PROGRAM_NAME).to eq('app/delayed_job')
      ensure
        $PROGRAM_NAME = program_name
      end
    end
  end

  describe 'exit_with_error_status' do
    it 'exits with status 1' do
      expect { Delayed::Command.new([]).send(:exit_with_error_status) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe 'running worker pools defined by multiple --pool arguments' do
    it 'should run the correct worker processes' do
      command = Delayed::Command.new(['--pool=*:1', '--pool=test_queue:4', '--pool=mailers,misc:2'])
      expect(FileUtils).to receive(:mkdir_p).with('./tmp/pids').once

      [
        ['delayed_job.0', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => []}],
        ['delayed_job.1', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
        ['delayed_job.2', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
        ['delayed_job.3', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
        ['delayed_job.4', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
        ['delayed_job.5', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}],
        ['delayed_job.6', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}]
      ].each do |args|
        expect(command).to receive(:run_process).with(*args).once
      end

      command.daemonize
    end
  end
end
