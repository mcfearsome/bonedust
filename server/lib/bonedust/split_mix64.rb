# frozen_string_literal: true

module Bonedust
  # SplitMix64, ported from Sources/BonedustCore/Random/SplitMix64.swift.
  #
  # Ruby Integers are arbitrary precision, so every operation has to be masked back to
  # 64 bits by hand. Miss one mask and the sequence diverges from Swift's silently a few
  # draws later, which is the sort of bug that only shows up as the server rejecting one
  # player in a thousand.
  class SplitMix64
    MASK = 0xFFFF_FFFF_FFFF_FFFF
    GOLDEN = 0x9E37_79B9_7F4A_7C15

    def initialize(seed)
      @state = seed & MASK
    end

    def next_u64
      @state = (@state + GOLDEN) & MASK
      z = @state
      z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & MASK
      z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & MASK
      z ^ (z >> 31)
    end

    # Uniform in [0, 1) with 24 bits of precision. The shift-and-divide has to match
    # Swift's exactly; converting the full 64 bits to a float would not round the same.
    def next_unit
      (next_u64 >> 40) / 16_777_216.0
    end

    # Plain modulo, biased and deliberately so: it is one line in any language, and
    # rejection sampling would be a parity bug waiting to happen.
    def next_int_below(bound)
      return 0 if bound <= 0

      next_u64 % bound
    end

    def next_int(lower, through:)
      return lower if through <= lower

      lower + next_int_below(through - lower + 1)
    end
  end
end
