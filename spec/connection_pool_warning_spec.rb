require 'helper'
require_relative 'processes/helpers'

# The warning a dispatcher logs when the Active Record connection pool is
# smaller than the number of threads that may query at once.
describe 'The connection pool size warning' do
  let(:messages) { Concurrent::Array.new }
  let(:pool) { double('connection pool', :size => pool_size) }
  let(:pool_size) { 5 }

  before do
    allow(ActiveRecord::Base).to receive(:connection_pool).and_return(pool)
  end

  after { Delayed::Worker.reset }

  def dispatcher(threads)
    Delayed::Dispatcher.new(:threads => threads).tap { |d| capture_say(messages, d) }
  end

  def warn!(threads)
    dispatcher(threads).send(:warn_if_connection_pool_too_small)
    messages.select { |_, text| text.include?('connection pool') }
  end

  def heartbeats_on
    Delayed::Worker.lock_heartbeat_interval = 10
    Delayed::Worker.lock_timeout = 60
    allow(Delayed::Job).to receive(:lock_heartbeats?).and_return(true)
  end

  context 'without lock heartbeats' do
    it 'is quiet when the pool fits every thread plus the dispatcher' do
      expect(warn!(4)).to be_empty
    end

    it 'warns when the pool is one short' do
      warnings = warn!(5)
      expect(warnings.size).to eq 1
      level, text = warnings.first
      expect(level).to eq 'warn'
      expect(text).to include 'pool size (5) is smaller than the 6 connections'
      expect(text).to include '(5 job thread(s), the dispatcher)'
      expect(text).not_to include 'heartbeat'
    end

    it 'counts the dispatcher for a single thread too' do
      allow(pool).to receive(:size).and_return(1)
      expect(warn!(1).first.last).to include 'smaller than the 2 connections'
    end
  end

  context 'with lock heartbeats' do
    before { heartbeats_on }

    it 'counts the heartbeat thread' do
      expect(warn!(3)).to be_empty # 3 + 1 + 1 = 5
      text = warn!(4).first.last # 4 + 1 + 1 = 6
      expect(text).to include 'pool size (5) is smaller than the 6 connections'
      expect(text).to include '(4 job thread(s), the dispatcher, the lock heartbeat)'
    end

    it 'does not count it when the backend does not support heartbeats' do
      allow(Delayed::Job).to receive(:lock_heartbeats?).and_return(false)
      expect(warn!(4)).to be_empty
    end
  end

  it 'does not count a heartbeat that is off' do
    allow(Delayed::Job).to receive(:lock_heartbeats?).and_return(true)
    expect(Delayed::Worker.lock_heartbeat_interval).to be_nil
    expect(warn!(4)).to be_empty
  end

  it 'is quiet without Active Record' do
    hide_const('ActiveRecord::Base')
    expect(warn!(50)).to be_empty
  end

  it 'is quiet when the pool cannot be inspected' do
    allow(ActiveRecord::Base).to receive(:connection_pool).and_raise(StandardError, 'no database configured')
    expect { warn!(50) }.not_to raise_error
    expect(messages).to be_empty
  end

  it 'is logged once when the dispatcher starts running' do
    heartbeats_on
    allow(Delayed::Job).to receive(:touch_locks).and_return(0)
    d = dispatcher(5)
    Delayed::Worker.exit_on_complete = true
    Timeout.timeout(5) { d.run }
    expect(messages.select { |_, text| text.include?('connection pool') }.size).to eq 1
  end

  context 'with a real Active Record pool' do
    include ProcessHelpers

    around do |example|
      Delayed::Worker.backend = Delayed::Backend::SqliteFile::Job
      example.run
    ensure
      Delayed::Worker.backend = :test
    end

    before { allow(ActiveRecord::Base).to receive(:connection_pool).and_call_original }

    it 'reads the configured pool size' do
      size = ActiveRecord::Base.connection_pool.size
      expect(warn!(size - 1)).to be_empty
      expect(warn!(size).first.last).to include "pool size (#{size}) is smaller than the #{size + 1} connections"
    end
  end
end
