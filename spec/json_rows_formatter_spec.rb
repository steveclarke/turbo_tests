# frozen_string_literal: true

require "spec_helper"

RSpec.describe TurboTests::JsonRowsFormatter do
  let(:output) { StringIO.new }
  let(:formatter) { described_class.new(output) }

  before do
    # Set the formatter output ID so output_row works
    ENV["RSPEC_FORMATTER_OUTPUT_ID"] = "TEST_ID"
  end

  after do
    ENV.delete("RSPEC_FORMATTER_OUTPUT_ID")
  end

  def parsed_rows
    output.string.lines.map do |line|
      json_part = line.split("TEST_ID").last
      JSON.parse(json_part, symbolize_names: true)
    end
  end

  # Fake notification matching what RSpec sends to example_group_started
  def fake_group_notification(description: "SomeClass", file_path: "./spec/models/some_spec.rb")
    group = Struct.new(:description, :file_path).new(description, file_path)
    Struct.new(:group).new(group)
  end

  describe "file-level events" do
    it "emits file_started on first group_started (depth 0 to 1)" do
      formatter.example_group_started(fake_group_notification)

      types = parsed_rows.map { |r| r[:type] }
      expect(types).to include("file_started")
    end

    it "does not emit file_started on nested group_started (depth 1 to 2)" do
      formatter.example_group_started(fake_group_notification)
      formatter.example_group_started(fake_group_notification(description: "nested"))

      file_started_count = parsed_rows.count { |r| r[:type] == "file_started" }
      expect(file_started_count).to eq(1)
    end

    it "emits file_completed when depth returns to 0" do
      formatter.example_group_started(fake_group_notification)
      formatter.example_group_started(fake_group_notification(description: "nested"))
      formatter.example_group_finished(fake_group_notification(description: "nested"))
      formatter.example_group_finished(fake_group_notification)

      types = parsed_rows.map { |r| r[:type] }
      expect(types).to include("file_completed")
    end

    it "does not emit file_completed on intermediate group_finished" do
      formatter.example_group_started(fake_group_notification)
      formatter.example_group_started(fake_group_notification(description: "nested"))
      formatter.example_group_finished(fake_group_notification(description: "nested"))

      file_completed_count = parsed_rows.count { |r| r[:type] == "file_completed" }
      expect(file_completed_count).to eq(0)
    end

    it "includes the file_path in file_started" do
      formatter.example_group_started(
        fake_group_notification(file_path: "./spec/models/user_spec.rb")
      )

      file_started = parsed_rows.find { |r| r[:type] == "file_started" }
      expect(file_started[:file]).to eq("./spec/models/user_spec.rb")
    end
  end
end
