#include <ruby.h>
#ifdef HAVE_SYS_PRCTL_H
#include <sys/prctl.h>
#endif

/*
 * Delayed::ProcessUtil.native_enable_child_subreaper -> true or false
 *
 * Makes this process a child subreaper (Linux 3.4+): orphaned descendants
 * are reparented to it instead of init, so it can wait for them. False
 * where prctl(PR_SET_CHILD_SUBREAPER) is unavailable or fails.
 */
static VALUE native_enable_child_subreaper(VALUE self) {
#if defined(HAVE_SYS_PRCTL_H) && defined(PR_SET_CHILD_SUBREAPER)
  return prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0 ? Qtrue : Qfalse;
#else
  return Qfalse;
#endif
}

void Init_subreaper(void) {
  VALUE delayed = rb_define_module("Delayed");
  VALUE process_util = rb_define_module_under(delayed, "ProcessUtil");
  rb_define_singleton_method(process_util, "native_enable_child_subreaper", native_enable_child_subreaper, 0);
}
