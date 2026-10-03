# frozen_string_literal: true

# Just enough CBOR to read an App Attest payload.
#
# Apple's attestation object and assertion are CBOR maps containing byte strings, text
# strings, integers and arrays — and nothing else. A full CBOR implementation would be a
# gem, a lockfile entry and a supply-chain dependency on the one code path that decides
# whether a request is trusted. Sixty lines that handle exactly the subset Apple emits is
# a better trade, and it is covered by its own spec.
#
# Floats, tags, indefinite-length items and bignums are refused rather than guessed at.
module CborReader
  class MalformedError < StandardError; end

  module_function

  def decode(bytes)
    io = StringIO.new(bytes.to_s.dup.force_encoding(Encoding::BINARY))
    value = read_item(io)
    value
  end

  def read_item(io, depth = 0)
    raise MalformedError, "nesting too deep" if depth > 16

    initial = io.read(1)
    raise MalformedError, "truncated" if initial.nil?

    byte = initial.unpack1("C")
    major = byte >> 5
    info = byte & 0x1F

    case major
    when 0 then read_length(io, info)                       # unsigned integer
    when 1 then -1 - read_length(io, info)                  # negative integer
    when 2 then read_bytes(io, read_length(io, info))       # byte string
    when 3 then read_bytes(io, read_length(io, info)).force_encoding(Encoding::UTF_8)
    when 4 then Array.new(read_length(io, info)) { read_item(io, depth + 1) }
    when 5
      count = read_length(io, info)
      count.times.each_with_object({}) do |_, out|
        key = read_item(io, depth + 1)
        out[key] = read_item(io, depth + 1)
      end
    when 7
      case info
      when 20 then false
      when 21 then true
      when 22 then nil
      else raise MalformedError, "unsupported simple value #{info}"
      end
    else
      raise MalformedError, "unsupported major type #{major}"
    end
  end

  def read_length(io, info)
    case info
    when 0..23 then info
    when 24 then read_uint(io, 1)
    when 25 then read_uint(io, 2)
    when 26 then read_uint(io, 4)
    when 27 then read_uint(io, 8)
    else raise MalformedError, "indefinite or reserved length"
    end
  end

  def read_uint(io, size)
    bytes = io.read(size)
    raise MalformedError, "truncated length" if bytes.nil? || bytes.bytesize != size

    bytes.unpack1({ 1 => "C", 2 => "n", 4 => "N", 8 => "Q>" }.fetch(size))
  end

  def read_bytes(io, length)
    raise MalformedError, "negative length" if length.negative?

    bytes = io.read(length) || ""
    raise MalformedError, "truncated string" if bytes.bytesize != length

    bytes
  end
end
