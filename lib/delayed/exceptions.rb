module Delayed
  FatalBackendError = Class.new(Exception)
  InvalidCallback = Class.new(Exception)
  DeserializationError = Class.new(StandardError)
end
