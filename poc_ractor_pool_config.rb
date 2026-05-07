# frozen_string_literal: true
# Puma config for the modified-Puma-with-RactorPool variant.
#
# Single process, single Server, RactorPool of N Ractors instead of a
# ThreadPool of N threads. We pass `use_ractor_pool: true` via the user
# options hash so Server#run picks up our experimental branch.

require 'etc'

bind "tcp://0.0.0.0:#{ENV.fetch('PORT', 9292)}"

# We do NOT cluster; the whole point is one process, many Ractors.
workers 0

# These get used as min/max for RactorPool. We pin to nprocessors.
n = Integer(ENV.fetch('RACTORS', Etc.nprocessors))
threads n, n

# Tell Server#run to use the RactorPool variant.
ENV['PUMA_RACTOR_POOL']    = '1'
ENV['PUMA_RACTOR_RACKUP'] ||= File.expand_path('poc_baseline_app.ru', __dir__)

quiet
