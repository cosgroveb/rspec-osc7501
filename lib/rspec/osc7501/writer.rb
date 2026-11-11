# frozen_string_literal: true

module RSpec
  module OSC7501
    class Writer # :nodoc: all
      def self.valid_id?(id)
        id.is_a?(String) && id.ascii_only? && id.bytesize <= 128 &&
          !!(id =~ %r{\A[A-Za-z0-9_.+-]{1,32}(?:/[A-Za-z0-9_.+-]{1,32}){0,7}\z})
      end

      def initialize(output, mode:, title:, id: nil)
        raise ArgumentError, 'RSPEC_OSC7501 must be auto, off, or force' unless %w[auto off force].include?(mode)

        @output = output
        @id = id
        @enabled = (id.nil? || self.class.valid_id?(id)) &&
                   output_enabled?(mode)
        @title = encode(title, 192) if @enabled
      rescue IOError, SystemCallError
        @enabled = false
      end

      def emit(state:, msg:, progress: nil)
        return unless @enabled

        fields = ['app=rspec', "title=#{@title}", "state=#{state}", "msg=#{encode(msg, 2048)}"]
        fields << "id=#{@id}" if @id
        fields << "progress=#{[[progress.to_i, 0].max, 100].min}" if state == 'working' && !progress.nil?
        @output.write("\e]7501;#{fields.join(':')}\e\\")
        @output.flush if @output.respond_to?(:flush)
      rescue IOError, SystemCallError
        @enabled = false
      end

      private

      def output_enabled?(mode)
        mode == 'force' || (mode == 'auto' && automatic_output?)
      end

      def automatic_output?
        ENV['TERM'] != 'dumb' && @output.respond_to?(:tty?) && @output.tty?
      end

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
