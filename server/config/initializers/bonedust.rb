# frozen_string_literal: true

# Loads the Bonedust port explicitly.
#
# `lib/bonedust` does not follow Zeitwerk's naming conventions and does not want to be
# autoloaded: it is a straight port of Swift source files, laid out to mirror them so the
# two can be read side by side. `config.autoload_lib(ignore: %w[bonedust])` keeps Zeitwerk
# out of it; this requires it.
require "bonedust/ceiling"

# Parse shared/constants.json once at boot rather than on the first payment. It is 38 KB of
# JSON on the path that decides whether a request is honest, and a cold first request is
# the one most likely to time out.
Rails.application.config.after_initialize do
  Bonedust.constants
rescue StandardError => e
  # Not fatal in development, where the file may be mid-regeneration. In production a
  # missing constants file means every ceiling would be wrong, so fail the boot.
  raise if Rails.env.production?

  Rails.logger.warn("shared/constants.json could not be loaded: #{e.message}")
end

# Attestation is only as good as its configuration, so a production boot that cannot
# enforce it fails here rather than serving requests that skip the check.
Rails.application.config.after_initialize do
  next unless Rails.env.production?

  if ENV["APP_ATTEST_APP_ID"].blank?
    raise "APP_ATTEST_APP_ID must be set in production (teamID.bundleID). " \
          "Without it the relying-party check cannot run and App Attest proves only " \
          "that some app signed the request, not that this one did."
  end
  if ENV["ATTEST_MODE"] == "permissive"
    raise "ATTEST_MODE=permissive is not allowed in production."
  end
end
