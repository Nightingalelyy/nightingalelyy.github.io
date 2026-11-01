#!/usr/bin/env ruby
# frozen_string_literal: true
require 'optparse'
require_relative 'repository'

options = { source: File.expand_path('..', __dir__), build: false, destination: nil }
OptionParser.new do |parser|
  parser.on('--source PATH') { |value| options[:source] = File.expand_path(value) }
  parser.on('--destination PATH') { |value| options[:destination] = File.expand_path(value) }
  parser.on('--build') { options[:build] = true }
end.parse!

begin
  validator = Publishing::Validator.new(Publishing::Repository.request(options[:source]))
  result = validator.validate
  if result['ok'] && options[:build]
    require 'jekyll'
    require_relative 'build_audit'
    destination = options[:destination] || File.join(options[:source], '_site')
    source = File.realpath(options[:source])
    raise ArgumentError, 'The build destination cannot contain the source repository' if source == destination || source.start_with?(destination + '/')
    ENV['JEKYLL_ENV'] = 'production'
    config = Jekyll.configuration('source' => source, 'destination' => destination, 'strict_front_matter' => true,
                                  'safe' => true, 'whitelist' => %w[jekyll-feed jekyll-seo-tag jekyll-sitemap])
    site = Jekyll::Site.new(config)
    site.process
    articles = Publishing::BuildAudit.verify(validator, site)
    result['ok'] = !validator.issues.any? { |item| item['severity'] == 'error' }
    if result['ok']
      commit = ENV['GITHUB_SHA'].to_s
      commit = IO.popen(['/usr/bin/git', '-C', source, 'rev-parse', 'HEAD'], &:read).strip if commit.empty?
      Publishing::BuildAudit.write_manifest(destination, articles, commit)
      result['summary']['builtArticles'] = articles.length
    end
  end
  result['issues'].each { |issue| warn "#{issue['path']}:#{issue['line']}: #{issue['severity']}: [#{issue['code']}] #{issue['message']}" }
  puts JSON.generate(result)
  exit(result['ok'] ? 0 : 1)
rescue StandardError => error
  warn "Publication checks failed: #{error.class}: #{error.message}"
  exit 2
end
