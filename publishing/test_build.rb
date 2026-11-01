#!/usr/bin/env ruby
# frozen_string_literal: true
# These fixtures use isolated sources and destinations. They never modify or
# publish an article in the real repository.
require 'tmpdir'
require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'digest'

checks = 0
assert = lambda do |condition, message|
  raise message unless condition
  checks += 1
end

Dir.mktmpdir('nightingale-publishing-fixtures-') do |temporary|
  source = File.join(temporary, 'source')
  FileUtils.mkdir_p(File.join(source, '_docs'))
  FileUtils.mkdir_p(File.join(source, '_layouts'))
  File.write(File.join(source, '_config.yml'), <<~YAML)
    url: https://nightingalelyy.github.io
    permalink: pretty
    markdown: kramdown
    kramdown:
      input: GFM
      hard_wrap: true
    collections:
      docs:
        output: true
        permalink: /:path/
    defaults:
      - scope:
          path: ''
        values:
          layout: default
  YAML
  File.write(File.join(source, 'index.md'), "---\ntitle: Home\n---\nHome.\n")
  layout_path = File.join(source, '_layouts', 'default.html')
  File.write(layout_path, '<html><body><article class="content">{{ content }}</article></body></html>')
  path = '_docs/example.md'
  raw = <<~MARKDOWN
    ---
    title: Fixture
    category: Notes
    date: 2026-11-02
    ---
    First line.
    Second line.

    ```cpp
    unordered_map<int,int> m{ {0,-1} };
    if (a < b && b > 0) return;
    ```

        indented < & > code

    Inline `a < b && c`.

    <pre><code>raw &lt; &amp; &gt; &nbsp;</code></pre>

    {% raw %}
    ```liquid
    {{ literal.example }}
    ```
    {% endraw %}
  MARKDOWN
  article_path = File.join(source, path)
  File.write(article_path, raw)
  cli = File.join(__dir__, 'validate_repository.rb')
  run = lambda do |name|
    destination = File.join(temporary, name)
    output, error, status = Open3.capture3({ 'GITHUB_SHA' => 'a' * 40 }, RbConfig.ruby, cli, '--source', source, '--build', '--destination', destination)
    [destination, output + error, status]
  end

  destination, output, status = run.call('valid')
  assert.call(status.success?, "Valid fixture did not build: #{output}")
  manifest = JSON.parse(File.read(File.join(destination, 'publication-manifest.json')))
  assert.call(manifest['commit'] == 'a' * 40, 'Manifest does not identify the built commit')
  assert.call(manifest['articles'][path]['sha256'] == Digest::SHA256.hexdigest(raw), 'Manifest does not identify exact source bytes')
  assert.call(manifest['articles'][path]['url'] == '/example/', 'Manifest does not contain the Jekyll output URL')

  {
    'liquid' => [raw.sub('m{ {0,-1} }', 'm{{0,-1}}'), 'liquid.unprotected'],
    'image' => [raw + "\n![Missing](/images/uploads/missing.png)\n", 'image.missing'],
    'link' => [raw + "\n[Missing](/missing/)\n", 'link.missing'],
    'metadata' => [raw.sub('2026-11-02', '2026-02-30'), 'metadata.date']
  }.each do |name, (content, code)|
    File.write(article_path, content)
    destination, output, status = run.call(name)
    assert.call(!status.success? && output.include?(code), "Invalid #{name} content was not blocked: #{output}")
    assert.call(!File.exist?(File.join(destination, 'publication-manifest.json')), "Invalid #{name} generated a publication manifest")
  end

  File.write(article_path, raw)
  File.write(layout_path, '<html><body><article class="content">{{ content | replace: "unordered_map", "map" }}</article></body></html>')
  destination, output, status = run.call('template-corruption')
  assert.call(!status.success? && output.include?('build.code_changed'), "Rendered code corruption was not blocked: #{output}")
  assert.call(!File.exist?(File.join(destination, 'publication-manifest.json')), 'Corrupt output generated a publication manifest')
end

puts "Publishing build fixtures passed: #{checks} checks."
