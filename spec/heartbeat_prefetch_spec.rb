require 'helper'
require_relative 'processes/helpers'

# The dispatcher examples (threads, prefetch, shutdown, lock heartbeats with
# prefetch) against a database backend that supports lock heartbeats.
describe Delayed::Backend::SqliteFile::Job, :processes do
  include ProcessHelpers

  around do |example|
    Delayed::Worker.backend = described_class
    example.run
  ensure
    Delayed::Worker.backend = :test
  end

  it_behaves_like 'a delayed_job backend running a dispatcher'
end
