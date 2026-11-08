# frozen_string_literal: true

module RSpec
  module OSC7501
    class Writer # :nodoc: all
      def initialize(output, mode:, title:)
        raise ArgumentError, 'RSPEC_OSC7501 must be auto, off, or force' unless %w[auto off force].include?(mode)

        @output = output
        @enabled = mode == 'force' || (mode == 'auto' && output.respond_to?(:tty?) && output.tty?)
        @title = encode(title, 192) if @enabled
      rescue IOError, SystemCallError
        @enabled = false
      end

      def emit(state:, msg:, progress: nil)
        return unless @enabled

        fields = ['app=rspec', "title=#{@title}", "state=#{state}", "msg=#{encode(msg, 2048)}"]
        fields << "progress=#{progress.to_i.clamp(0, 100)}" if state == 'working' && !progress.nil?
        @output.write("\e]7501;#{fields.join(':')}\e\\")
        @output.flush if @output.respond_to?(:flush)
      rescue IOError, SystemCallError
        @enabled = false
      end

      private

      def encode(text, byte_limit)
        input = text.to_s.byteslice(0, sanitization_byte_limit(byte_limit))
        clean = input.encode('UTF-8', invalid: :replace, undef: :replace).gsub(/[\u0000-\u001F\u007F-\u009F]/, '')
        bytes = 0
        bounded = clean.each_char.take_while do |char|
          bytes += char.bytesize
          bytes <= byte_limit
        end.join
        [bounded].pack('m0')
      end

      # Bound sanitization work with 50% headroom for stripped controls.
      def sanitization_byte_limit(output_byte_limit)
        output_byte_limit + output_byte_limit / 2
      end
    end
  end
end
