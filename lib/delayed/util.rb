module Delayed
  HAS_FORK = ::Process.respond_to?(:fork)
  IS_JRUBY = Object.const_defined?(:JRUBY_VERSION)
  IS_WINDOWS = !!(RUBY_PLATFORM =~ /mswin|ming|cygwin/) || IS_JRUBY && RUBY_DESCRIPTION.include?('mswin')

  def self.forkable?
    HAS_FORK
  end

  def self.jruby?
    IS_JRUBY
  end

  def self.windows?
    IS_WINDOWS
  end

  def self.program_name
    File.basename($PROGRAM_NAME)
  end

  def self.root
    defined?(::Rails.root) ? ::Rails.root : Pathname.new(Dir.pwd)
  end

  def self.set_thread_name(name)
    return unless Thread.current.respond_to?(:name=)
    Thread.current.name = "delayed_job #{name}"
  end

  # An instance method on Thread has been provided to address https://bugs.ruby-lang.org/issues/13632,
  # which currently effects some older versions of Ruby: 2.2.7 2.2.8 2.2.9 2.2.10 2.3.4 2.4.1
  # Additional context: https://github.com/puma/puma/pull/1345
  def self.purge_interrupt_queue
    return unless Thread.current.respond_to?(:purge_interrupt_queue)
    Thread.current.purge_interrupt_queue
  end

  # Perform garbage collection compaction before fork.
  def self.nakayoshi_gc(logger)
    logger.info '! Promoting existing objects to old generation...'
    4.times { GC.start(full_mark: false) }
    if GC.respond_to?(:compact)
      logger.info '! Compacting...'
      GC.compact
    end
    logger.info '! Friendly fork preparation complete.'
  end
end
