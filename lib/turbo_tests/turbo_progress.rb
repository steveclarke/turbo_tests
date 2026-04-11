# frozen_string_literal: true

require "rspec/core"
RSpec::Support.require_rspec_core "formatters/base_text_formatter"

module TurboTests
  # Live parallel test progress formatter for turbo_tests.
  #
  # Progress display writes to stderr (isolated from subprocess stdout).
  # Final results (dump_summary etc.) write to stdout via the standard
  # RSpec output. This avoids the race condition where subprocess threads
  # print to stdout concurrently with ANSI cursor movements.
  class TurboProgress < RSpec::Core::Formatters::BaseTextFormatter
    BAR_WIDTH = 20
    FILLED = "\u2588"
    EMPTY = "\u2591"
    SEPARATOR = "\u2500"

    GREEN = "\e[32m"
    RED = "\e[31m"
    BOLD = "\e[1m"
    DIM = "\e[2m"
    RESET = "\e[0m"

    THROTTLE_INTERVAL = 0.15

    RSpec::Core::Formatters.register self,
      :start,
      :turbo_start,
      :dump_failures,
      :dump_pending,
      :dump_summary,
      :close,
      :turbo_example_passed,
      :turbo_example_failed,
      :turbo_example_pending,
      :turbo_all_workers_finished

    def initialize(output)
      super
      @tty = $stderr
      @workers = {}
      @expected_total = 0
      @total_done = 0
      @total_failures = 0
      @total_pending = 0
      @start_time = nil
      @last_redraw = 0
      @lines_drawn = 0
      @started = false
      @finished = false
    end

    # --- Lifecycle events ---

    def start(notification)
      @start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @expected_total = notification.count
      @started = true
    end

    def turbo_start(example_groups, per_worker_counts = {})
      return unless example_groups

      example_groups.each_with_index do |_files, index|
        process_id = index + 1
        @workers[process_id] = {
          expected: per_worker_counts[process_id] || 0,
          done: 0,
          failures: 0
        }
      end
    end

    def turbo_all_workers_finished
      @finished = true
      # Flush stdout so any buffered subprocess output (e.g. "Run options")
      # is written before we measure cursor position.
      $stdout.flush
      # Over-clear generously — subprocess stdout writes shift the cursor
      # unpredictably, so clear well beyond @lines_drawn. \e[1A at the top
      # of the screen is harmless (cursor stays at line 1).
      n = @lines_drawn + 20
      n.times { @tty.print "\e[1A\e[2K" }
      @tty.flush
      @lines_drawn = 0
      print_final_state
    end

    def close(_notification)
      clear_progress
    end

    # --- Example events ---

    def turbo_example_passed(process_id, _notification)
      count_example(process_id)
      throttled_redraw
    end

    def turbo_example_pending(process_id, _notification)
      count_example(process_id)
      @total_pending += 1
      throttled_redraw
    end

    def turbo_example_failed(process_id, _notification)
      count_example(process_id)
      @total_failures += 1
      @workers[process_id][:failures] += 1
      throttled_redraw
    end

    # --- Dump phase (standard RSpec events) ---

    def dump_failures(notification)
      clear_progress
      super
    end

    def dump_pending(notification)
      clear_progress
      super
    end

    def dump_summary(notification)
      clear_progress
      output.puts notification.fully_formatted
    end

    private

    def print_final_state
      @workers.keys.sort.each do |pid|
        output.puts render_worker_line(pid, @workers[pid], finished: true)
      end
      output.puts "#{DIM}#{SEPARATOR * 40}#{RESET}"
      output.puts render_summary_line
      output.puts
    end

    def ensure_worker(process_id)
      return if process_id.nil?

      @workers[process_id] ||= {
        expected: 0,
        done: 0,
        failures: 0
      }
    end

    def count_example(process_id)
      ensure_worker(process_id)
      @workers[process_id][:done] += 1
      @total_done += 1
    end

    def throttled_redraw
      return if @finished

      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if (now - @last_redraw) < THROTTLE_INTERVAL

      @last_redraw = now
      redraw
    end

    def redraw
      return unless @started
      return if @finished

      clear_progress

      lines = []

      @workers.keys.sort.each do |pid|
        lines << render_worker_line(pid, @workers[pid])
      end

      lines << "#{DIM}#{SEPARATOR * 40}#{RESET}"
      lines << render_summary_line

      lines.each { |line| @tty.puts line }
      @lines_drawn = lines.size
    end

    def clear_progress
      return if @lines_drawn == 0

      @lines_drawn.times { @tty.print "\e[1A\e[2K" }
      @tty.flush

      @lines_drawn = 0
    end

    def render_worker_line(process_id, worker, finished: false)
      expected = worker[:expected]
      done = worker[:done]
      failures = worker[:failures]

      label = if finished || (expected > 0 && done >= expected)
        "#{GREEN}\u2714#{RESET} "
      else
        "W#{process_id}"
      end

      pct = if finished
        1.0
      elsif expected > 0
        done.to_f / expected
      else
        0.0
      end
      filled = [(pct * BAR_WIDTH).round, BAR_WIDTH].min
      empty = BAR_WIDTH - filled
      bar = "#{GREEN}#{FILLED * filled}#{RESET}#{DIM}#{EMPTY * empty}#{RESET}"

      if finished
        count = format_number(done)
      else
        expected_str = format_number(expected)
        count = "#{format_number(done).rjust(expected_str.length)}/#{expected_str}"
      end

      fail_str = if failures > 0
        "  #{RED}#{failures} #{(failures == 1) ? "failure" : "failures"}#{RESET}"
      else
        ""
      end

      "  #{label} #{bar} #{count}#{fail_str}"
    end

    def render_summary_line
      parts = if @finished
        ["#{BOLD}#{format_number(@expected_total)}#{RESET} examples"]
      else
        ["#{BOLD}#{format_number(@total_done)}#{RESET}/#{format_number(@expected_total)} examples"]
      end

      if @total_failures > 0
        parts << "#{RED}#{@total_failures} failures#{RESET}"
      end

      if @total_pending > 0
        parts << "#{DIM}#{@total_pending} pending#{RESET}"
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start_time

      eta = ""
      if !@finished && @total_done > 0 && @total_done < @expected_total
        remaining = elapsed * (@expected_total - @total_done).to_f / @total_done
        eta = " | ETA #{format_duration(remaining)}"
      end

      "  #{parts.join(", ")} | #{format_duration(elapsed)}#{eta}"
    end

    def format_number(n)
      n.to_s.gsub(/(\d)(?=(\d{3})+$)/, '\1,')
    end

    def format_duration(seconds)
      seconds = seconds.round
      if seconds >= 60
        "#{seconds / 60}m#{seconds % 60}s"
      else
        "#{seconds}s"
      end
    end
  end
end
