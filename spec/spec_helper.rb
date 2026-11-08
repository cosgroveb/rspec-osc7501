# frozen_string_literal: true

require 'stringio'
require 'rspec/osc7501'

module FrameHelpers
  FRAME = /\e\]7501;([^\e]*)\e\\/

  def frames(output)
    output.scan(FRAME).map do |(body)|
      body.split(':').to_h do |field|
        key, value = field.split('=', 2)
        [key, %w[title msg].include?(key) ? value.unpack1('m0').force_encoding('UTF-8') : value]
      end
    end
  end
end

RSpec.configure do |config|
  config.include FrameHelpers
  config.order = :random
  Kernel.srand config.seed
end
