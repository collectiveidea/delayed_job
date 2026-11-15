require_relative '../../helper'
require_relative 'shared_examples'
require 'tmpdir'

describe Delayed::Launcher::Forking do
  let(:options) { {} }
  subject { described_class.new(options) }

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

  describe '#launch' do
    before do
      allow(Delayed::Worker).to receive(:before_fork)
      allow_any_instance_of(described_class).to receive(:prepare_for_fork)
    end

    shared_examples 'a forking parent' do
      it 'prepares for forking, then supervises the forked workers' do
        expect(subject).to receive(:prepare_for_fork).ordered
        expect(Delayed::Worker).to receive(:before_fork).ordered
        expect(subject).to receive(:fork_worker).at_least(:once).ordered
        expect(subject).to receive(:run_loop).ordered
        subject.launch
      end
    end

    shared_examples 'a single worker process' do
      it 'runs the worker in this process without forking' do
        expect(subject).not_to receive(:prepare_for_fork)
        expect(Delayed::Worker).not_to receive(:before_fork)
        expect(subject).not_to receive(:fork_worker)
        expect(subject).not_to receive(:run_loop)
        subject.launch
      end
    end

    context 'with multiple workers' do
      let(:options) { {:processes => 2} }
      it_behaves_like 'a forking parent'
    end

    # Regression: pools with the default worker count (1) used to fork
    # without Worker.before_fork (crashing the children in after_fork) and
    # without supervising them (the parent exited immediately).
    context 'with pools and the default worker count' do
      let(:options) { {:pools => [[['mailers'], 2]]} }
      it_behaves_like 'a forking parent'
    end

    context 'with a single pool of one worker' do
      let(:options) { {:pools => [[[], 1]]} }
      it_behaves_like 'a forking parent'
    end

    context 'with a single worker' do
      let(:options) { {} }
      it_behaves_like 'a single worker process'
    end

    context 'with an identifier and multiple workers' do
      let(:options) { {:identifier => 'abc', :processes => 2} }
      it_behaves_like 'a single worker process'
    end
  end

  describe 'the pidfile' do
    around do |example|
      Dir.mktmpdir('dj-launcher') do |dir|
        @dir = dir
        example.run
      end
    end

    let(:path) { File.join(@dir, 'run', 'dj.pid') }

    describe '#pid_file' do
      it 'is nil by default' do
        expect(subject.pid_file).to be_nil
      end

      context 'with a path' do
        let(:options) { {:pid_file => path} }
        it { expect(subject.pid_file).to eq path }
      end

      context 'with a Pathname' do
        let(:options) { {:pid_file => Pathname.new(path)} }
        it { expect(subject.pid_file).to eq path }
      end

      context 'with true' do
        let(:options) { {:pid_file => true, :pid_dir => @dir} }
        it 'is named after the process in pid_dir' do
          expect(subject.pid_file).to eq File.join(@dir, 'delayed_job.pid')
        end
      end

      context 'with true and an identifier' do
        let(:options) { {:pid_file => true, :pid_dir => @dir, :identifier => 'x'} }
        it { expect(subject.pid_file).to eq File.join(@dir, 'delayed_job.x.pid') }
      end

      context 'with true and the default pid_dir' do
        let(:options) { {:pid_file => true} }
        it { expect(subject.pid_file).to eq "#{Delayed.root}/tmp/pids/delayed_job.pid" }
      end

      it 'is not passed on to the workers' do
        launcher = described_class.new(:pid_file => path)
        expect(launcher.instance_variable_get(:@options)).not_to have_key(:pid_file)
      end
    end

    describe '#launch' do
      let(:options) { {:pid_file => path} }

      it 'holds the pidfile while it runs, and deletes it when done' do
        held = nil
        allow(subject).to receive(:setup_workers) { held = File.read(path) }
        subject.launch
        expect(held).to eq "#{Process.pid}\n"
        expect(File.exist?(path)).to be false
      end

      it 'writes the pidfile before trapping signals or starting workers' do
        expect(Delayed::Pidfile).to receive(:new).with(path).ordered.and_call_original
        expect(subject).to receive(:trap_signals).ordered
        expect(subject).to receive(:setup_workers).ordered
        subject.launch
      end

      it 'deletes the pidfile when it fails' do
        allow(subject).to receive(:setup_workers).and_raise('boom')
        expect { subject.launch }.to raise_error('boom')
        expect(File.exist?(path)).to be false
      end

      it 'deletes the pidfile when it exits' do
        allow(subject).to receive(:setup_workers) { exit(1) }
        expect { subject.launch }.to raise_error(SystemExit)
        expect(File.exist?(path)).to be false
      end

      it 'logs the pidfile' do
        logger = Logger.new(io = StringIO.new)
        allow(Delayed::Worker).to receive(:logger).and_return(logger)
        subject.launch
        expect(io.string).to include "Wrote pidfile #{path} - pid #{Process.pid}"
      end

      context 'when another launcher holds the pidfile' do
        let!(:other) { Delayed::Pidfile.new(path).setup }
        after { other.delete }

        it 'raises AlreadyRunningError without starting workers or trapping signals' do
          expect(subject).not_to receive(:trap_signals)
          expect(subject).not_to receive(:setup_workers)
          expect { subject.launch }.to raise_error(Delayed::AlreadyRunningError, /pid #{Process.pid}/)
        end

        it "leaves the other launcher's pidfile" do
          expect { subject.launch }.to raise_error(Delayed::AlreadyRunningError)
          expect(File.read(path)).to eq "#{Process.pid}\n"
        end
      end

      it 'writes no pidfile by default' do
        launcher = described_class.new(:pid_dir => @dir)
        expect(Delayed::Pidfile).not_to receive(:new)
        launcher.launch
        expect(Dir.children(@dir)).to be_empty
      end
    end
  end

  describe '#prepare_for_fork' do
    let(:config) { double('config', :cache_classes => true) }
    let(:application) { double('application', :config => config) }

    before { allow(subject).to receive(:warmup_heap) }

    it 'eager loads the Rails application' do
      stub_const('Rails', double('Rails', :application => application))
      expect(application).to receive(:eager_load!)
      subject.send(:prepare_for_fork)
    end

    it 'does not eager load when code reloading is enabled' do
      allow(config).to receive(:cache_classes).and_return(false)
      stub_const('Rails', double('Rails', :application => application))
      expect(application).not_to receive(:eager_load!)
      subject.send(:prepare_for_fork)
    end

    it 'skips eager loading without a Rails application' do
      stub_const('Rails', double('Rails', :application => nil))
      expect { subject.send(:prepare_for_fork) }.not_to raise_error
    end

    it 'warms up the heap' do
      stub_const('Rails', double('Rails', :application => nil))
      expect(subject).to receive(:warmup_heap)
      subject.send(:prepare_for_fork)
    end
  end

  describe '#warmup_heap' do
    it 'uses Process.warmup when available' do
      skip 'Process.warmup requires Ruby 3.3' unless Process.respond_to?(:warmup)
      expect(Process).to receive(:warmup)
      expect(GC).not_to receive(:start)
      subject.send(:warmup_heap)
    end

    it 'falls back to a full GC and compaction' do
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:warmup).and_return(false)
      expect(GC).to receive(:start)
      expect(GC).to receive(:compact) if GC.respond_to?(:compact)
      subject.send(:warmup_heap)
    end

    it 'tolerates platforms without compaction' do
      allow(Process).to receive(:respond_to?).and_call_original
      allow(Process).to receive(:respond_to?).with(:warmup).and_return(false)
      allow(GC).to receive(:start)
      allow(GC).to receive(:respond_to?).and_call_original
      allow(GC).to receive(:respond_to?).with(:compact).and_return(true)
      allow(GC).to receive(:compact).and_raise(NotImplementedError)
      expect { subject.send(:warmup_heap) }.not_to raise_error
    end
  end
end
