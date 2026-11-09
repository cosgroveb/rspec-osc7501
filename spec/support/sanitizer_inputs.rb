# frozen_string_literal: true

# Fixed inputs keep sanitizer failures reproducible independently of spec order.
module SanitizerInputs
  SEED = 7501
  ENCODINGS = %w[UTF-8 UTF-16LE UTF-16BE UTF-32LE ISO-8859-1 ASCII-8BIT].freeze
  CHARACTERS = ['a', '界', '😀', 'é', "\0", "\n", "\e", "\u007F", "\u0085", "\u009F", ':', '='].freeze

  def self.cases
    random = Random.new(SEED)
    ENCODINGS.flat_map do |encoding|
      lengths(192).zip(lengths(2048)).map do |title_size, message_size|
        ["#{encoding}, title #{title_size}, message #{message_size}, seed #{SEED}",
         text(random, encoding, title_size), text(random, encoding, message_size)]
      end
    end
  end

  def self.lengths(limit)
    [0, 1, limit - 1, limit, limit + 1, limit * 3 / 2 - 1, limit * 3 / 2, limit * 3 / 2 + 1]
  end

  def self.text(random, encoding, size)
    tokens = CHARACTERS.map { |char| char.encode(encoding, undef: :replace).b }
    tokens << "\xFF\x80".b
    bytes = String.new.b
    bytes << tokens.sample(random: random) while bytes.bytesize < size
    bytes.byteslice(0, size).force_encoding(encoding)
  end
end
