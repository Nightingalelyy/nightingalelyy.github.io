#!/usr/bin/ruby
# frozen_string_literal: true
require_relative 'validator'

begin
  input = STDIN.read(Publishing::MAX_REQUEST_BYTES + 1)
  raise ArgumentError, 'Request exceeds the size limit' if input.bytesize > Publishing::MAX_REQUEST_BYTES
  result = Publishing::Validator.new(JSON.parse(input)).validate
  STDOUT.write(JSON.generate(result))
rescue StandardError
  # A malformed request is different from authored content failing validation.
  # Do not log article bodies, credentials, or parser internals.
  STDERR.write("Publication validation could not process this request.\n")
  exit 2
end
