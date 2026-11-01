# frozen_string_literal: true
require_relative 'validator'
require 'cgi'
require 'digest'
require 'time'
require 'rexml/document'

module Publishing
  module BuildAudit
    module_function

    # Rouge produces escaped text and span elements. Parse that small, bounded
    # XML-compatible fragment rather than treating arbitrary HTML as XML.
    def code_text(fragment)
      raise ArgumentError, 'Unexpected code markup' if fragment.match?(/<!|<\?/) || fragment.bytesize > MAX_DOCUMENT_BYTES * 6
      fragment = fragment.gsub(/&([a-zA-Z][a-zA-Z0-9]+);/) do |entity|
        next entity if %w[amp lt gt quot apos].include?(Regexp.last_match(1))
        known = Kramdown::Utils::Entities.entity(Regexp.last_match(1))
        known ? '&#' + known.code_point.to_s + ';' : entity
      end
      document = REXML::Document.new("<code>#{fragment}</code>")
      text = +''
      visit = lambda do |node|
        node.children.each do |child|
          if child.is_a?(REXML::Text)
            text << child.value
          elsif child.is_a?(REXML::Element) && child.name == 'span'
            visit.call(child)
          else
            raise ArgumentError, 'Unexpected markup inside a code block'
          end
        end
      end
      visit.call(document.root)
      text
    end

    def article_html(html)
      match = html.match(/<article\b[^>]*class=["'][^"']*\bcontent\b[^"']*["'][^>]*>(.*?)<\/article\s*>/m)
      raise ArgumentError, 'Article output was not found' unless match
      match[1]
    end

    def code_blocks(html)
      article_html(html).scan(/<pre\b[^>]*>\s*<code\b[^>]*>(.*?)<\/code\s*>\s*<\/pre\s*>/m).map { |match| code_text(match[0]) }
    end

    def code_spans(html)
      without_blocks = article_html(html).gsub(/<pre\b[^>]*>.*?<\/pre\s*>/m, '')
      without_blocks.scan(/<code\b[^>]*>(.*?)<\/code\s*>/m).map { |match| code_text(match[0]) }
    end

    def verify(validator, site)
      outputs = (site.pages + site.collections.values.flat_map(&:docs)).each_with_object({}) do |document, result|
        path = document.respond_to?(:relative_path) ? document.relative_path.to_s : document.path.to_s
        path = path.sub(%r{\A/}, '')
        result[path] = document
      end
      manifest = {}
      validator.documents.each do |source|
        output = outputs[source[:path]]
        unless output && File.file?(output.destination(site.dest))
          validator.issue(source[:path], 1, 'build.missing', 'The site build did not create this article or page.')
          next
        end
        html = File.read(output.destination(site.dest), encoding: 'UTF-8')
        begin
          # Render the pre-Liquid source separately. This covers fenced,
          # indented, inline and raw-HTML code, with only the renderer's own
          # Markdown normalization, and catches Liquid changing any code text.
          expected_html = '<article class="content">' + Kramdown::Document.new(source[:literal_body], input: 'GFM', hard_wrap: true, syntax_highlighter: nil).to_html + '</article>'
          actual_blocks = code_blocks(html)
          actual_spans = code_spans(html)
          if code_blocks(expected_html) != actual_blocks || code_spans(expected_html) != actual_spans
            validator.issue(source[:path], source[:body_line], 'build.code_changed', 'Published code differs from the Markdown source. Check Liquid and raw HTML around the code.')
          end
        rescue StandardError
          validator.issue(source[:path], source[:body_line], 'build.code_markup', 'The generated article code could not be verified safely.')
        end
        manifest[source[:path]] = { 'sha256' => Digest::SHA256.hexdigest(source[:raw]), 'url' => output.url }
      end
      manifest
    end

    def write_manifest(destination, articles, commit)
      raise ArgumentError, 'A full commit SHA is required for publication' unless commit.to_s.match?(/\A[0-9a-f]{40}\z/)
      payload = { 'version' => VERSION, 'commit' => commit, 'builtAt' => Time.now.utc.iso8601, 'articles' => articles }
      File.write(File.join(destination, 'publication-manifest.json'), JSON.pretty_generate(payload) + "\n")
    end
  end
end
