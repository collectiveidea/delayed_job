require 'helper'
require 'delayed/command'

describe Delayed::Command do
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

  describe 'running worker pools defined by multiple --pool arguments' do
    it 'should run the correct worker processes' do
      command = Delayed::Command.new(['--pool=*:1', '--pool=test_queue:4', '--pool=mailers,misc:2'])

      expect(Dir).to receive(:mkdir).with('./tmp/pids').once

      [
        ['delayed_job.0', {quiet: true, pid_dir: './tmp/pids', queues: []}],
        ['delayed_job.1', {quiet: true, pid_dir: './tmp/pids', queues: ['test_queue']}],
        ['delayed_job.2', {quiet: true, pid_dir: './tmp/pids', queues: ['test_queue']}],
        ['delayed_job.3', {quiet: true, pid_dir: './tmp/pids', queues: ['test_queue']}],
        ['delayed_job.4', {quiet: true, pid_dir: './tmp/pids', queues: ['test_queue']}],
        ['delayed_job.5', {quiet: true, pid_dir: './tmp/pids', queues: %w[mailers misc]}],
        ['delayed_job.6', {quiet: true, pid_dir: './tmp/pids', queues: %w[mailers misc]}]
      ].each do |args|
        expect(command).to receive(:run_process).with(*args).once
      end

      command.daemonize
    end
  end
end
