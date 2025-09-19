# frozen_string_literal: true

require "json"
require "parallel_tests/rspec/runner"

require_relative "../utils/hash_extension"

module TurboTests
  class Runner
    using CoreExtensions

    def self.run(opts = {})
      files = opts[:files]
      formatters = opts[:formatters]
      tags = opts[:tags]

      start_time = opts.fetch(:start_time) { RSpec::Core::Time.now }
      runtime_log = opts.fetch(:runtime_log, nil)
      verbose = opts.fetch(:verbose, false)
      fail_fast = opts.fetch(:fail_fast, nil)
      count = opts.fetch(:count, nil)
      seed = opts.fetch(:seed)
      seed_used = !seed.nil?
      sync_log = !!opts.fetch(:sync_log)

      if verbose
        warn "VERBOSE"
        warn "SYNC_LOG" if sync_log
      end

      reporter = Reporter.from_config(formatters, start_time, seed, seed_used)

      new(
        reporter: reporter,
        files: files,
        tags: tags,
        runtime_log: runtime_log,
        verbose: verbose,
        fail_fast: fail_fast,
        count: count,
        seed: seed,
        seed_used: seed_used,
        sync_log: sync_log,
      ).run
    end

    def initialize(opts)
      @reporter = opts[:reporter]
      @files = opts[:files]
      @tags = opts[:tags]
      @runtime_log = opts[:runtime_log] || "tmp/turbo_rspec_runtime.log"
      @verbose = opts[:verbose]
      @fail_fast = opts[:fail_fast]
      @count = opts[:count]
      @seed = opts[:seed]
      @seed_used = opts[:seed_used]
      @sync_log = opts[:sync_log]

      @load_time = 0
      @load_count = 0
      @failure_count = 0

      @messages = Thread::Queue.new
      @threads = []
      @error = false
    end

    def run
      @num_processes = [
        ParallelTests.determine_number_of_processes(@count),
        ParallelTests::RSpec::Runner.tests_with_size(@files, {}).size
      ].min

      use_runtime_info = @files == ["spec"]

      group_opts = {}

      if use_runtime_info
        group_opts[:runtime_log] = @runtime_log
      else
        group_opts[:group_by] = :filesize
      end

      tests_in_groups =
        ParallelTests::RSpec::Runner.tests_in_groups(
          @files,
          @num_processes,
          **group_opts
        )

      subprocess_opts = {
        record_runtime: use_runtime_info,
      }

      @reporter.report(tests_in_groups) do |reporter|
        warn "* #{ts} | Before spawning subprocesses" if @verbose

        if @sync_log
          @wait_thr_statuses = []

          tests_in_groups.each_with_index do |tests, process_id|
            start_regular_subprocess(tests, process_id + 1, **subprocess_opts)
          end

          warn "* #{ts} | Before 'handle_messages'" if @verbose

          handle_messages

          warn "* #{ts} | After 'handle_messages'" if @verbose

          @threads.each(&:join)

          warn "* #{ts} | After threads join" if @verbose

          if @reporter.failed_examples.empty? && @wait_thr_statuses.all? { |s| s == 0 }
            warn "* #{ts} | Fast 0 return" if @verbose
            0
          else
            warn "* #{ts} | Wait threads max" if @verbose

            @wait_thr_statuses.max
          end
        else
          wait_threads = tests_in_groups.map.with_index do |tests, process_id|
            start_regular_subprocess(tests, process_id + 1, **subprocess_opts)
          end

          warn "* #{ts} | Before 'handle_messages'" if @verbose

          handle_messages

          warn "* #{ts} | After 'handle_messages'" if @verbose

          @threads.each(&:join)

          warn "* #{ts} | After threads join" if @verbose

          if @reporter.failed_examples.empty? && wait_threads.map(&:value).all?(&:success?)
            warn "* #{ts} | Fast 0 return" if @verbose
            0
          else
            warn "* #{ts} | Wait threads max" if @verbose

            # From https://github.com/serpapi/turbo_tests/pull/20/
            wait_threads.map { |thread| thread.value.exitstatus }.max
          end
        end
      end
    end

    private

    def start_regular_subprocess(tests, process_id, **opts)
      start_subprocess(
        {"TEST_ENV_NUMBER" => process_id.to_s},
        @tags.map { |tag| "--tag=#{tag}" },
        tests,
        process_id,
        **opts
      )
    end

    def start_subprocess(env, extra_args, tests, process_id, record_runtime:)
      if tests.empty?
        @messages << {
          type: "exit",
          process_id: process_id,
        }
      else
        env["RSPEC_FORMATTER_OUTPUT_ID"] = SecureRandom.uuid
        env["RUBYOPT"] = ["-I#{File.expand_path("..", __dir__)}", ENV["RUBYOPT"]].compact.join(" ")
        env["RSPEC_SILENCE_FILTER_ANNOUNCEMENTS"] = "1"

        if ENV["RSPEC_EXECUTABLE"]
          command_name = ENV["RSPEC_EXECUTABLE"].split
        elsif ENV["BUNDLE_BIN_PATH"]
          command_name = [ENV["BUNDLE_BIN_PATH"], "exec", "rspec"]
        else
          command_name = "rspec"
        end

        record_runtime_options =
          if record_runtime
            [
              "--format", "ParallelTests::RSpec::RuntimeLogger",
              "--out", @runtime_log,
            ]
          else
            []
          end

        seed_option = if @seed_used
          [
            "--seed", @seed,
          ]
        else
          []
        end

        command = [
          *command_name,
          *extra_args,
          *seed_option,
          "--format", "TurboTests::JsonRowsFormatter",
          *record_runtime_options,
          *tests,
        ]

        if @verbose
          command_str = [
            env.map { |k, v| "#{k}=#{v}" }.join(" "),
            command.join(" "),
          ].select { |x| x.size > 0 }.join(" ")

          warn "+ #{ts} | Process #{process_id}: #{command_str}"
        end

        if @sync_log
          # popen3_select(env, command, process_id)
          # popen3_select_reverse(env, command, process_id)
          # capture3(env, command, process_id)
          # capture2e(env, command, process_id)
          # popen2e(env, command, process_id)
          popen2e_sync(env, command, process_id)
        else
          popen3(env, command, process_id)
        end
      end
    end

    def popen3(env, command, process_id)
      warn "* #{ts} | PID: #{process_id} | before popen3" if @verbose

      stdin, stdout, stderr, wait_thr = Open3.popen3(env, *command)

      warn "* #{ts} | PID: #{process_id} | after popen3" if @verbose

      stdin.close

      warn "* #{ts} | PID: #{process_id} | after stdin.close" if @verbose

      @threads <<
        Thread.new do
          stdout.each_line do |line|
            result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

            output = result.shift

            unless output.empty?
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | extra output: #{output.inspect}" if @verbose
              print(output)
            end

            message = result.shift
            # next unless message

            if message
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
            else
              warn "* #{ts} | PID: #{process_id} | skipping line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
              next
            end

            message = JSON.parse(message, symbolize_names: true)
            message[:process_id] = process_id
            @messages << message
          end

          warn "* #{ts} | PID: #{process_id} | marking process to exit" if @verbose
          @messages << { type: "exit", process_id: process_id }
        rescue => thread_error
          warn "! #{ts} | Thread error | PID: #{process_id} | #{thread_error.class} | #{thread_error.message} | #{thread_error.backtrace} | #{env["RSPEC_FORMATTER_OUTPUT_ID"]}" if @verbose
          raise thread_error
        end

      warn "* #{ts} | PID: #{process_id} | start copy thread" if @verbose
      @threads << start_copy_thread(stderr, STDERR, process_id)

      warn "* #{ts} | PID: #{process_id} | << error" if @verbose
      @threads << Thread.new do
        unless wait_thr.value.success?
          @messages << { type: "error" }
        end
      end

      warn "* #{ts} | PID: #{process_id} | return wait_thr" if @verbose
      wait_thr
    end

    def popen3_select(env, command, process_id)
      @threads << Thread.new do
        warn "* #{ts} | PID: #{process_id} | before popen3+select" if @verbose

        Open3.popen3(env, *command) do |i, o, e, wait_thr|
          i.close
          readables = [o, e]
          stdout = []
          stderr = []

          warn "* #{ts} | PID: #{process_id} | before read_nonblock" if @verbose

          loop do
            break if readables.empty?

            warn "* #{ts} | PID: #{process_id} | readables: #{readables}" if @verbose

            readable, = IO.select(readables)

            if readable.nil?
              warn "* #{ts} | PID: #{process_id} | no ready streams" if @verbose
              break
            end

            warn "* #{ts} | PID: #{process_id} | readable: #{readable.inspect}" if @verbose

            if readable.include?(o)
              begin
                warn "* #{ts} | PID: #{process_id} | o_read before" if @verbose
                o_read = o.read_nonblock(4096)
                warn "* #{ts} | PID: #{process_id} | o_read after: #{o_read.inspect}" if @verbose

                stdout << o_read
              rescue EOFError
                warn "* #{ts} | PID: #{process_id} | o_delete, readables before: #{readables}" if @verbose
                readables.delete(o)
                warn "* #{ts} | PID: #{process_id} | o_delete, readables after: #{readables}" if @verbose
              rescue => error
                warn "* #{ts} | PID: #{process_id} | o other error: #{error.class}, #{error.message}" if @verbose
                raise error
              end
            end

            if readable.include?(e)
              begin
                warn "* #{ts} | PID: #{process_id} | e_read before" if @verbose
                e_read = e.read_nonblock(4096)
                warn "* #{ts} | PID: #{process_id} | e_read after: #{e_read.inspect}" if @verbose

                stderr << e_read
              rescue EOFError
                warn "* #{ts} | PID: #{process_id} | e_delete, readables before: #{readables}" if @verbose
                readables.delete(e)
                warn "* #{ts} | PID: #{process_id} | e_delete, readables after: #{readables}" if @verbose
              rescue => error
                warn "* #{ts} | PID: #{process_id} | e other error: #{error.class}, #{error.message}" if @verbose
                raise error
              end
            end

            warn "* #{ts} | PID: #{process_id} | outside include checks, readables: #{readables}, readable: #{readable}" if @verbose
          end

          warn "* #{ts} | PID: #{process_id} | after read blocks" if @verbose

          stdout_s = stdout.join
          stderr_s = stderr.join

          warn "* #{ts} | PID: #{process_id} | before each_line parsing, size: #{stdout_s.size}" if @verbose

          stdout_s.each_line do |line|
            result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

            output = result.shift

            unless output.empty?
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | extra output: #{output.inspect}" if @verbose
              print(output)
            end

            message = result.shift
            # next unless message

            if message
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
            else
              warn "* #{ts} | PID: #{process_id} | skipping line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
              next
            end

            message = JSON.parse(message, symbolize_names: true)
            message[:process_id] = process_id
            @messages << message
          end

          warn "* #{ts} | PID: #{process_id} | before stderr write, size: #{stderr_s.size}" if @verbose

          unless stderr_s.empty?
            STDERR.puts(stderr_s)
          end

          warn "* #{ts} | PID: #{process_id} | before checking wait_thr status" if @verbose
          warn "* #{ts} | PID: #{process_id} | wait_thr status: #{wait_thr.value.exitstatus}" if @verbose

          unless wait_thr.value.success?
            @messages << { type: "error" }
          end

          warn "* #{ts} | PID: #{process_id} | before exit message" if @verbose

          @messages << { type: "exit", process_id: process_id }

          @wait_thr_statuses << wait_thr.value.exitstatus
        end

        warn "* #{ts} | PID: #{process_id} | after popen3+select" if @verbose
      end
    end

    def popen3_select_reverse(env, command, process_id)
      @threads << Thread.new do
        warn "* #{ts} | PID: #{process_id} | before popen3+select reverse" if @verbose

        Open3.popen3(env, *command) do |i, o, e, wait_thr|
          i.close
          stdout = []
          stderr = []

          warn "* #{ts} | PID: #{process_id} | before read blocks" if @verbose

          loop do
            begin
              warn "* #{ts} | PID: #{process_id} | before o_read" if @verbose
              o_read = o.read_nonblock(4096)
              warn "* #{ts} | PID: #{process_id} | after o_read: #{o_read.inspect}" if @verbose

              stdout << o_read
            rescue IO::WaitReadable
              warn "* #{ts} | PID: #{process_id} | o WaitReadable before select" if @verbose
              selected = IO.select([o], nil, nil, 10)

              if selected.nil?
                warn "* #{ts} | PID: #{process_id} | o WaitReadable no ready streams" if @verbose
                break
              end

              warn "* #{ts} | PID: #{process_id} | o WaitReadable after select: #{selected.inspect}" if @verbose
              retry
            rescue EOFError
              warn "* #{ts} | PID: #{process_id} | o eof" if @verbose
              break
            end
          end

          loop do
            begin
              warn "* #{ts} | PID: #{process_id} | before e_read" if @verbose
              e_read = e.read_nonblock(4096)
              warn "* #{ts} | PID: #{process_id} | after e_read: #{e_read.inspect}" if @verbose

              stderr << e_read
            rescue IO::WaitReadable
              warn "* #{ts} | PID: #{process_id} | e WaitReadable before select" if @verbose
              selected = IO.select([e], nil, nil, 10)

              if selected.nil?
                warn "* #{ts} | PID: #{process_id} | e WaitReadable no ready streams" if @verbose
                break
              end

              warn "* #{ts} | PID: #{process_id} | e WaitReadable after select: #{selected.inspect}" if @verbose
              retry
            rescue EOFError
              warn "* #{ts} | PID: #{process_id} | e eof" if @verbose
              break
            end
          end

          warn "* #{ts} | PID: #{process_id} | after read blocks" if @verbose

          stdout_s = stdout.join
          stderr_s = stderr.join

          warn "* #{ts} | PID: #{process_id} | before each_line parsing, size: #{stdout_s.size}" if @verbose

          stdout_s.each_line do |line|
            result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

            output = result.shift

            unless output.empty?
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | extra output: #{output.inspect}" if @verbose
              print(output)
            end

            message = result.shift
            # next unless message

            if message
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
            else
              warn "* #{ts} | PID: #{process_id} | skipping line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
              next
            end

            message = JSON.parse(message, symbolize_names: true)
            message[:process_id] = process_id
            @messages << message
          end

          warn "* #{ts} | PID: #{process_id} | before stderr write, size: #{stderr_s.size}" if @verbose

          unless stderr_s.empty?
            STDERR.puts(stderr_s)
          end

          warn "* #{ts} | PID: #{process_id} | before checking wait_thr status" if @verbose
          warn "* #{ts} | PID: #{process_id} | wait_thr status: #{wait_thr.value.exitstatus}" if @verbose

          unless wait_thr.value.success?
            @messages << { type: "error" }
          end

          warn "* #{ts} | PID: #{process_id} | before exit message" if @verbose

          @messages << { type: "exit", process_id: process_id }

          @wait_thr_statuses << wait_thr.value.exitstatus
        end

        warn "* #{ts} | PID: #{process_id} | after popen3+select reverse" if @verbose
      end
    end

    def capture3(env, command, process_id)
      @threads << Thread.new do
        warn "* #{ts} | PID: #{process_id} | before capture3" if @verbose

        stdout_s, stderr_s, wait_thr = Open3.capture3(env, *command)

        warn "* #{ts} | PID: #{process_id} | after capture3" if @verbose

        stdout_s.each_line do |line|
          result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

          output = result.shift

          unless output.empty?
            warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | extra output: #{output.inspect}" if @verbose
            print(output)
          end

          message = result.shift
          # next unless message

          if message
            warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
          else
            warn "* #{ts} | PID: #{process_id} | skipping line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
            next
          end

          message = JSON.parse(message, symbolize_names: true)
          message[:process_id] = process_id
          @messages << message
        end

        warn "* #{ts} | PID: #{process_id} | before stderr write, size: #{stderr_s.size}" if @verbose

        unless stderr_s.empty?
          STDERR.write(stderr_s)
        end

        warn "* #{ts} | PID: #{process_id} | after stderr write, size: #{stderr_s.size}" if @verbose

        unless wait_thr.success?
          @messages << { type: "error" }
        end

        warn "* #{ts} | PID: #{process_id} | marking process to exit" if @verbose
        @messages << { type: "exit", process_id: process_id }

        warn "* #{ts} | PID: #{process_id} | pushing exitstatus" if @verbose

        @wait_thr_statuses << wait_thr.exitstatus
      end
    end

    def capture2e(env, command, process_id)
      @threads << Thread.new do
        warn "* #{ts} | PID: #{process_id} | before capture2e" if @verbose

        log, wait_thr = Open3.capture2e(env, *command)

        warn "* #{ts} | PID: #{process_id} | after capture2e" if @verbose

        log.each_line do |line|
          if line.start_with?(env["RSPEC_FORMATTER_OUTPUT_ID"])
            result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

            output = result.shift

            unless output.empty?
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | extra output: #{output.inspect}" if @verbose
              print(output)
            end

            message = result.shift
            # next unless message

            if message
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
            else
              warn "* #{ts} | PID: #{process_id} | skipping line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
              next
            end

            message = JSON.parse(message, symbolize_names: true)
            message[:process_id] = process_id
            @messages << message
          else
            warn "* #{ts} | PID: #{process_id} | before stderr line write, size: #{line.size}, content: #{line.inspect}" if @verbose

            unless line.empty?
              STDERR.write(line)
            end

            warn "* #{ts} | PID: #{process_id} | after stderr line write, size: #{line.size}, content: #{line.inspect}" if @verbose
          end
        end

        unless wait_thr.success?
          @messages << { type: "error" }
        end

        warn "* #{ts} | PID: #{process_id} | marking process to exit" if @verbose
        @messages << { type: "exit", process_id: process_id }

        warn "* #{ts} | PID: #{process_id} | pushing exitstatus" if @verbose

        @wait_thr_statuses << wait_thr.exitstatus
      end
    end

    def popen2e(env, command, process_id)
      warn "* #{ts} | PID: #{process_id} | before popen2e" if @verbose

      stdin, stdout_and_stderr, wait_thr = Open3.popen2e(env, *command)

      warn "* #{ts} | PID: #{process_id} | after popen2e" if @verbose

      stdin.close

      warn "* #{ts} | PID: #{process_id} | after stdin.close" if @verbose

      @threads <<
        Thread.new do
          stdout_and_stderr.each_line do |line|
            if line.start_with?(env["RSPEC_FORMATTER_OUTPUT_ID"])
              result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

              output = result.shift

              unless output.empty?
                warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | extra output: #{output.inspect}" if @verbose
                print(output)
              end

              message = result.shift
              # next unless message

              if message
                warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
              else
                warn "* #{ts} | PID: #{process_id} | skipping line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
                next
              end

              message = JSON.parse(message, symbolize_names: true)
              message[:process_id] = process_id
              @messages << message
            else
              warn "* #{ts} | PID: #{process_id} | before stderr line write, size: #{line.size}, content: #{line.inspect}" if @verbose

              unless line.empty?
                STDERR.write(line)
              end

              warn "* #{ts} | PID: #{process_id} | after stderr line write, size: #{line.size}, content: #{line.inspect}" if @verbose
            end
          end

          warn "* #{ts} | PID: #{process_id} | marking process to exit" if @verbose
          @messages << { type: "exit", process_id: process_id }
        rescue => thread_error
          warn "! #{ts} | Thread error | PID: #{process_id} | #{thread_error.class} | #{thread_error.message} | #{thread_error.backtrace} | #{env["RSPEC_FORMATTER_OUTPUT_ID"]}" if @verbose
          raise thread_error
        end

      warn "* #{ts} | PID: #{process_id} | << error" if @verbose
      @threads << Thread.new do
        unless wait_thr.value.success?
          @messages << { type: "error" }
        end
      end

      warn "* #{ts} | PID: #{process_id} | return wait_thr" if @verbose
      wait_thr
    end

    def popen2e_sync(env, command, process_id)
      @threads << Thread.new do
        warn "* #{ts} | PID: #{process_id} | before popen2e sync" if @verbose

        stdin, stdout_and_stderr, wait_thr = Open3.popen2e(env, *command)
        stdin.close

        warn "* #{ts} | PID: #{process_id} | after stdin.close" if @verbose

        stdout_and_stderr.each_line do |line|
          if line.start_with?(env["RSPEC_FORMATTER_OUTPUT_ID"])
            result = line.split(env["RSPEC_FORMATTER_OUTPUT_ID"])

            output = result.shift

            unless output.empty?
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | extra output: #{output.inspect}" if @verbose
              print(output)
            end

            message = result.shift
            # next unless message

            if message
              warn "* #{ts} | PID: #{process_id} | line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
            else
              warn "* #{ts} | PID: #{process_id} | skipping line: #{line.inspect} | result: #{result.inspect} | output: #{output.inspect} | message: #{message.inspect}" if @verbose
              next
            end

            message = JSON.parse(message, symbolize_names: true)
            message[:process_id] = process_id
            @messages << message
          else
            warn "* #{ts} | PID: #{process_id} | before stderr line write, size: #{line.size}, content: #{line.inspect}" if @verbose

            unless line.empty?
              STDERR.write(line)
            end

            warn "* #{ts} | PID: #{process_id} | after stderr line write, size: #{line.size}, content: #{line.inspect}" if @verbose
          end
        end

        stdout_and_stderr.close

        warn "* #{ts} | PID: #{process_id} | marking process to exit" if @verbose
        @messages << { type: "exit", process_id: process_id }

        warn "* #{ts} | PID: #{process_id} | << error" if @verbose
        unless wait_thr.value.success?
          @messages << { type: "error" }
        end

        @wait_thr_statuses << wait_thr.value.exitstatus

        warn "* #{ts} | PID: #{process_id} | after popen2e sync" if @verbose
      rescue => thread_error
        warn "! #{ts} | Thread error | PID: #{process_id} | #{thread_error.class} | #{thread_error.message} | #{thread_error.backtrace} | #{env["RSPEC_FORMATTER_OUTPUT_ID"]}" if @verbose
        raise thread_error
      end
    end

    def start_copy_thread(src, dst, process_id)
      Thread.new do
        loop do
          msg = src.readpartial(4096)
          warn "$ #{ts} | PID: #{process_id} | SCT read | #{msg.inspect}" if @verbose
          msg
        rescue EOFError
          warn "$ #{ts} | PID: #{process_id} | SCT EOFError" if @verbose
          src.close
          break
        else
          warn "$ #{ts} | PID: #{process_id} | SCT else | #{msg.inspect}" if @verbose
          dst.write(msg)
        end
      end
    end

    def handle_messages
      exited = 0

      loop do
        message = @messages.pop

        warn "> #{ts} | #{@messages.size} left | #{exited}/#{@num_processes} | #{message}" if @verbose

        case message[:type]
        when "example_passed"
          example = FakeExample.from_obj(message[:example])
          @reporter.example_passed(example)
        when "group_started"
          @reporter.group_started(message[:group].to_struct)
        when "group_finished"
          @reporter.group_finished
        when "example_pending"
          example = FakeExample.from_obj(message[:example])
          @reporter.example_pending(example)
        when "load_summary"
          message = message[:summary]
          # NOTE: notifications order and content is not guaranteed hence the fetch
          #       and count increment tracking to get the latest accumulated load time
          @reporter.load_time = message[:load_time] if message.fetch(:count, 0) > @load_count
        when "example_failed"
          example = FakeExample.from_obj(message[:example])
          @reporter.example_failed(example)
          @failure_count += 1
          if fail_fast_met
            warn "* #{ts} | Loop: break via killing threads" if @verbose

            @threads.each(&:kill)
            break
          end
        when "message"
          if message[:message].include?("An error occurred") || message[:message].include?("occurred outside of examples")
            @reporter.error_outside_of_examples(message[:message])
            @error = true
          else
            @reporter.message(message[:message])
          end
        when "seed"
        when "close"
        when "error"
          # Do nothing
          nil
        when "exit"
          exited += 1
          if exited == @num_processes
            warn "* #{ts} | Loop: break via exited count" if @verbose
            break
          end
        else
          warn "! #{ts} | Unhandled msg: #{message}" if @verbose
          STDERR.puts("Unhandled message in main process: #{message}")
        end

        warn "* #{ts} | STDOUT flush" if @verbose
        STDOUT.flush
      end

      warn "* #{ts} | Loop is broken" if @verbose
    rescue Interrupt => error
      warn "! #{ts} | Interrupt | #{error.class} | #{error.message} | #{error.backtrace}" if @verbose
    rescue => other
      warn "! #{ts} | Other error | #{other.class} | #{other.message} | #{other.backtrace}" if @verbose
    end

    def fail_fast_met
      !@fail_fast.nil? && @failure_count >= @fail_fast
    end

    def ts
      Time.now.strftime("%Y-%m-%d %H:%M:%S.%6N %z")
    end
  end
end
