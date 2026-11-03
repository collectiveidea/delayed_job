# These extensions allow properly serializing and autoloading of
# Classes, Modules and Structs

require 'yaml'
if YAML.parser.class.name =~ /syck|yecht/i
  require File.expand_path('syck_ext', __dir__)
  require File.expand_path('serialization/active_record', __dir__)
else
  require File.expand_path('psych_ext', __dir__)
end
