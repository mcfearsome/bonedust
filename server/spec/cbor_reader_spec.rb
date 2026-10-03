# frozen_string_literal: true

require "rails_helper"

# The CBOR subset decoder sits on the path that decides whether a request is trusted, so
# it gets its own tests rather than being covered incidentally.
RSpec.describe CborReader do
  def hex(string)
    [string.delete(" ")].pack("H*")
  end

  it "reads small unsigned integers" do
    expect(described_class.decode(hex("00"))).to eq(0)
    expect(described_class.decode(hex("17"))).to eq(23)
  end

  it "reads multi-byte integers" do
    expect(described_class.decode(hex("18 18"))).to eq(24)
    expect(described_class.decode(hex("19 01 00"))).to eq(256)
    expect(described_class.decode(hex("1a 00 01 00 00"))).to eq(65_536)
  end

  it "reads negative integers" do
    expect(described_class.decode(hex("20"))).to eq(-1)
    expect(described_class.decode(hex("38 63"))).to eq(-100)
  end

  it "reads byte strings" do
    expect(described_class.decode(hex("44 01 02 03 04"))).to eq(hex("01020304"))
  end

  it "reads text strings" do
    expect(described_class.decode(hex("63 61 62 63"))).to eq("abc")
  end

  it "reads arrays" do
    expect(described_class.decode(hex("83 01 02 03"))).to eq([1, 2, 3])
  end

  it "reads the shape of an App Attest assertion" do
    # { "signature": h'ABCD', "authenticatorData": h'01020304' }
    bytes = hex("a2") + hex("69") + "signature" + hex("42 ab cd") +
            hex("71") + "authenticatorData" + hex("44 01 02 03 04")
    decoded = described_class.decode(bytes)
    expect(decoded["signature"]).to eq(hex("abcd"))
    expect(decoded["authenticatorData"]).to eq(hex("01020304"))
  end

  it "refuses a truncated payload rather than guessing" do
    expect { described_class.decode(hex("44 01 02")) }
      .to raise_error(CborReader::MalformedError)
  end

  it "refuses indefinite-length items" do
    expect { described_class.decode(hex("5f")) }.to raise_error(CborReader::MalformedError)
  end

  it "refuses floats, which Apple does not send" do
    expect { described_class.decode(hex("fa 3f 80 00 00")) }
      .to raise_error(CborReader::MalformedError)
  end

  it "refuses unbounded nesting" do
    deep = hex("81") * 40 + hex("00")
    expect { described_class.decode(deep) }.to raise_error(CborReader::MalformedError)
  end
end
