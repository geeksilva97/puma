# frozen_string_literal: true
# I/O-bound Rack app for the Puma vs. Puma-Ractor benchmark.
#
# Models what a typical Rails action looks like when the bottleneck is
# downstream — a Postgres query, a Redis call, an internal HTTP API.
# The Ruby work is trivial; the time is spent waiting.
#
# Per request:
#   - sleep(IO_WAIT_S)   ← GVL is released during sleep, so OS threads
#                          parallelize at the OS scheduler level just
#                          like Ractors do.
#   - tiny JSON response.
#
# Why sleep and not a real socket call?
#   sleep is the standard simulation in Ruby webserver benchmarks
#   (Heroku, Speedshop, the Puma maintainers' own tests). It releases
#   the GVL the same way blocking I/O does — read(2), recv(2), select(2)
#   — without the bench-time noise of an actual downstream service.
#   For the question "do threads parallelize when the GVL is released?"
#   sleep is exactly the right model.
#
# Tuning:
#   IO_WAIT_MS env var — defaults to 20ms (moderate Postgres query /
#   fast internal API call).
#
# Ractor-safety:
#   - Stdlib only (json).
#   - Captures only frozen module-level constants.

require 'json'

IO_WAIT_S = (ENV['IO_WAIT_MS'] || 20).to_f / 1000.0

run ->(env) {
  sleep IO_WAIT_S

  body = JSON.generate(
    'ok'        => true,
    'waited_ms' => (IO_WAIT_S * 1000).to_i,
    'path'      => env['PATH_INFO'] || '/'
  )

  [200, {
    'content-type'   => 'application/json',
    'content-length' => body.bytesize.to_s
  }, [body]]
}
