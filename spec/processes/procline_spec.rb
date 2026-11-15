require 'helper'
require_relative 'helpers'

# The titles of real forked worker processes, as ps shows them.
describe 'The process titles of forked worker processes', :processes do
  include ProcessHelpers

  before { skip 'needs /proc' unless File.exist?("/proc/#{Process.pid}/cmdline") }

  def title(pid)
    File.read("/proc/#{pid}/cmdline").split("\0").join(' ').strip
  rescue Errno::ENOENT
    nil
  end

  def worker_pids(output)
    output.scan(/Child process (delayed_job\.\d) \(pid (\d+)\) started/).to_h { |name, pid| [name, pid.to_i] }
  end

  it 'shows each worker, its busy threads and its queues, live' do
    job = enqueue_process_job(ProcessJobs::SleepJob.new('busy', 2), :queue => 'mail')
    # The second pool doesn't work the mail queue, so only the first can run
    # the job (a '*' pool could take it; queues=* is covered by procline_spec).
    pid, reader = spawn_launcher(:pools => [[['mail'], 1], [%w[sms push], 1]], :threads => 2,
                                 :worker => {:sleep_delay => 0.1})
    output = +''
    pids = wait_for do
      output << read_available(reader)
      found = worker_pids(output)
      found.size == 2 && found
    end
    mail = pids['delayed_job.0']
    all = pids['delayed_job.1']

    wait_for { reload_job(job).locked_by }
    expect(wait_for { (t = title(mail)) == 'delayed_job.0: 1/2 busy, queues=mail' && t }).to be_truthy
    expect(wait_for { (t = title(all)) == 'delayed_job.1: 0/2 busy, queues=sms,push' && t }).to be_truthy

    # Stopping while the mail worker's job still runs.
    Process.kill('TERM', pid)
    expect(wait_for { title(mail) == 'delayed_job.0: stopping, 1/2 busy, queues=mail' }).to be true
    status, = wait_for_launcher(pid, reader)
    expect(status).to be_success
  end
end
