# Runs a Delayed::Launcher::Forking on an SQLite file database.
# Usage: ruby -Ilib spec/processes/launch.rb DB_PATH OPTIONS_JSON
# OPTIONS_JSON holds the launcher options, plus "worker" settings applied to
# Delayed::Worker (e.g. {"sleep_delay": 0.1}). Logs go to STDOUT.
require 'bundler/setup'
require 'json'
require 'logger'
require_relative 'backend'
require_relative 'jobs'

db_path, json = ARGV
options = JSON.parse(json || '{}', :symbolize_names => true)
worker_settings = options.delete(:worker) || {}
# Seconds each forked worker process sleeps in after_fork, before it installs
# its own signal traps: lets specs signal it during start-up.
startup_delay = options.delete(:startup_delay)
# Attaches Delayed::LogSubscriber, so specs can check the events.
log_events = options.delete(:log_events)
# The first N forked worker processes crash (exit 3) as they start up.
crash_on_start = options.delete(:crash_on_start)
# Worker processes working this queue crash (exit 3) whenever they start.
crash_queue = options.delete(:crash_queue)
# Seconds each forked child process waits before replacing the launcher's
# (inherited) signal traps: lets specs signal it in that window.
capture_delay = options.delete(:capture_delay)
# The first respawn delay of a crash loop (see Launcher::Forking).
respawn_delay_unit = options.delete(:respawn_delay_unit)
Delayed::Launcher::Forking.respawn_delay_unit = respawn_delay_unit if respawn_delay_unit
# Seconds between child pings in mold mode (see Launcher::Mold).
mold_ping_interval = options.delete(:mold_ping_interval)
Delayed::Launcher::Forking.mold_ping_interval = mold_ping_interval if mold_ping_interval
# Mold timings (see Launcher::MoldSupervisor), lowered by specs.
{:mold_retry_delay_unit => :retry_delay_unit, :mold_boot_timeout => :boot_timeout,
 :mold_drain_deadline => :drain_deadline}.each do |option, setting|
  value = options.delete(option)
  Delayed::Launcher::MoldSupervisor.send("#{setting}=", value) if value
end
# Runs the mold process as without a child subreaper (not Linux, no fiddle).
Delayed::ProcessUtil.define_singleton_method(:enable_child_subreaper) { false } if options.delete(:no_subreaper)
# Child processes forked by a mold crash (exit 3) as they start.
broken_mold = options.delete(:broken_mold)
# Seconds a mold sleeps in a before(:mold) hook, before it is ready.
mold_hook_delay = options.delete(:mold_hook_delay)
# Each mold logs "before(:mold) <pid> <generation>" and "after(:mold) ...".
log_mold_hooks = options.delete(:log_mold_hooks)
# Recovering a dead child's jobs hangs in the launcher (a hung database
# call), so specs can reach the kill timer's exit_stuck backstop.
hang_recovery = options.delete(:hang_recovery)
# The launcher's forks with these numbers (1-based, every attempt counted)
# fail with EAGAIN; "fail_forks_from" fails every one from that number on.
fail_forks = options.delete(:fail_forks) || []
fail_forks_from = options.delete(:fail_forks_from)

Delayed::Backend::SqliteFile::Job.connect(db_path)
Delayed::Worker.backend = Delayed::Backend::SqliteFile::Job
STDOUT.sync = true
Delayed::Worker.logger = Logger.new(STDOUT).tap { |l| l.formatter = proc { |_s, _t, _p, m| "#{m}\n" } }
worker_settings.each { |setting, value| Delayed::Worker.send("#{setting}=", value) }
Delayed::LogSubscriber.attach_to :delayed_job if log_events

if startup_delay
  Delayed::Backend::SqliteFile::Job.singleton_class.prepend(Module.new do
    define_method(:after_fork) do
      puts "worker #{Process.pid} starting up"
      sleep startup_delay
      super()
    end
  end)
end

if crash_on_start
  starts = "#{db_path}.starts"
  Delayed::Backend::SqliteFile::Job.singleton_class.prepend(Module.new do
    define_method(:after_fork) do
      File.open(starts, 'a') { |f| f.puts Process.pid }
      exit!(3) if File.readlines(starts).size <= crash_on_start
      super()
    end
  end)
end

if capture_delay
  Delayed::Launcher::Forking.prepend(Module.new do
    define_method(:capture_signals) do
      puts "child #{Process.pid} capturing signals in #{capture_delay}s"
      sleep capture_delay
      super()
    end
  end)
end

if crash_queue
  Delayed::Dispatcher.prepend(Module.new do
    define_method(:run) do
      exit!(3) if Delayed::Worker.queues.include?(crash_queue)
      super()
    end
  end)
end

if broken_mold
  Delayed::Backend::SqliteFile::Job.singleton_class.prepend(Module.new do
    define_method(:after_fork) do
      exit!(3) if $0.include?(' gen ')
      super()
    end
  end)
end

if mold_hook_delay
  Delayed::Worker.plugins << Class.new(Delayed::Plugin) do
    callbacks do |lifecycle|
      lifecycle.before(:mold) do |pid, _generation|
        puts "mold #{pid} hook sleeping"
        sleep mold_hook_delay
      end
    end
  end
end

if log_mold_hooks
  Delayed::Worker.plugins << Class.new(Delayed::Plugin) do
    callbacks do |lifecycle|
      lifecycle.before(:mold) { |pid, generation| puts "before(:mold) #{pid} #{generation}" }
      lifecycle.after(:mold) { |pid, generation| puts "after(:mold) #{pid} #{generation}" }
    end
  end
end

if hang_recovery
  launcher_pid = Process.pid
  hang = proc do
    next unless Process.pid == launcher_pid
    puts 'recovery hanging'
    sleep
  end
  Delayed::Worker.singleton_class.prepend(Module.new do
    define_method(:recover_jobs_of) { |*args| hang.call || super(*args) }
  end)
  Delayed::Backend::SqliteFile::Job.singleton_class.prepend(Module.new do
    define_method(:clear_locks!) { |*args| hang.call || super(*args) }
  end)
end

if fail_forks.any? || fail_forks_from
  forks = 0
  Delayed::Launcher::Forking.prepend(Module.new do
    define_method(:fork_worker) do |*args|
      forks += 1
      if fail_forks.include?(forks) || (fail_forks_from && forks >= fail_forks_from)
        puts "fork #{forks} failing"
        raise Errno::EAGAIN, 'fork'
      end
      super(*args)
    end
  end)
end

options[:pools] = options[:pools].map { |queues, count| [queues, count] } if options[:pools]
Delayed::Launcher::Forking.new(options.merge(:quiet => true)).launch
