# Stubs Delayed Job's logging (#say) on dispatchers and workers, in specs.
module LogHelper
  # Collects what each speaker (a dispatcher or worker) says into `into`,
  # as [level, text]. `into` should be a Concurrent::Array: worker threads
  # append to it.
  def capture_say(into, *speakers)
    speakers.each { |speaker| allow(speaker).to receive(:say) { |text, level = 'info'| into << [level, text] } }
    into
  end

  # Keeps the speakers quiet.
  def silence_say(*speakers)
    speakers.each { |speaker| allow(speaker).to receive(:say) }
  end

  # The dispatcher and its workers: everyone that says something while it runs.
  def and_workers(dispatcher)
    [dispatcher, *dispatcher.workers]
  end
end
