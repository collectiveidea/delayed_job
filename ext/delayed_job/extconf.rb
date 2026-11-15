# Delayed::ProcessUtil.native_enable_child_subreaper, for the mold process:
# prctl(PR_SET_CHILD_SUBREAPER) on Linux. Elsewhere it builds as a stub that
# returns false; JRuby, which has no C extensions, builds nothing (the
# require fails and the subreaper is off).
require 'mkmf'

if RUBY_ENGINE == 'jruby'
  File.write('Makefile', dummy_makefile($srcdir).join) # rubocop:disable Style/GlobalVars
else
  have_header('sys/prctl.h')
  create_makefile('delayed/subreaper')
end
