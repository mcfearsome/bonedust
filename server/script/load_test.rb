#!/usr/bin/env ruby
# frozen_string_literal: true

# §9: "The ledger survives 500 concurrent POST /payments without lost increments."
#
# Runs the payments path concurrently against a live server and then checks the one thing
# that actually matters: that the debt moved by exactly the sum of what was credited. A
# load test that only measured latency would miss the bug this exists to catch, which is a
# read-modify-write losing increments under contention.
#
# Usage:
#   bin/rails server -p 3000            # in one terminal
#   ATTEST_MODE=permissive ruby script/load_test.rb [concurrency] [per_thread]

require "json"
require "net/http"
require "securerandom"
require "uri"

BASE = ENV.fetch("LEDGER_URL", "http://localhost:3000")
TOTAL = Integer(ARGV[0] || 500)
THREADS = Integer(ENV.fetch("THREADS", "50"))
PER_THREAD = (TOTAL.to_f / THREADS).ceil

def request(method, path, body: nil, install:)
  uri = URI.join(BASE, path)
  klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
  req = klass.new(uri)
  req["Content-Type"] = "application/json"
  req["X-Bonedust-Install"] = install
  req.body = body.to_json if body
  response = Net::HTTP.start(uri.hostname, uri.port, read_timeout: 30) { |http| http.request(req) }
  [response.code.to_i, (JSON.parse(response.body) rescue {})]
end

# Reads the authoritative row, not GET /v1/ledger.
#
# That endpoint is cached for 15 seconds with an ETag, by design — it is the one the whole
# player base polls. A run of this script finishes well inside that window, so reading it
# returned the warm-up value and the script reported 5,000 dollars lost that were sitting
# in the database the whole time. The payment response carries the fresh figure for the
# client; this check needs the row itself.
def ledger_paid
  value = `bin/rails runner 'print CrewLedger.current.paid' 2>/dev/null`.strip
  raise "could not read the ledger row (is the database migrated?)" if value.empty?

  Integer(value)
end

puts "warming up..."
before = ledger_paid
puts "ledger paid before: #{before}"

results = Queue.new
started = Time.now

workers = THREADS.times.map do
  Thread.new do
    # One install per thread, so the rate limiter is not the thing under test. The limit
    # is 120 an hour per install; 500 payments from one install would be rejected by
    # design and would prove nothing about concurrency.
    install = SecureRandom.uuid
    PER_THREAD.times do
      status, slab = request(:post, "/v1/slabs", body: { site: "charmouth" }, install: install)
      next results << [:slab_failed, status, 0] unless status == 201

      amount = 10
      status, body = request(
        :post, "/v1/payments",
        body: {
          slab_id: slab.fetch("slab_id"),
          amount: amount,
          duration_ms: 42_000,
          fossil_id: slab["fossil_id"],
          site: "charmouth",
          exposure: 0.8,
          intact: 0.9,
          gems: 0
        },
        install: install
      )
      results << [status == 201 ? :ok : :rejected, status, body.fetch("credited", 0)]
    end
  end
end
workers.each(&:join)
elapsed = Time.now - started

tally = Hash.new(0)
credited = 0
until results.empty?
  outcome, status, amount = results.pop
  tally["#{outcome} #{status}"] += 1
  credited += amount.to_i
end

after = ledger_paid
moved = after - before

puts ""
puts "sent #{THREADS * PER_THREAD} payments across #{THREADS} threads in #{elapsed.round(2)}s"
puts "  #{(THREADS * PER_THREAD / elapsed).round} payments/second"
tally.sort.each { |label, count| puts "  #{label}: #{count}" }
puts ""
puts "credited by responses: #{credited}"
puts "ledger moved by:       #{moved}"

# A test that passes when nothing happened is worse than no test. The first run of this
# script reported PASS with 500 server errors, because zero credited equals zero moved.
expected = THREADS * PER_THREAD
accepted = tally.select { |label, _| label.start_with?("ok ") }.values.sum
if accepted < expected
  warn "FAIL: only #{accepted} of #{expected} payments were accepted; " \
       "the concurrency check never ran"
  exit 1
end
if credited.zero?
  warn "FAIL: nothing was credited, so nothing was tested"
  exit 1
end

if moved == credited
  puts "PASS: #{accepted} payments, no increments lost"
else
  warn "FAIL: ledger moved #{moved} but responses credited #{credited} " \
       "(#{(credited - moved).abs} lost)"
  exit 1
end
