require 'helper'
require 'rake'

describe 'Rake tasks' do
  let(:env) { {} }

  before do
    stub_const('ENV', env)
    Rake.application = Rake::Application.new
    Rake.application.rake_require('delayed/tasks', $LOAD_PATH, [])
    Rake::Task.define_task(:environment)
  end

  describe 'jobs:clear' do
    it do
      expect(Delayed::Job).to receive(:delete_all)
      Rake.application.invoke_task 'jobs:clear'
    end
  end

  shared_examples_for 'work task' do
    let(:expect_success) do
      expect(Delayed::Launcher::Forking).to receive(:new).with(default_args.merge(exp_args)).and_call_original
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:run)
    end

    context 'default case' do
      let(:exp_args) { {:quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'MIN_PRIORITY=-2' do
      let(:env) { {'MIN_PRIORITY' => '-2'} }
      let(:exp_args) { {:min_priority => -2, :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'MIN_PRIORITY not a number' do
      let(:env) { {'MIN_PRIORITY' => 'foo'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'MAX_PRIORITY=-5' do
      let(:env) { {'MAX_PRIORITY' => '-5'} }
      let(:exp_args) { {:max_priority => -5, :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'MAX_PRIORITY not a number' do
      let(:env) { {'MAX_PRIORITY' => 'foo'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'NUM_WORKERS=5' do
      let(:env) { {'NUM_WORKERS' => '5'} }
      let(:exp_args) { {:quiet => false, :worker_count => 5} }
      it do
        expect_success
        run_task
      end
    end

    context 'NUM_WORKERS not a number' do
      let(:env) { {'NUM_WORKERS' => 'foo'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'SLEEP_DELAY=5' do
      let(:env) { {'SLEEP_DELAY' => '5'} }
      let(:exp_args) { {:quiet => false, :sleep_delay => 5, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'SLEEP_DELAY not a number' do
      let(:env) { {'SLEEP_DELAY' => 'foo'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'READ_AHEAD=5' do
      let(:env) { {'READ_AHEAD' => '5'} }
      let(:exp_args) { {:quiet => false, :read_ahead => 5, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'READ_AHEAD not a number' do
      let(:env) { {'READ_AHEAD' => 'foo'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'QUIET=foo' do
      let(:env) { {'QUIET' => 'foo'} }
      let(:exp_args) { {:quiet => true, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'QUIET=0' do
      let(:env) { {'QUIET' => '0'} }
      let(:exp_args) { {:quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'QUIET=f' do
      let(:env) { {'QUIET' => 'f'} }
      let(:exp_args) { {:quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'QUIET=FaLsE' do
      let(:env) { {'QUIET' => 'FaLsE'} }
      let(:exp_args) { {:quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'QUEUE=mailers' do
      let(:env) { {'QUEUE' => 'mailers'} }
      let(:exp_args) { {:queues => %w[mailers], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'QUEUE=mailers,tweets,payments' do
      let(:env) { {'QUEUE' => 'mailers,tweets,payments'} }
      let(:exp_args) { {:queues => %w[mailers tweets payments], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'QUEUES=mailers' do
      let(:env) { {'QUEUES' => 'mailers'} }
      let(:exp_args) { {:queues => %w[mailers], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'QUEUES=mailers,tweets,payments' do
      let(:env) { {'QUEUES' => 'mailers,tweets,payments'} }
      let(:exp_args) { {:queues => %w[mailers tweets payments], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'POOL=*:1' do
      let(:env) { {'POOL' => '*:1'} }
      let(:exp_args) { {:pools => [[[], 1]], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'POOL=*:1|test_queue:4|mailers,misc:2' do
      let(:env) { {'POOL' => '*:1|test_queue:4|mailers,misc:2'} }
      let(:exp_args) { {:pools => [[[], 1], [%w[test_queue], 4], [%w[mailers misc], 2]], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'POOLS=*:1' do
      let(:env) { {'POOL' => '*:1'} }
      let(:exp_args) { {:pools => [[[], 1]], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'POOLS=*:1|test_queue:4|mailers,misc:2' do
      let(:env) { {'POOL' => '*:1|test_queue:4|mailers,misc:2'} }
      let(:exp_args) { {:pools => [[[], 1], [%w[test_queue], 4], [%w[mailers misc], 2]], :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'NUM_WORKERS=0' do
      let(:env) { {'NUM_WORKERS' => '0'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'MIN_PRIORITY less than MAX_PRIORITY' do
      let(:env) { {'MIN_PRIORITY' => '-5', 'MAX_PRIORITY' => '0'} }
      let(:exp_args) { {:max_priority => 0, :min_priority => -5, :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'MIN_PRIORITY equal to MAX_PRIORITY' do
      let(:env) { {'MIN_PRIORITY' => '-5', 'MAX_PRIORITY' => '-5'} }
      let(:exp_args) { {:max_priority => -5, :min_priority => -5, :quiet => false, :worker_count => 1} }
      it do
        expect_success
        run_task
      end
    end

    context 'MIN_PRIORITY greater than MAX_PRIORITY' do
      let(:env) { {'MIN_PRIORITY' => '5', 'MAX_PRIORITY' => '0'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'NUM_WORKERS and POOLS' do
      let(:env) { {'NUM_WORKERS' => '5', 'POOLS' => 'mailers:2'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end

    context 'QUEUES and POOLS' do
      let(:env) { {'QUEUES' => 'mailers', 'POOLS' => 'mailers:2'} }
      it { expect { run_task }.to raise_error(ArgumentError) }
    end
  end

  describe 'jobs:work task' do
    let(:run_task) { Rake.application.invoke_task 'jobs:work' }
    let(:default_args) { {} }

    it_behaves_like 'work task'
  end

  describe 'jobs:workoff' do
    let(:run_task) { Rake.application.invoke_task 'jobs:workoff' }
    let(:default_args) { {:exit_on_complete => true} }

    it_behaves_like 'work task'
  end
end
