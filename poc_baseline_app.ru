# frozen_string_literal: true
# Baseline rack app for the Puma vs. Puma-Ractor PoC.
# Mirrors the Ractor PoC's response shape so the two are comparable.

run ->(env) {
  # Fixed-length body so `ab` doesn't flag varying-length responses across
  # workers as failures. We pad pid to 10 digits.
  body = format("hello from puma worker pid=%010d\n", Process.pid)
  [200, { 'content-type' => 'text/plain', 'content-length' => body.bytesize.to_s }, [body]]
}
