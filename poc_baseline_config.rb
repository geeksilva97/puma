# frozen_string_literal: true
# Baseline Puma config: cluster mode, worker count == nprocessors,
# 1:5 thread pool — mirrors Ractor count to make the comparison meaningful.

require 'etc'

bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 9292)}"

workers Integer(ENV.fetch('WORKERS', Etc.nprocessors))
threads 1, 5

# Cluster mode forks; preload keeps RSS lower via copy-on-write.
preload_app!

# Quiet down a bit; we want clean startup output for the bench harness.
quiet
