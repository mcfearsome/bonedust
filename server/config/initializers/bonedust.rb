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
