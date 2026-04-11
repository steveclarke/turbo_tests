# frozen_string_literal: true

require "spec_helper"

RSpec.describe TurboTests::Reporter do
  let(:start_time) { RSpec::Core::Time.now }
  let(:seed) { 12345 }
  let(:reporter) { described_class.new(start_time, seed, true) }

  # A spy formatter that records everything it receives
  let(:spy_formatter) do
    Class.new do
      attr_reader :events

      def initialize(_output)
        @events = []
      end

      # Standard RSpec events
      def start(notification) = @events << [:start, notification]
      def seed(notification) = @events << [:seed, notification]
      def example_group_started(notification) = @events << [:example_group_started, notification]
      def example_group_finished(notification) = @events << [:example_group_finished, notification]
      def example_passed(notification) = @events << [:example_passed, notification]
      def example_failed(notification) = @events << [:example_failed, notification]
      def example_pending(notification) = @events << [:example_pending, notification]

      # Turbo events
      def turbo_example_passed(pid, notification) = @events << [:turbo_example_passed, pid, notification]
      def turbo_example_failed(pid, notification) = @events << [:turbo_example_failed, pid, notification]
      def turbo_example_pending(pid, notification) = @events << [:turbo_example_pending, pid, notification]
      def turbo_group_started(pid, notification) = @events << [:turbo_group_started, pid, notification]
      def turbo_group_finished(pid) = @events << [:turbo_group_finished, pid]
      def turbo_file_started(pid, file) = @events << [:turbo_file_started, pid, file]
      def turbo_file_completed(pid) = @events << [:turbo_file_completed, pid]
      def turbo_all_workers_finished = @events << [:turbo_all_workers_finished]

      def respond_to?(method, include_all = false)
        %i[
          start seed
          example_group_started example_group_finished
          example_passed example_failed example_pending
          turbo_example_passed turbo_example_failed turbo_example_pending
          turbo_group_started turbo_group_finished
          turbo_file_started turbo_file_completed
          turbo_all_workers_finished
        ].include?(method) || super
      end
    end
  end

  let(:formatter_instance) { spy_formatter.new($stdout) }

  before do
    reporter.instance_variable_get(:@formatters) << formatter_instance
  end

  describe "#report" do
    it "stores example_groups" do
      groups = [["spec/a_spec.rb", "spec/b_spec.rb"], ["spec/c_spec.rb"]]
      reporter.report(groups) { |_| }
      expect(reporter.example_groups).to eq(groups)
    end

    it "does not fire StartNotification" do
      groups = [["spec/a_spec.rb"]]
      reporter.report(groups) { |_| }
      start_events = formatter_instance.events.select { |e| e[0] == :start }
      expect(start_events).to be_empty
    end
  end

  describe "#start_with_example_count" do
    it "fires StartNotification with the given count" do
      groups = [["spec/a_spec.rb"]]
      reporter.report(groups) do |_|
        reporter.start_with_example_count(500)
      end

      start_event = formatter_instance.events.find { |e| e[0] == :start }
      expect(start_event).not_to be_nil
      expect(start_event[1].count).to eq(500)
    end
  end

  describe "dual dispatch" do
    it "fires turbo_example_passed with process_id before example_passed" do
      groups = [["spec/a_spec.rb"]]
      reporter.report(groups) do |_|
        reporter.start_with_example_count(1)
        reporter.current_process_id = 1

        fake_result = TurboTests::FakeExecutionResult.new(false, nil, :passed, false, nil, nil)
        fake_example = TurboTests::FakeExample.new(fake_result, "spec/a_spec.rb:1", "works", "works", {shared_group_inclusion_backtrace: []}, "spec/a_spec.rb:1")
        reporter.example_passed(fake_example)
      end

      event_types = formatter_instance.events.map(&:first)
      turbo_idx = event_types.index(:turbo_example_passed)
      std_idx = event_types.index(:example_passed)
      expect(turbo_idx).to be < std_idx
    end

    it "passes current_process_id to turbo events" do
      groups = [["spec/a_spec.rb"]]
      reporter.report(groups) do |_|
        reporter.start_with_example_count(1)
        reporter.current_process_id = 3

        fake_result = TurboTests::FakeExecutionResult.new(false, nil, :passed, false, nil, nil)
        fake_example = TurboTests::FakeExample.new(fake_result, "spec/a_spec.rb:1", "works", "works", {shared_group_inclusion_backtrace: []}, "spec/a_spec.rb:1")
        reporter.example_passed(fake_example)
      end

      turbo_event = formatter_instance.events.find { |e| e[0] == :turbo_example_passed }
      expect(turbo_event[1]).to eq(3)
    end
  end

  describe "#file_started" do
    it "delegates turbo_file_started with process_id and file_path" do
      groups = [["spec/a_spec.rb"]]
      reporter.report(groups) do |_|
        reporter.file_started(2, "./spec/models/user_spec.rb")
      end

      event = formatter_instance.events.find { |e| e[0] == :turbo_file_started }
      expect(event).to eq([:turbo_file_started, 2, "./spec/models/user_spec.rb"])
    end
  end

  describe "#file_completed" do
    it "delegates turbo_file_completed with process_id" do
      groups = [["spec/a_spec.rb"]]
      reporter.report(groups) do |_|
        reporter.file_completed(2)
      end

      event = formatter_instance.events.find { |e| e[0] == :turbo_file_completed }
      expect(event).to eq([:turbo_file_completed, 2])
    end
  end

  describe "#all_workers_finished" do
    it "delegates turbo_all_workers_finished" do
      groups = [["spec/a_spec.rb"]]
      reporter.report(groups) do |_|
        reporter.all_workers_finished
      end

      event = formatter_instance.events.find { |e| e[0] == :turbo_all_workers_finished }
      expect(event).to eq([:turbo_all_workers_finished])
    end
  end
end
