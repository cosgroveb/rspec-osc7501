# frozen_string_literal: true

module RSpec
  module OSC7501
    class Writer # :nodoc: all
      def initialize(output, mode:, title:)
        raise ArgumentError, "RSPEC_OSC7501 must be auto, off, or force" unless %w[auto off force].include?(mode)

        @output = output
        @enabled = mode == "force" || (mode == "auto" && output.tty?)
        @title = encode(title, 192) if @enabled
      rescue IOError, SystemCallError
        @enabled = false
      end

      def emit(state:, msg:, progress: nil)
        return unless @enabled

        fields = ["app=rspec", "title=#{@title}", "state=#{state}", "msg=#{encode(msg, 2048)}"]
        fields << "progress=#{progress.to_i.clamp(0, 100)}" if state == "working" && !progress.nil?
        @output.write("\e]7501;#{fields.join(':')}\e\\")
      rescue IOError, SystemCallError
        @enabled = false
      end

      private

      def encode(text, byte_limit)
        clean = text.to_s.encode("UTF-8", invalid: :replace, undef: :replace).gsub(/[\u0000-\u001F\u007F-\u009F]/, "")
        bytes = 0
        bounded = clean.each_char.take_while do |char|
          bytes += char.bytesize
          bytes <= byte_limit
        end.join
        [bounded].pack("m0")
      end
    end
  end
end
