# frozen_string_literal: true

# This library treats article text as data. It never evaluates Liquid, executes
# article code, reads arbitrary files, or makes network requests.
require 'json'
require 'psych'
require 'date'
require 'uri'
require 'set'

%w[rexml kramdown kramdown-parser-gfm].each do |name|
  $LOAD_PATH.unshift(File.expand_path("vendor/#{name}/lib", __dir__))
end
require 'kramdown'
require 'kramdown/parser/gfm'

module Publishing
  VERSION = 1
  MAX_REQUEST_BYTES = 20 * 1024 * 1024
  MAX_DOCUMENT_BYTES = 5 * 1024 * 1024
  MAX_ISSUES = 200
  EXCLUDED_ARTICLES = %w[_defaults.md readme.md 1.md].freeze
  EXCLUDED_FILES = %w[Gemfile Gemfile.lock README.md LICENCE].freeze

  def self.authored_path?(path)
    %w[index.md 404.md admin/index.md].include?(path) ||
      (path.start_with?('_docs/') && path.end_with?('.md') && !EXCLUDED_ARTICLES.include?(File.basename(path)))
  end

  def self.valid_path?(path)
    path.is_a?(String) && path.bytesize.between?(1, 1023) && !path.start_with?('/') &&
      !path.match?(/[\\\x00-\x1f\x7f]/) &&
      !path.split('/', -1).any? { |part| ['', '.', '..'].include?(part) }
  end

  def self.static_path?(path)
    valid_path?(path) && !EXCLUDED_FILES.include?(path) &&
      !path.split('/').any? { |part| part.start_with?('.', '_') } &&
      !path.start_with?('desktop/', 'publishing/') && !path.end_with?('.md', '.markdown', '.scss', '.sass')
  end

  def self.route_for(path, metadata = {})
    permalink = metadata['permalink']
    return permalink if permalink.is_a?(String) && permalink.start_with?('/') && !permalink.match?(/:[a-z_]+/)
    return '/' if path == 'index.md'
    return '/404.html' if path == '404.md'
    return '/admin/' if path == 'admin/index.md'
    '/' + path.sub(%r{\A_docs/}, '').sub(/\.md\z/, '') + '/'
  end

  class Validator
    attr_reader :documents, :issues

    def initialize(request)
      raise ArgumentError, 'Unsupported validation request' unless request.is_a?(Hash) && request['schemaVersion'] == VERSION
      @request = request
      @issues = []
      @documents = []
      @files = array('files', 50_000).to_set
      @routes = array('routes', 50_000).map { |route| normalized_route(route) }.to_set
      raise ArgumentError, 'Invalid repository paths' unless @files.all? { |path| Publishing.valid_path?(path) }
      @files.select! { |path| Publishing.static_path?(path) }
      @site = request.fetch('site', {})
      raise ArgumentError, 'Invalid site settings' unless @site.is_a?(Hash)
      supplied_url = @site.fetch('url', 'https://nightingalelyy.github.io').to_s
      supplied_url = "https://#{supplied_url}" unless supplied_url.match?(%r{\Ahttps?://})
      @site_uri = URI.parse(supplied_url)
      raise ArgumentError, 'Invalid website URL' unless %w[http https].include?(@site_uri.scheme) && @site_uri.host
      @baseurl = @site.fetch('baseurl', '').to_s.sub(%r{/\z}, '')
      raise ArgumentError, 'Invalid base URL' unless @baseurl.empty? || (@baseurl.start_with?('/') && !@baseurl.include?('..'))
    end

    def validate
      input_documents = @request['documents']
      raise ArgumentError, 'Expected documents' unless input_documents.is_a?(Array) && input_documents.length <= 10_000
      seen = Set.new
      input_documents.each do |document|
        raise ArgumentError, 'Invalid document' unless document.is_a?(Hash)
        path, raw = document.values_at('path', 'rawContent')
        raise ArgumentError, 'Invalid document path or text' unless Publishing.valid_path?(path) && raw.is_a?(String) && raw.valid_encoding? && raw.bytesize <= MAX_DOCUMENT_BYTES
        raise ArgumentError, 'Duplicate document path' unless seen.add?(path)
        unless Publishing.authored_path?(path)
          issue(path, 1, 'document.unsupported', 'This file is not an editable article or page.')
          next
        end
        parsed = parse_document(path, raw)
        @documents << parsed if parsed
      end
      document_routes = Set.new
      @documents.each do |document|
        route = normalized_route(document[:url])
        issue(document[:path], 2, 'metadata.duplicate_url', 'Another article in this publication has the same published URL.') unless document_routes.add?(route)
        @routes.add(route)
      end
      @documents.each { |document| check_links(document) }
      {
        'schemaVersion' => VERSION, 'ok' => !@issues.any? { |item| item['severity'] == 'error' },
        'issues' => @issues,
        'summary' => { 'documents' => input_documents.length, 'codeBlocks' => @documents.sum { |document| document[:code_blocks].length } }
      }
    end

    def issue(path, line, code, message, severity = 'error')
      return if @issues.length >= MAX_ISSUES
      @issues << { 'severity' => severity, 'path' => path, 'line' => [line.to_i, 1].max, 'code' => code, 'message' => message }
    end

    private

    def array(key, limit)
      value = @request[key]
      raise ArgumentError, "Invalid #{key}" unless value.is_a?(Array) && value.length <= limit && value.all? { |item| item.is_a?(String) && item.bytesize <= 2048 }
      value
    end

    def normalized_route(route)
      raise ArgumentError, 'Invalid published URL' unless route.is_a?(String) && route.start_with?('/') && !route.match?(/[\x00-\x1f\\]/)
      # A route may contain Unicode and percent-encoded components. Decode once;
      # never treat a second decoding as an alternative path.
      decoded = URI::DEFAULT_PARSER.unescape(route)
      raise ArgumentError, 'Invalid published URL' if decoded.match?(/[\x00-\x1f\\]/) || decoded.split('/').include?('..')
      decoded.sub(%r{/index\.html\z}, '/')
    end

    def parse_document(path, raw)
      match = raw.match(/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)(.*)\z/m)
      unless match
        issue(path, 1, 'metadata.frontmatter', 'Add YAML metadata between opening and closing --- lines.')
        return nil
      end
      header, body = match.captures
      body_line = raw[0...match.begin(2)].count("\n") + 1
      begin
        tree = Psych.parse_stream(header)
        inspect_yaml(tree, path)
        metadata = Psych.safe_load(header, permitted_classes: [Date, Time], permitted_symbols: [], aliases: false)
        raise ArgumentError, 'Article metadata must be a mapping' unless metadata.is_a?(Hash) && metadata.keys.all? { |key| key.is_a?(String) }
      rescue Psych::Exception, ArgumentError => error
        issue(path, error.respond_to?(:line) ? error.line.to_i + 1 : 2, 'metadata.yaml', 'Metadata must be valid YAML with named fields and no aliases or object tags.')
        return nil
      end
      check_metadata(path, metadata)
      literal_body = literal_liquid(body, path, body_line)
      check_fences(literal_body, path, body_line)
      begin
        document = Kramdown::Document.new(literal_body, input: 'GFM', hard_wrap: true, syntax_highlighter: nil)
      rescue StandardError
        issue(path, body_line, 'markdown.parse', 'The Markdown could not be parsed. Check its structure and code fences.')
        return nil
      end
      blocks, spans = [], []
      walk(document.root) do |element|
        blocks << element.value if element.type == :codeblock
        spans << element.value if element.type == :codespan
      end
      { path: path, raw: raw, metadata: metadata, body: body, literal_body: literal_body,
        body_line: body_line, root: document.root, code_blocks: blocks, code_spans: spans,
        url: Publishing.route_for(path, metadata) }
    end

    def inspect_yaml(node, path, depth = 0)
      raise ArgumentError, 'Metadata is too deeply nested' if depth > 60
      if node.is_a?(Psych::Nodes::Mapping)
        seen = Set.new
        node.children.each_slice(2) do |key, _value|
          raise ArgumentError, 'Metadata keys must be strings' unless key.is_a?(Psych::Nodes::Scalar)
          issue(path, key.start_line + 2, 'metadata.duplicate', "Metadata repeats the field #{key.value[0, 80].inspect}.") unless seen.add?(key.value)
        end
      end
      Array(node.respond_to?(:children) ? node.children : nil).each { |child| inspect_yaml(child, path, depth + 1) }
    end

    def check_metadata(path, metadata)
      required = path.start_with?('_docs/') ? %w[title category date] : %w[title]
      required.each do |field|
        value = metadata[field]
        valid = field == 'date' ? valid_date?(value) : value.is_a?(String) && !value.strip.empty?
        issue(path, 2, "metadata.#{field}", field == 'date' ? 'Enter a real calendar date, such as 2026-11-02.' : "Enter a nonempty #{field}.") unless valid
      end
      if metadata.key?('order')
        value = metadata['order']
        issue(path, 2, 'metadata.order', 'Navigation order must be a finite number of zero or more.') unless value.is_a?(Numeric) && value.finite? && value >= 0
      end
      if metadata.key?('permalink')
        value = metadata['permalink']
        unless value.is_a?(String) && value.start_with?('/') && !value.match?(/[:\x00-\x20\\]/) && !value.split('/').include?('..')
          issue(path, 2, 'metadata.permalink', 'Use an absolute published URL path for permalink, without template variables.')
        end
      end
      if metadata['published'] == false
        issue(path, 2, 'metadata.unpublished', 'This file is marked published: false and will not appear on the website.')
      end
    end

    def valid_date?(value)
      return true if value.is_a?(Date) || value.is_a?(Time)
      return false unless value.is_a?(String)
      match = value.match(/\A(\d{4})-(\d{1,2})-(\d{1,2})(?:[T ]\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:?\d{2})?)?\z/)
      match && Date.valid_date?(*match.captures.map(&:to_i))
    end

    def literal_liquid(body, path, first_line)
      # Liquid runs before Markdown, including inside fences and HTML. Explicit
      # raw blocks are the one supported way to quote Liquid text verbatim.
      result = +''
      cursor = 0
      line = first_line
      raw = false
      pattern = /\{\{.*?\}\}|\{%.*?%\}|\{\{|\{%/m
      body.to_enum(:scan, pattern).each do
        match = Regexp.last_match
        preceding = body[cursor...match.begin(0)]
        result << preceding
        line += preceding.count("\n")
        token = match[0]
        if token.match?(/\A\{%[ \t]+raw[ \t]+%\}\z/) && !raw
          raw = true
        elsif token.match?(/\A\{%[ \t]+endraw[ \t]+%\}\z/) && raw
          raw = false
        else
          unless raw
            issue(path, line, 'liquid.unprotected', 'Liquid syntax can change the published text, even inside code. Separate literal braces or wrap intentional Liquid examples in {% raw %} and {% endraw %}.')
          end
          result << token
        end
        cursor = match.end(0)
        line += token.count("\n")
      end
      result << body[cursor..-1].to_s
      issue(path, first_line, 'liquid.unclosed_raw', 'Close the {% raw %} block with {% endraw %}.') if raw
      result
    end

    def check_fences(body, path, first_line)
      opening = nil
      body.lines.each_with_index do |line, index|
        if opening
          opening = nil if line.match?(/\A {0,3}#{Regexp.escape(opening[:character])}{#{opening[:length]},}[ \t]*\r?\n?\z/)
        else
          match = line.match(/\A {0,3}(`{3,}|~{3,})([^\r\n]*)\r?\n?\z/)
          next unless match
          opening = { character: match[1][0], length: match[1].length, line: first_line + index }
        end
      end
      issue(path, opening[:line], 'markdown.unclosed_fence', 'Close this code fence before publishing so the code renders as intended.') if opening
    end

    def walk(element, &block)
      yield element
      element.children.each { |child| walk(child, &block) }
    end

    def check_links(document)
      walk(document[:root]) do |element|
        tag = element.type == :html_element ? element.value.to_s.downcase : element.type.to_s
        attribute = tag == 'img' ? 'src' : tag == 'a' ? 'href' : nil
        next unless attribute && element.attr[attribute]
        check_url(document, element.attr[attribute], tag == 'img', element.options[:location].to_i)
      end
    end

    def check_url(document, url, image, line)
      value = url.to_s.strip
      return if value.empty? || value.start_with?('#')
      if value.match?(%r{\A(?:mailto:|tel:|data:image/)}i)
        return
      end
      begin
        escaped = URI::DEFAULT_PARSER.escape(value, /[^\x21-\x7e]|[<>"{}|\\^`]/)
        uri = URI.parse(escaped)
        if uri.scheme && !%w[http https].include?(uri.scheme.downcase)
          issue(document[:path], document[:body_line] + line - 1, 'link.scheme', 'This URL cannot be published as a website link or image.')
          return
        end
        return if uri.host && uri.host.downcase != @site_uri.host.downcase
        base = @site_uri.dup
        base.path = URI::DEFAULT_PARSER.escape(@baseurl + document[:url])
        resolved = URI.join(base.to_s, escaped)
        target = resolved.path
        target = target.delete_prefix(@baseurl) if !@baseurl.empty? && (target == @baseurl || target.start_with?(@baseurl + '/'))
        target = normalized_route(target)
        exists = @files.include?(target.delete_prefix('/')) || (!image && @routes.include?(target))
        unless exists
          issue(document[:path], document[:body_line] + line - 1, image ? 'image.missing' : 'link.missing', "#{image ? 'Image' : 'Linked page or file'} is not included in this publication: #{target}")
        end
      rescue URI::InvalidURIError, ArgumentError
        issue(document[:path], document[:body_line] + line - 1, 'link.invalid', 'This URL has an invalid path or encoding.')
      end
    end
  end
end
