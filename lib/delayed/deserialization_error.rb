module Delayed
  class DeserializationError < StandardError
  end

  class PayloadNotFoundError < DeserializationError
  end
end
