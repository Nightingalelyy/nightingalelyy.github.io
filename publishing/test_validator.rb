#!/usr/bin/env ruby
# frozen_string_literal: true
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require_relative 'repository'
require_relative 'build_audit'

class PublishingValidatorTest < Minitest::Test
  PATH = '_docs/Notes/2026-11-02-example.md'

  def article(body = "Hello.\n", metadata = "title: Example\ncategory: Notes\ndate: 2026-11-02\norder: 1")
    "---\n#{metadata}\n---\n#{body}"
  end

  def request(raw = article, files: [], routes: [])
    { 'schemaVersion' => 1, 'documents' => [{ 'path' => PATH, 'rawContent' => raw }],
      'files' => files, 'routes' => ['/', '/admin/'] + routes,
      'site' => { 'url' => 'https://nightingalelyy.github.io', 'baseurl' => '' } }
  end

  def validate(raw = article, **options)
    Publishing::Validator.new(request(raw, **options)).validate
  end

  def codes(result)
    result['issues'].map { |issue| issue['code'] }
  end

  def test_current_repository_baseline
    result = Publishing::Validator.new(Publishing::Repository.request(File.expand_path('..', __dir__))).validate
    assert result['ok'], result['issues'].inspect
    assert_operator result['summary']['documents'], :>=, 139
    assert_operator result['summary']['codeBlocks'], :>=, 139
  end

  def test_initializer_regression
    invalid = validate(article("```cpp\nunordered_map<int,int> m{{0,-1}};\n```\n"))
    assert_includes codes(invalid), 'liquid.unprotected'
    refute invalid['ok']
    assert validate(article("```cpp\nunordered_map<int,int> m{ {0,-1} };\n```\n"))['ok']
  end

  def test_liquid_is_checked_in_inline_indented_html_and_prose
    ["`{{ value }}`", "    x{{value}}\n", '<pre><code>{{value}}</code></pre>', '<img src="{{value}}">', '\\{{value}}', '{% include file %}'].each do |body|
      assert_includes codes(validate(article(body))), 'liquid.unprotected', body
    end
  end

  def test_explicit_raw_blocks_preserve_literal_examples
    body = "{% raw %}\n```liquid\n{{ value }}\n{% include file %}\n```\n{% endraw %}\n"
    validator = Publishing::Validator.new(request(article(body)))
    assert validator.validate['ok']
    assert_equal "{{ value }}\n{% include file %}\n", validator.documents.first[:code_blocks].first
    assert_includes codes(validate(article('{% raw %} example'))), 'liquid.unclosed_raw'
    assert_includes codes(validate(article('{% endraw %}'))), 'liquid.unprotected'
  end

  def test_legacy_dates_are_valid_without_mutating_source
    raw = article('Body', "title: Example\ncategory: Notes\ndate: 2022-1-3\ncustom_field: preserved")
    validator = Publishing::Validator.new(request(raw))
    assert validator.validate['ok']
    assert_equal raw, validator.documents.first[:raw]
    assert_includes codes(validate(article('Body', "title: Example\ncategory: Notes\ndate: 2026-02-30"))), 'metadata.date'
  end

  def test_metadata_rejects_duplicate_keys_aliases_objects_and_wrong_types
    assert_includes codes(validate(article('Body', "title: One\ntitle: Two\ncategory: Notes\ndate: 2026-11-02"))), 'metadata.duplicate'
    ["title: &title Example\ncategory: *title\ndate: 2026-11-02", 'title: !ruby/object:Object {}'].each do |metadata|
      assert_includes codes(validate(article('Body', metadata))), 'metadata.yaml'
    end
    result = validate(article('Body', "title: 123\ncategory: []\ndate: no\norder: -1"))
    %w[metadata.title metadata.category metadata.date metadata.order].each { |code| assert_includes codes(result), code }
  end

  def test_missing_local_images_are_blocked_in_markdown_and_raw_html
    ['![Image](/images/uploads/a.png)', '<img src="/images/uploads/a.png">'].each do |body|
      assert_includes codes(validate(article(body))), 'image.missing'
      assert validate(article(body), files: ['images/uploads/a.png'])['ok']
    end
  end

  def test_local_links_follow_published_urls_not_source_paths
    assert validate(article('[Other](/Other/2026-1-3-note/)'), routes: ['/Other/2026-1-3-note/'])['ok']
    assert_includes codes(validate(article('[Missing](/gone/)'))), 'link.missing'
    assert_includes codes(validate(article('[Source](/_docs/notes.md)'), files: ['_docs/notes.md'])), 'link.missing'
    assert validate(article('[Other](../other/)'), routes: ['/Notes/other/'])['ok']
    assert validate(article('[Encoded](/Priority%20queue/example/)'), routes: ['/Priority queue/example/'])['ok']
    assert validate(article('[Chinese](/随笔/文章/)'), routes: ['/随笔/文章/'])['ok']
  end

  def test_external_resources_need_no_network
    assert validate(article('![Image](https://example.invalid/image.png) [Link](https://example.invalid) [Email](mailto:author@example.invalid)'))['ok']
    assert_includes codes(validate(article('![Local](file:///private/secret.png)'))), 'link.scheme'
    assert_includes codes(validate(article('[Internal](https://nightingalelyy.github.io/missing/)'))), 'link.missing'
  end

  def test_literal_urls_in_code_are_not_validated_as_links
    assert validate(article("```html\n<img src=\"/missing.png\">\n```\n\n`[link](/missing/)`\n"))['ok']
  end

  def test_code_fences_must_close_and_longer_closers_work
    assert_includes codes(validate(article("```cpp\nint x;\n"))), 'markdown.unclosed_fence'
    assert validate(article("```cpp\nint x;\n``````\n"))['ok']
    assert validate(article("~~~cpp\nint x;\n~~~\n"))['ok']
  end

  def test_request_boundary_rejects_traversal_duplicates_and_version_mismatch
    invalid = request
    invalid['files'] = ['../secret']
    assert_raises(ArgumentError) { Publishing::Validator.new(invalid).validate }
    invalid = request
    invalid['documents'] *= 2
    assert_raises(ArgumentError) { Publishing::Validator.new(invalid).validate }
    invalid = request
    invalid['schemaVersion'] = 2
    assert_raises(ArgumentError) { Publishing::Validator.new(invalid).validate }
  end

  def test_duplicate_published_urls_are_blocked
    payload = request(article('First', "title: First\ncategory: Notes\ndate: 2026-11-02\npermalink: /same/"))
    payload['documents'] << { 'path' => '_docs/second.md', 'rawContent' => article('Second', "title: Second\ncategory: Notes\ndate: 2026-11-02\npermalink: /same/") }
    assert_includes codes(Publishing::Validator.new(payload).validate), 'metadata.duplicate_url'
  end

  def test_rendered_code_parser_preserves_entities_and_whitespace_exactly
    html = '<article class="content"><pre class="highlight"><code><span class="k">int</span> x = 0;\n&lt;&amp;&gt;</code></pre><p><code>inline &amp; text</code></p></article>'.gsub('\\n', "\n")
    assert_equal ["int x = 0;\n<&>"], Publishing::BuildAudit.code_blocks(html)
    assert_equal ['inline & text'], Publishing::BuildAudit.code_spans(html)
    assert_equal "\u00a0", Publishing::BuildAudit.code_text('&nbsp;')
    assert_raises(ArgumentError) { Publishing::BuildAudit.code_text('<script>bad</script>') }
    assert_raises(ArgumentError) { Publishing::BuildAudit.code_text('<!ENTITY x SYSTEM "file:///secret">') }
  end

  def test_json_helper_reports_content_errors_without_crashing
    command = [RbConfig.ruby, '--disable-gems', File.join(__dir__, 'validate_request.rb')]
    output, _error, status = Open3.capture3(*command, stdin_data: JSON.generate(request(article('{{oops}}'))))
    assert status.success?
    refute JSON.parse(output)['ok']
    output, error, status = Open3.capture3(*command, stdin_data: 'not json')
    refute status.success?
    assert_empty output
    refute_includes error, 'not json'
  end
end
