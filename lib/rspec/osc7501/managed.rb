# frozen_string_literal: true

require_relative '../osc7501'

module RSpec
  module OSC7501
    # Selects an additive formatter only for a managed child invocation.
    module Managed
      # Isolate RSpec's private formatter-loader seam to this configuration.
      module Loader # :nodoc: all
        def setup_default(output_stream, deprecation_stream)
          super
          add Formatter, output_stream unless formatters.any? { |formatter| formatter.is_a?(Formatter) }
        end
      end

      def self.install!(configuration = RSpec.configuration)
        return false unless Writer.valid_id?(ENV['RSPEC_OSC7501_ID'])
        return false if ENV['RSPEC_OSC7501'] == 'off'

        loader = configuration.send(:formatter_loader)
        return false if loader.is_a?(Loader)

        loader.singleton_class.prepend(Loader)
        true
      end
    end
  end
end

RSpec::OSC7501::Managed.install!
