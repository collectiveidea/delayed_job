require 'helper'
require 'delayed/command'

describe Delayed::Command do
  let(:options) { [] }
  let(:logger) { double('Logger') }
  let(:output_options) { subject.instance_variable_get(:'@options') }
  subject { Delayed::Command.new(options) }

  def verify_worker_processes
    command = Delayed::Command.new(%w[-d] + options)
    allow(FileUtils).to receive(:mkdir_p)
    exp.each do |args|
      launcher = command.send(:launcher)
      args.last[:daemonized] = launcher.is_a?(Delayed::Launcher::Daemonized)
      expect(launcher).to receive(:run_process).with(*args).once
    end
    command.run
  end

  describe '#run' do
    it 'should use fork mode by default' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:run)
      Delayed::Command.new([]).run
    end

    it 'should use fork mode if --fork set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:run)
      Delayed::Command.new(%w[--fork]).run
    end

    it 'should use daemon mode if -d set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:run)
      Delayed::Command.new(%w[-d]).run
    end

    it 'should use daemon mode if --daemonize set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:run)
      Delayed::Command.new(%w[--daemonize]).run
    end

    it 'using multiple switches should use first one' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:run)
      Delayed::Command.new(%w[-d --fork]).run
    end
  end

  describe '#daemonize' do
    it 'should use daemon mode by default' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:run)
      Delayed::Command.new([]).daemonize
    end

    it 'should use fork mode if --fork set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:run)
      Delayed::Command.new(%w[--fork]).daemonize
    end

    it 'should use daemon mode if -d set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:run)
      Delayed::Command.new(%w[-d]).daemonize
    end

    it 'should use daemon mode if --daemonize set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:run)
      Delayed::Command.new(%w[--daemonize]).daemonize
    end

    it 'using multiple switches should use first one' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:run)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:run)
      Delayed::Command.new(%w[--fork -d]).daemonize
    end
  end

  describe '--min-priority arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:min_priority]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--min-priority 2] }
      it { expect(output_options[:min_priority]).to eq 2 }
    end

    context 'not a number' do
      let(:options) { %w[--min-priority sponge] }
      it { expect(output_options[:min_priority]).to eq nil }
    end
  end

  describe '--max-priority arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:max_priority]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--max-priority -5] }
      it { expect(output_options[:max_priority]).to eq(-5) }
    end

    context 'not a number' do
      let(:options) { %w[--max-priority giraffe] }
      it { expect(output_options[:max_priority]).to eq nil }
    end
  end

  describe '--num-workers arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:worker_count]).to eq 1 }
    end

    context '-n set' do
      let(:options) { %w[-n 2] }
      it { expect(output_options[:worker_count]).to eq 2 }
    end

    context '-n not a number' do
      let(:options) { %w[-n elephant] }
      it { expect(output_options[:worker_count]).to eq 1 }
    end

    context '--num-workers set' do
      let(:options) { %w[--num-workers 4] }
      it { expect(output_options[:worker_count]).to eq 4 }
    end

    context '--num-workers not a number' do
      let(:options) { %w[--num-workers hippo] }
      it { expect(output_options[:worker_count]).to eq 1 }
    end

    context '--number_of_workers set' do
      let(:options) { %w[--number_of_workers 5] }
      it do
        expect(STDERR).to receive(:puts)
        expect(output_options[:worker_count]).to eq 5
      end
    end

    context '--number_of_workers not a number' do
      let(:options) { %w[--number_of_workers rhino] }
      it do
        expect(STDERR).to receive(:puts)
        expect(output_options[:worker_count]).to eq 1
      end
    end
  end

  describe '--pid-dir arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:pid_dir]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--pid-dir ./foo/bar] }
      it { expect(output_options[:pid_dir]).to eq './foo/bar' }
    end

    context 'worker processes' do
      let(:options) { %w[--pid-dir ./foo/bar] }
      let(:exp) do
        [['delayed_job', {:quiet => true, :pid_dir => './foo/bar', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--log-dir arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:log_dir]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--log-dir ./foo/bar] }
      it { expect(output_options[:log_dir]).to eq './foo/bar' }
    end

    context 'worker processes' do
      let(:options) { %w[--log-dir ./foo/bar] }
      let(:exp) do
        [['delayed_job', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './foo/bar'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--monitor arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:monitor]).to eq false }
    end

    context 'set' do
      let(:options) { %w[--monitor] }
      it { expect(output_options[:monitor]).to eq true }
    end
  end

  describe '--sleep-delay arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:sleep_delay]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--sleep-delay 5] }
      it { expect(output_options[:sleep_delay]).to eq(5) }
    end

    context 'not a number' do
      let(:options) { %w[--sleep-delay giraffe] }
      it { expect(output_options[:sleep_delay]).to eq nil }
    end
  end

  describe '--read-ahead arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:read_ahead]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--read-ahead 5] }
      it { expect(output_options[:read_ahead]).to eq(5) }
    end

    context 'not a number' do
      let(:options) { %w[--read-ahead giraffe] }
      it { expect(output_options[:read_ahead]).to eq nil }
    end
  end

  describe '--identifier arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:identifier]).to eq nil }
    end

    context '-i set' do
      let(:options) { %w[-i bond] }
      it { expect(output_options[:identifier]).to eq 'bond' }
    end

    context '--identifier set' do
      let(:options) { %w[--identifier goldfinger] }
      it { expect(output_options[:identifier]).to eq 'goldfinger' }
    end

    context 'worker processes' do
      let(:options) { %w[--identifier spectre] }
      let(:exp) do
        [['delayed_job.spectre', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--prefix arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:prefix]).to eq nil }
    end

    context '-p set' do
      let(:options) { %w[-p oddjob] }
      it { expect(output_options[:prefix]).to eq 'oddjob' }
    end

    context '--prefix set' do
      let(:options) { %w[--prefix jaws] }
      it { expect(output_options[:prefix]).to eq 'jaws' }
    end
  end

  describe '--exit-on-complete arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:exit_on_complete]).to eq nil }
    end

    context '-x set' do
      let(:options) { %w[-x] }
      it { expect(output_options[:exit_on_complete]).to eq true }
    end

    context '--exit-on-complete set' do
      let(:options) { %w[--exit-on-complete] }
      it { expect(output_options[:exit_on_complete]).to eq true }
    end
  end

  describe '--verbose arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:quiet]).to eq true }
    end

    context '-v set' do
      let(:options) { %w[-v] }
      it { expect(output_options[:quiet]).to eq false }
    end

    context '--verbose set' do
      let(:options) { %w[--verbose] }
      it { expect(output_options[:quiet]).to eq false }
    end

    context 'worker processes' do
      let(:options) { %w[-v] }
      let(:exp) do
        [['delayed_job', {:quiet => false, :pid_dir => './tmp/pids', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--queues arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:queues]).to eq nil }
    end

    context '--queue set' do
      let(:options) { %w[--queue mailers] }
      it { expect(output_options[:queues]).to eq %w[mailers] }
    end

    context '--queues set' do
      let(:options) { %w[--queues mailers,tweets] }
      it { expect(output_options[:queues]).to eq %w[mailers tweets] }
    end

    context 'worker processes' do
      let(:options) { %w[--queues mailers,tweets] }
      let(:exp) do
        [['delayed_job', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers tweets]}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--pool arg' do
    context 'multiple --pool args set' do
      let(:options) { %w[--pool=*:1 --pool=test_queue:4 --pool=mailers,misc:2] }
      it 'should parse correctly' do
        expect(output_options[:pools]).to eq [
          [[], 1],
          [['test_queue'], 4],
          [%w[mailers misc], 2]
        ]
      end
    end

    context 'pipe-delimited' do
      let(:options) { %w[--pools=*:1|test_queue:4 --pool=mailers,misc:2] }
      it 'should parse correctly' do
        expect(output_options[:pools]).to eq [
          [[], 1],
          [['test_queue'], 4],
          [%w[mailers misc], 2]
        ]
      end
    end

    context 'queues specified as *' do
      let(:options) { ['--pool=*:4'] }
      it 'should use all queues' do
        expect(output_options[:pools]).to eq [[[], 4]]
      end
    end

    context 'queues not specified' do
      let(:options) { ['--pools=:4'] }
      it 'should use all queues' do
        expect(output_options[:pools]).to eq [[[], 4]]
      end
    end

    context 'worker count not specified' do
      let(:options) { ['--pool=mailers'] }
      it 'should default to one worker' do
        expect(output_options[:pools]).to eq [[['mailers'], 1]]
      end
    end

    context 'worker processes' do
      let(:options) { %w[--pool=*:1 --pool=test_queue:4 --pool=mailers,misc:2] }
      let(:exp) do
        [
          ['delayed_job.0', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => []}],
          ['delayed_job.1', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.2', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.3', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.4', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.5', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}],
          ['delayed_job.6', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}]
        ]
      end
      it { verify_worker_processes }
    end
  end

  describe '--daemon-options arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:exit_on_complete]).to eq nil }
      it 'does not affect launch_strategy' do
        expect(subject.instance_variable_get(:'@launch_strategy')).to eq nil
      end
    end

    context 'set' do
      let(:options) { %w[--daemon-options a,b,c] }
      it { expect(subject.instance_variable_get(:'@daemon_options')).to eq %w[a b c] }
      it 'coerces launch_strategy to :daemon' do
        expect(subject.instance_variable_get(:'@launch_strategy')).to eq :daemon
      end
    end
  end

  describe 'extra args' do
    context '--daemon-options not set' do
      let(:options) { %w[foo bar baz] }
      it { expect(output_options[:args]).to eq %w[foo bar baz] }
    end

    context '--daemon-options set' do
      let(:options) { %w[foo bar --daemon-options a,b,c baz] }
      it { expect(output_options[:args]).to eq %w[foo bar baz a b c] }
    end
  end

  describe 'validations' do
    it 'should launch normally without validations' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect(STDERR).to_not receive(:puts)
      Delayed::Command.new(%w[-d]).run
    end

    it 'raise error num-workers and identifier are present' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:run)
      expect(STDERR).to_not receive(:puts)
      expect { Delayed::Command.new(%w[-d --num-workers=2 --identifier=foobar]).run }.to raise_error(ArgumentError)
    end

    it 'warn if num-workers is 0' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect(STDERR).to receive(:puts)
      Delayed::Command.new(%w[-d --num-workers=0]).run
    end

    it 'not warn if min-priority is less than max-priority' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect(STDERR).to_not receive(:puts)
      Delayed::Command.new(%w[-d --min-priority=-5 --max-priority=0]).run
    end

    it 'not warn if min-priority equals max-priority' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect(STDERR).to_not receive(:puts)
      Delayed::Command.new(%w[-d --min-priority=-5 --max-priority=-5]).run
    end

    it 'warn if min-priority is greater than max-priority' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect(STDERR).to receive(:puts)
      Delayed::Command.new(%w[-d --min-priority=-4 --max-priority=-5]).run
    end

    it 'warn if both queues and pools are present' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect(STDERR).to receive(:puts)
      Delayed::Command.new(%w[-d --queues=mailers --pool=mailers:2]).run
    end

    it 'warn if both num-workers and pools are present' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:run)
      expect(STDERR).to receive(:puts)
      Delayed::Command.new(%w[-d --num-workers=2 --pool=mailers:2]).run
    end
  end
end
