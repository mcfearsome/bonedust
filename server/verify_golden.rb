#!/usr/bin/env ruby
# frozen_string_literal: true

# §6's cross-language golden test, as a plain script so it runs without bundler.
#
# Swift emits shared/golden/derivations.json with `make golden`; this reproduces every
# entry from the seed alone and fails loudly on the first disagreement.

require "json"
require_relative "lib/bonedust/ceiling"

fixture = File.expand_path("../shared/golden/derivations.json", __dir__)
expected = JSON.parse(File.read(fixture))
constants = Bonedust.constants

failures = []
expected.each do |row|
  actual = Bonedust::Ceiling.derive(
    seed: row.fetch("seed"), site_id: row.fetch("siteID"), constants: constants
  )
  %w[fossilID instances baseCeiling].each do |field|
    next if actual.fetch(field) == row.fetch(field)

    failures << "seed #{row['seed']} @ #{row['siteID']}: #{field} " \
                "swift=#{row.fetch(field).inspect} ruby=#{actual.fetch(field).inspect}"
  end
end

if failures.empty?
  puts "golden ok: #{expected.size} derivations match Swift exactly"
else
  warn "golden FAILED: #{failures.size} of #{expected.size * 3} fields disagree"
  failures.first(15).each { |line| warn "  #{line}" }
  exit 1
end
