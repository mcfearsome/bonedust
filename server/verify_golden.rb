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

# The same gate, for ceilings reached with charms on the belt.
#
# derivations.json cannot cover this: `derive` hardcodes an empty belt, so those 250 rows
# say nothing about the fourteen scaling rules ported into this file by hand. Each row here
# names the charms claimed and the ceiling Swift reached with them.
ceilings_fixture = File.expand_path("../shared/golden/ceilings.json", __dir__)
charmed = File.exist?(ceilings_fixture) ? JSON.parse(File.read(ceilings_fixture)) : []
charmed.each do |row|
  derived = Bonedust::Ceiling.derive(
    seed: row.fetch("seed"), site_id: row.fetch("siteID"), constants: constants
  )
  fossil = constants.fossil(derived.fetch("fossilID")) or next
  actual = Bonedust::Ceiling.ceiling(
    fossil: fossil, instances: derived.fetch("instances"),
    site: constants.site(row.fetch("siteID")),
    claimed_charms: row.fetch("charms"), constants: constants
  )
  next if actual == row.fetch("ceiling")

  failures << "seed #{row['seed']} @ #{row['siteID']} charms=#{row['charms'].inspect}: " \
              "ceiling swift=#{row.fetch('ceiling')} ruby=#{actual}"
end

if failures.empty?
  puts "golden ok: #{expected.size} derivations and #{charmed.size} charmed ceilings " \
       "match Swift exactly"
else
  warn "golden FAILED: #{failures.size} disagreements across " \
       "#{expected.size * 3 + charmed.size} checks"
  failures.first(15).each { |line| warn "  #{line}" }
  exit 1
end
