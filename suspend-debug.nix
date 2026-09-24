{ ... }:

# Instrumentation for diagnosing a hung resume. Diagnostic only -- this module
# changes no suspend behavior, it only makes the next failure legible.
#
# Background: on 2026-09-23 the machine entered S3 and never came back. The
# fans went to full and the power LED kept pulsing the S3 pattern, meaning
# firmware still believed it was suspended while the CPU was running -- a hang
# in the resume path before the console was restored.
#
# The journal proved *that* it hung but not *where*:
#
#   PM: suspend entry  x3
#   PM: suspend exit   x2        <- one entry never paired with an exit
#
# The last line ever written was "PM: suspend entry (deep)". /sys/fs/pstore was
# empty, so there was no panic or oops -- consistent with a hard hang rather
# than a crash, and offering no stack trace to read.
#
# The missing fact is which device failed to resume. These two kernel
# parameters supply exactly that, and nothing else.

{
  boot.kernelParams = [
    # Make the PM core log every device as it suspends and resumes, with
    # timings. On a hang, the last device logged is the one that wedged. This
    # is the parameter that turns "it hung somewhere in resume" into a name.
    #
    # Equivalent to writing 1 to /sys/power/pm_debug_messages, but set from
    # boot so it is already active for an unplanned suspend.
    "pm_debug_messages"

    # Keep the console alive through suspend and resume instead of suspending
    # it early. Without this, console output stops before the interesting part
    # and the final messages are never flushed to disk -- which is why the
    # previous hang left nothing after "suspend entry".
    #
    # Costs a little suspend latency and is not something to leave on forever,
    # but it is the difference between a diagnosable hang and a silent one.
    "no_console_suspend"
  ];

  # Raise the kernel console log level so the PM messages above actually reach
  # the console and journal rather than being filtered. Default here was
  # loglevel=4 (KERN_WARNING); 7 (KERN_DEBUG) is needed for pm_debug_messages
  # to be visible.
  boot.consoleLogLevel = 7;

  # journald is already Storage=persistent on this machine, so logs survive the
  # hard reset needed to recover from a hang. Stated explicitly so the
  # diagnostic does not silently depend on a default staying put.
  services.journald.storage = "persistent";
}
