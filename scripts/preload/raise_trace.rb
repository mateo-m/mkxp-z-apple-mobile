# raise_trace.rb
#
# Keep a small ring buffer of recent Ruby exception raises. The
# engine drains the buffer into the debug log when script execution
# ends (binding-mri.cpp, RAISETRACE tag).
#
# Why: many fangame loaders eval loose script files inside a rescue
# block that drops the error (Bushido-style repacks comment out the
# re-raise). The session then ends "cleanly" and the log holds no
# evidence. The buffer preserves the last raises, so a masked boot
# error becomes visible without a per-game patch file.
#
# The bootstrap loads this file only when the host has debug logs
# enabled, so normal play pays no cost.
#
# This file only stores and formats. The engine installs a C
# RUBY_EVENT_RAISE hook (binding/script-bootstrap.cpp) that calls
# record_exception for every raise. That hook is the mechanism
# behind TracePoint(:raise) and exists on Ruby 1.8, 1.9 and 3.1
# alike, so VM-internal raises (a NoMethodError from a typo) are
# captured on every VM, not just explicit `raise` calls.

unless defined?(MKXPRaiseTrace)
  module MKXPRaiseTrace
    CAP = 25
    FRAMES = 10
    MSG_LIMIT = 300

    @entries = []
    @dropped = 0

    # The recorder runs while a raise is in flight (TracePoint hook
    # or Kernel#raise wrapper). An error that escapes here would
    # replace the game's own exception, so every entry point
    # swallows everything, including non-StandardError.
    # rubocop:disable Lint/RescueException
    class << self
      def record(class_name, message, frames)
        msg = message.to_s
        msg = "#{msg[0, MSG_LIMIT]}..." if msg.length > MSG_LIMIT
        frames = (frames || [])[0, FRAMES]
        sig = "#{class_name}|#{frames[0]}"
        last = @entries[-1]
        if last && last[:sig] == sig
          last[:count] += 1
          return
        end
        if @entries.length >= CAP
          @entries.shift
          @dropped += 1
        end
        @entries.push({ :sig => sig, :head => "#{class_name}: #{msg}",
                        :frames => frames, :count => 1 })
        nil
      rescue Exception
        nil
      end

      def record_exception(exc)
        record(exc.class.to_s, exc.message, exc.backtrace)
      rescue Exception
        nil
      end

      # Format the buffer as log lines and clear it. The engine
      # calls this once when script execution ends. Nil means there
      # is nothing to report.
      def drain
        return nil if @entries.empty?

        lines = []
        suffix = @dropped > 0 ? " (#{@dropped} older dropped)" : ''
        lines.push("last #{@entries.length} raise group(s), newest last#{suffix}")
        @entries.each do |entry|
          head = entry[:head]
          head = "#{head} [x#{entry[:count]}]" if entry[:count] > 1
          lines.push(head)
          entry[:frames].each { |frame| lines.push("  from #{frame}") }
        end
        @entries = []
        @dropped = 0
        lines
      rescue Exception
        nil
      end
    end
    # rubocop:enable Lint/RescueException
  end
end
