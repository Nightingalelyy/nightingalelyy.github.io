#!/usr/bin/ruby
# frozen_string_literal: true
# Code is data: it is never evaluated, required, or passed to a shell.
require 'json'
require_relative '../vendor/rouge/lib/rouge'

MAX_BLOCKS = 64
MAX_BLOCK_BYTES = 256 * 1024
MAX_TOTAL_BYTES = 512 * 1024
MAX_REQUEST_BYTES = 4 * 1024 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024

begin
  input = STDIN.read(MAX_REQUEST_BYTES + 1)
  raise ArgumentError, 'Request is too large' if input.bytesize > MAX_REQUEST_BYTES
  payload = JSON.parse(input)
  blocks = payload['blocks']
  raise ArgumentError, 'Expected a blocks array' unless blocks.is_a?(Array) && blocks.length <= MAX_BLOCKS
  total_bytes = 0
  blocks.each do |block|
    raise ArgumentError, 'Expected code and language strings' unless block.is_a?(Hash) && block['code'].is_a?(String)
    language = block.fetch('language', block.fetch('lang', ''))
    raise ArgumentError, 'Expected a language string' unless language.is_a?(String) && language.bytesize <= 128
    total_bytes += block['code'].bytesize
    raise ArgumentError, 'Code block is too large' if block['code'].bytesize > MAX_BLOCK_BYTES
  end
  raise ArgumentError, 'Batch is too large' if total_bytes > MAX_TOTAL_BYTES
  raise 'Unexpected Rouge version' unless Rouge.version == '3.30.0'
  Rouge::Formatter.disable_escape!
  formatter = Rouge::Formatters::HTML.new
  highlighted = blocks.map do |block|
    code = block['code']
    # Match the site's fence language handling; legacy ?linenums is not an option.
    language = block.fetch('language', block.fetch('lang', '')).strip.split(/\s+/, 2).first.to_s.split('?', 2).first.to_s.downcase
    language = 'plaintext' unless language.match?(/\A[a-z0-9_+.-]{1,64}\z/)
    lexer = language == 'guess' ? nil : Rouge::Lexer.find_fancy(language, code)
    lexer ||= Rouge::Lexers::PlainText.new
    did_highlight = !lexer.is_a?(Rouge::Lexers::PlainText)
    begin
      html = formatter.format(lexer.lex(code))
    rescue StandardError
      html = formatter.format(Rouge::Lexers::PlainText.new.lex(code))
      did_highlight = false
    end
    { 'html' => html, 'language' => language, 'highlighted' => did_highlight }
  end
  response = JSON.generate('blocks' => highlighted, 'version' => Rouge.version)
  raise ArgumentError, 'Highlighted output is too large' if response.bytesize > MAX_RESPONSE_BYTES
  STDOUT.write(response)
rescue StandardError
  # Do not echo authored code or parser internals into application logs.
  STDERR.write('Code highlighting could not process this request.\n')
  exit 1
end
