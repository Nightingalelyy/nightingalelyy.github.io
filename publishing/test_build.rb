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
    timezone: Etc/UTC
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
  # Site infrastructure remains even when every authored document is removed.
  File.write(File.join(source, 'robots.txt'), "User-agent: *\nAllow: /\n")
  layout_path = File.join(source, '_layouts', 'default.html')
  File.write(layout_path, '<html><body><article class="content">{{ content }}</article></body></html>')
  path = '_docs/example.md'
  raw = <<~MARKDOWN
    ---
    title: Fixture
    category: Notes
    date: 2020-01-02
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
    'metadata' => [raw.sub('2020-01-02', '2026-02-30'), 'metadata.date']
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

  # At 02:14 in China it is still the previous calendar day in UTC. A date-only
  # frontmatter value must be interpreted in the site's authoring timezone.
  File.write(layout_path, '<html><body><article class="content">{{ content }}</article></body></html>')
  boundary_raw = raw.sub('2020-01-02', '2026-11-02')
  File.write(article_path, boundary_raw)
  config_path = File.join(source, '_config.yml')
  boundary_config = File.read(config_path) + "\ntime: '2026-11-01T18:14:00Z'\n"
  File.write(config_path, boundary_config)
  destination, output, status = run.call('utc-date-boundary')
  assert.call(!status.success? && output.include?('build.missing'), "UTC boundary did not reproduce future filtering: #{output}")
  assert.call(!File.exist?(File.join(destination, 'publication-manifest.json')), 'Hidden future article produced a success manifest')

  File.write(config_path, boundary_config.sub('timezone: Etc/UTC', 'timezone: Asia/Shanghai'))
  destination, output, status = run.call('shanghai-date-boundary')
  assert.call(status.success?, "An article dated today in China was hidden: #{output}")
  manifest = JSON.parse(File.read(File.join(destination, 'publication-manifest.json')))
  assert.call(manifest['articles'][path]['sha256'] == Digest::SHA256.hexdigest(boundary_raw), 'Boundary publication did not identify exact source')

  File.write(article_path, boundary_raw.sub('2026-11-02', '2026-11-03'))
  destination, output, status = run.call('genuine-future-date')
  assert.call(!status.success? && output.include?('build.missing'), "A genuine future date unexpectedly published: #{output}")

  # Delete only files in this isolated fixture. Current source inventory is not
  # a permanent minimum: an intentional deletion must be allowed to deploy.
  File.write(config_path, boundary_config.sub("\ntime: '2026-11-01T18:14:00Z'\n", ''))
  File.write(article_path, raw)
  index_path = File.join(source, 'index.md')
  not_found_path = File.join(source, '404.md')
  home = "---\ntitle: Home\n---\nHome.\n"
  not_found = "---\ntitle: Not found\npermalink: /404.html\n---\nNot found.\n"
  File.write(index_path, home)
  File.write(not_found_path, not_found)
  destination, output, status = run.call('article-delete-lifecycle')
  assert.call(status.success? && File.file?(File.join(destination, 'example', 'index.html')), "Article deletion fixture did not build: #{output}")
  File.delete(article_path)
  File.write(index_path, home + "\n[Old article](/example/)\n")
  destination, output, status = run.call('article-delete-linked')
  assert.call(!status.success? && output.include?('link.missing'), "An incoming article link did not block deletion: #{output}")
  assert.call(!File.exist?(File.join(destination, 'publication-manifest.json')), 'Blocked article deletion produced a success manifest')
  File.write(index_path, home)
  destination, output, status = run.call('article-delete-lifecycle')
  assert.call(status.success?, "An unreferenced article could not be deleted: #{output}")
  manifest = JSON.parse(File.read(File.join(destination, 'publication-manifest.json')))
  assert.call(!manifest['articles'].key?(path), 'Deleted article remained in publication manifest')
  assert.call(!File.exist?(File.join(destination, 'example', 'index.html')), 'Deleted article output survived the next build')

  File.delete(index_path)
  File.write(not_found_path, not_found + "\n[Home](/)\n")
  destination, output, status = run.call('homepage-delete-linked')
  assert.call(!status.success? && output.include?('link.missing'), "A dangling homepage link passed validation: #{output}")
  File.write(not_found_path, not_found)
  destination, output, status = run.call('homepage-delete')
  assert.call(status.success?, "Homepage deletion did not build: #{output}")
  manifest = JSON.parse(File.read(File.join(destination, 'publication-manifest.json')))
  assert.call(!manifest['articles'].key?('index.md') && !File.exist?(File.join(destination, 'index.html')), 'Deleted homepage remained in output or manifest')

  File.write(index_path, home + "\n[Not found](/404.html)\n")
  File.delete(not_found_path)
  destination, output, status = run.call('not-found-delete-linked')
  assert.call(!status.success? && output.include?('link.missing'), "A dangling custom 404 link passed validation: #{output}")
  File.write(index_path, home)
  destination, output, status = run.call('not-found-delete')
  assert.call(status.success?, "Custom 404 deletion did not build: #{output}")
  manifest = JSON.parse(File.read(File.join(destination, 'publication-manifest.json')))
  assert.call(!manifest['articles'].key?('404.md') && !File.exist?(File.join(destination, '404.html')), 'Deleted custom 404 remained in output or manifest')

  File.delete(index_path)
  destination, output, status = run.call('no-authored-documents')
  assert.call(status.success?, "An empty authored collection cannot build: #{output}")
  manifest = JSON.parse(File.read(File.join(destination, 'publication-manifest.json')))
  assert.call(manifest['articles'].empty?, 'Empty authored collection produced unexpected manifest records')
end

puts "Publishing build fixtures passed: #{checks} checks."
