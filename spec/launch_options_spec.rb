require 'helper'

# One set of rules for the command line and rake jobs:work.
describe Delayed::LaunchOptions do
  let(:cli) { described_class::CLI_NAMES }

  describe '.parse' do
    it 'parses whole numbers and seconds' do
      expect(described_class.parse(:threads, ' 4 ', '--threads')).to eq 4
      expect(described_class.parse(:prefetch, '0', '--prefetch')).to eq 0
      expect(described_class.parse(:max_priority, '-5', '--max-priority')).to eq(-5)
      expect(described_class.parse(:sleep_delay, '0.5', '--sleep-delay')).to eq 0.5
    end

    it 'reads 010 as ten, not octal' do
      expect(described_class.parse(:processes, '010', '--processes')).to eq 10
    end

    {
      [:processes, '0'] => '--processes must be 1 or greater',
      [:processes, 'x'] => '--processes must be 1 or greater',
      [:threads, '1.5'] => '--threads must be 1 or greater',
      [:read_ahead, '0x5'] => '--read-ahead must be 1 or greater',
      [:prefetch, '21'] => '--prefetch must be a whole number from 0 to 20',
      [:min_priority, 'low'] => '--min-priority must be a whole number',
      [:sleep_delay, '-1'] => '--sleep-delay must be a number of seconds, 0 or greater',
      [:shutdown_timeout, '1e3'] => '--shutdown-timeout must be a number of seconds, 0 or greater',
      [:lock_heartbeat_interval, '0'] => '--lock-heartbeat must be greater than 0',
      [:lock_timeout, ''] => '--lock-timeout must be greater than 0'
    }.each do |(option, text), message|
      it "rejects #{option} #{text.inspect}" do
        expect { described_class.parse(option, text, cli[option]) }.to raise_error(ArgumentError, message)
      end
    end

    it 'names the option as given' do
      expect { described_class.parse(:threads, '0', 'NUM_THREADS') }.to raise_error(ArgumentError, 'NUM_THREADS must be 1 or greater')
    end
  end

  describe '.validate!' do
    it 'accepts valid options' do
      expect { described_class.validate!({:processes => 2, :threads => 4, :lock_heartbeat_interval => 10, :lock_timeout => 20}, cli) }.not_to raise_error
    end

    it 'rejects values set other than by parsing' do
      expect { described_class.validate!({:processes => 0}, cli) }.to raise_error(ArgumentError, '--processes must be 1 or greater')
      expect { described_class.validate!({:prefetch => 'x'}, cli) }.to raise_error(ArgumentError, /--prefetch/)
    end

    it 'checks the lock timeout against the heartbeat, falling back to Worker.lock_timeout' do
      expect { described_class.validate!({:lock_heartbeat_interval => 200}, cli) }.
        to raise_error(ArgumentError, '--lock-timeout must be at least twice --lock-heartbeat') # Default 300.
      Delayed::Worker.lock_timeout = 60
      expect { described_class.validate!({:lock_heartbeat_interval => 45}, cli) }.to raise_error(ArgumentError, /at least twice/)
      expect { described_class.validate!({:lock_heartbeat_interval => 30}, cli) }.not_to raise_error
    end

    {
      {:processes => 2, :identifier => '1'} => 'Cannot specify both --processes and --identifier',
      {:identifier => '1', :pools => [[[], 2]]} => 'Cannot specify both --identifier and --pool',
      {:processes => 2, :pools => [[[], 2]]} => 'Cannot specify both --processes and --pool',
      {:queues => %w[a], :pools => [[[], 2]]} => 'Cannot specify both --queues and --pool',
      {:min_priority => 3, :max_priority => 1} => '--min-priority must be less than or equal to --max-priority'
    }.each do |options, message|
      it "rejects #{options.keys.join(' with ')}" do
        expect { described_class.validate!(options, cli) }.to raise_error(ArgumentError, message)
      end
    end

    it 'allows one process with pools or an identifier' do
      expect { described_class.validate!({:processes => 1, :pools => [[[], 2]]}, cli) }.not_to raise_error
      expect { described_class.validate!({:processes => 1, :identifier => '3'}, cli) }.not_to raise_error
    end
  end
end
