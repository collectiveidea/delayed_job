require 'helper'

# Windows of the forking launcher (no mold) too narrow to hit with real
# processes: a kill or stop landing while a fork is in flight.
describe Delayed::Launcher::Forking, 'races with a fork in flight' do
  subject(:launcher) { described_class.new(options) }
  let(:options) { {:processes => 2} }
  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(Signal).to receive(:trap)
    allow(Process).to receive(:kill)
    allow(Delayed::Worker).to receive(:thread_error)
  end

  after { Delayed::Worker.reset }

  # The kill timer fires between add_worker's stop check and the child being
  # recorded: kill's SIGKILL missed it, so it must be caught up with KILL,
  # not TERM, or it would run on past the kill.
  it 'SIGKILLs a child recorded just after the kill fired' do
    launcher.send(:workers)[11] = ['delayed_job.0', {}]
    allow(launcher).to receive(:fork_worker) do
      launcher.shutdown
      launcher.kill('after 10 second timeout')
      12
    end
    launcher.send(:start_child, {}, {})
    expect(Process).to have_received(:kill).with('KILL', 12)
    expect(Process).not_to have_received(:kill).with('TERM', 12)
  end

  # A stop arrives while a respawn's fork fails: the retry it queued is
  # dropped, not forked once the delay passes.
  it 'drops the retry of a respawn whose fork failed as the launcher was stopped' do
    allow(launcher).to receive(:fork_worker) do
      launcher.send(:stop_from_trap, 'TERM', nil)
      raise Errno::EAGAIN, 'fork'
    end
    launcher.send(:respawn, 'delayed_job.0', 11, {}, nil, 1, 1)
    expect(launcher.send(:pending_replacements).size).to eq 1
    launcher.send(:replace_due_workers)
    expect(launcher.send(:pending_replacements)).to be_empty
    expect(launcher).to have_received(:fork_worker).once
  end

  # A child reaped after the kill isn't replaced, nor reported as killed by
  # someone else, even when its replacement was pending back-off.
  it 'replaces nothing reaped after the kill, dropping a replacement pending its back-off' do
    launcher.send(:workers)[11] = ['delayed_job.0', {}]
    launcher.send(:pending_replacements) << [0, ['delayed_job.1', 12, {}, nil, 1, 1]]
    allow(launcher).to receive(:recover_jobs_of_worker)
    allow(launcher).to receive(:fork_worker)
    launcher.kill('after 10 second timeout')
    status = instance_double(Process::Status, :termsig => 9, :success? => false, :to_s => 'pid 11 SIGKILL (signal 9)')
    launcher.send(:handle_exit, 11, status)
    launcher.send(:replace_due_workers)
    expect(launcher).not_to have_received(:fork_worker)
    expect(launcher.send(:pending_replacements)).to be_empty
    expect(logger).not_to have_received(:warn).with(/OOM killer/)
  end
end

describe Delayed::Launcher::Daemonized, 'guards' do
  it 'refuses a pidfile, which is for --fork mode' do
    expect { described_class.new(:pid_file => '/tmp/dj.pid') }.to raise_error(ArgumentError, /--pid-file is for --fork mode/)
  end
end
