#!/usr/bin/env ruby
# frozen_string_literal: true
# Build a small disposable site with the real discovery templates. No production
# content is edited, and no additional plugins or HTML parser dependencies are used.
require 'tmpdir'
require 'fileutils'
require 'json'
require 'yaml'
require 'uri'
require 'rexml/document'
require 'jekyll'

checks = 0
assert = lambda do |condition, message|
  raise message unless condition
  checks += 1
end

elements = lambda { |node| REXML::XPath.match(node, './/*') }
with_class = lambda do |node, name|
  elements.call(node).select { |element| element.attributes['class'].to_s.split.include?(name) }
end
text_content = lambda do |node|
  node.children.map { |child| child.is_a?(REXML::Text) ? child.value : (child.is_a?(REXML::Element) ? text_content.call(child) : '') }.join
end
links = lambda { |node| REXML::XPath.match(node, './/a').map { |link| link.attributes['href'] } }
list_links = lambda { |node| with_class.call(node, 'discovery-list').flat_map { |list| links.call(list) } }
load_html = lambda do |destination, path|
  REXML::Document.new(File.read(File.join(destination, path)))
end

Dir.mktmpdir('nightingale-discovery-fixtures-') do |temporary|
  # Jekyll safe-mode include checks compare real paths; macOS /var is an alias.
  temporary = File.realpath(temporary)
  source = File.join(temporary, 'source')
  FileUtils.mkdir_p(File.join(source, '_docs'))
  FileUtils.mkdir_p(File.join(source, '_layouts'))
  FileUtils.mkdir_p(File.join(source, '_includes'))
  repository = File.expand_path('..', __dir__)
  %w[_layouts/home.html _includes/discovery-home.html archive.html categories.html search-index.json].each do |path|
    FileUtils.cp(File.join(repository, path), File.join(source, path))
  end
  File.write(File.join(source, '_layouts/default.html'), '<html><body><article class="content">{{ content }}</article></body></html>')
  File.write(File.join(source, '_config.yml'), {
    'url' => 'https://example.invalid', 'timezone' => 'Asia/Shanghai', 'permalink' => 'pretty',
    'markdown' => 'kramdown', 'kramdown' => { 'input' => 'GFM', 'hard_wrap' => true },
    'plugins' => [], 'personal_categories' => ['个人随笔', '阅读 & <随笔>'],
    'collections' => { 'docs' => { 'output' => true, 'permalink' => '/:path/' } },
    'defaults' => [{ 'scope' => { 'path' => '' }, 'values' => { 'layout' => 'default' } }]
  }.to_yaml)

  homepage_code = "if (a < b && b > 0) {\n  std::cout << \"<keep>&\";\n}\n"
  homepage_body = "## Editable homepage heading\n\nFirst authored line.\nSecond authored line.\n\n```cpp\n#{homepage_code}```\n\nKeep inline `a < b` too.\n"
  homepage_title = 'CMS home <title> & "author"'
  homepage_source = { 'title' => homepage_title, 'layout' => 'home', 'home' => true }.to_yaml + "---\n#{homepage_body}"
  File.write(File.join(source, 'index.md'), homepage_source)

  hostile_title = 'Title <script>evil()</script> & "quotes"'
  hostile_category = 'Graphs & <img src=x onerror=evil()>'
  fixtures = [
    ['2021-01-02-earlier.md', { 'title' => 'Earlier coding', 'date' => '2021-01-02', 'category' => 'C++' }, '/2021-01-02-earlier/'],
    ['Graph/2022-01-03-note.md', { 'title' => hostile_title, 'date' => '2022-01-03', 'category' => hostile_category, 'tags' => ['C++', '算法'] }, '/Graph/2022-01-03-note/'],
    ['2026-01-02-beijing.md', { 'title' => '北京', 'date' => '2026-01-02', 'category' => '个人随笔' }, '/2026-01-02-beijing/'],
    ['2023-04-05-essay.md', { 'title' => 'Reading notes', 'date' => '2023-04-05', 'category' => '阅读 & <随笔>', 'permalink' => '/custom-essay/' }, '/custom-essay/'],
    ['2025-01-01-not-indexed.md', { 'title' => 'Visible outside search', 'date' => '2025-01-01', 'category' => '个人随笔', 'excluded_in_search' => true }, '/2025-01-01-not-indexed/'],
    ['undated.md', { 'title' => 'Undated coding', 'category' => 'Algorithms' }, '/undated/'],
    ['2031-01-01-future.md', { 'title' => 'Future article', 'date' => '2031-01-01', 'category' => 'C# / ?' }, '/2031-01-01-future/'],
    ['2024-01-01-private.md', { 'title' => 'Unpublished article', 'date' => '2024-01-01', 'category' => 'C%2B%2B', 'published' => false }, '/2024-01-01-private/']
  ]
  fixtures.each do |path, metadata, _url|
    target = File.join(source, '_docs', path)
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, metadata.to_yaml + "---\n\nFixture body with 北京 and algorithm notes.\n")
  end
  File.write(File.join(source, '_docs/Graph/1.md'), '')
  expected_urls = fixtures.map { |path, _metadata, url| ["_docs/#{path}", url] }.to_h
  stable_category_ids = nil
  last_configuration = nil

  [
    ['public root', false, false, ''],
    ['public subpath', false, false, '/preview'],
    ['future enabled', true, false, '/preview'],
    ['unpublished enabled', false, true, '/preview'],
    ['both enabled', true, true, '/preview']
  ].each_with_index do |(label, future, unpublished, baseurl), index|
    destination = File.join(temporary, "build-#{index}")
    configuration = Jekyll.configuration(
      'source' => source, 'destination' => destination, 'quiet' => true, 'safe' => true,
      'disable_disk_cache' => true, 'future' => future, 'unpublished' => unpublished,
      'baseurl' => baseurl, 'time' => Time.new(2026, 11, 2, 12, 0, 0, '+08:00')
    )
    site = Jekyll::Site.new(configuration)
    site.process
    published = site.collections['docs'].docs.select(&:write?)
    published_urls = published.map { |document| baseurl + document.url }
    assert.call(published.size == 6 + (future ? 1 : 0) + (unpublished ? 1 : 0), "#{label}: unexpected Jekyll publication count")
    published.each do |document|
      assert.call(document.url == expected_urls[document.relative_path], "#{label}: article URL changed for #{document.relative_path}")
      assert.call(File.file?(document.destination(destination)), "#{label}: expected article was not written")
    end

    archive_urls = nil
    [['archive', 'archive-year'], ['categories', 'category-section']].each do |page, section_class|
      html = load_html.call(destination, "#{page}/index.html")
      module_node = with_class.call(html, 'site-discovery').first
      assert.call(module_node, "#{label}: #{page} has no discovery content")
      actual = list_links.call(module_node)
      assert.call(actual.sort == published_urls.sort, "#{label}: #{page} must list every written article exactly once")
      sections = with_class.call(module_node, section_class)
      total = 0
      sections.each do |section|
        count = text_content.call(with_class.call(section, 'discovery-count').first).to_i
        assert.call(count == list_links.call(section).size, "#{label}: #{page} section count differs from its articles")
        total += count
      end
      assert.call(total == published.size, "#{label}: #{page} total differs from published article count")
      assert.call(links.call(module_node).all? { |href| !href.start_with?('/') || href.start_with?(baseurl + '/') }, "#{label}: #{page} links escape the configured baseurl")
      assert.call(REXML::XPath.match(module_node, './/script | .//img').empty?, "#{label}: title/category text created HTML elements")
      archive_urls = actual if page == 'archive'
      if page == 'categories'
        headings = sections.map { |section| REXML::XPath.first(section, './div/h2') }
        ids = headings.map { |heading| heading.attributes['id'] }
        category_nav = elements.call(module_node).find { |element| element.attributes['aria-label'] == 'Jump to a category' }
        targets = links.call(category_nav).map { |href| URI::DEFAULT_PARSER.unescape(href.sub(/\A#/, '')) }
        assert.call(ids.uniq.size == ids.size && ids.none? { |id| id.match?(/\s/) }, "#{label}: category fragment IDs collide or contain whitespace")
        assert.call(targets == ids, "#{label}: encoded category links do not target their exact HTML IDs")
        stable_category_ids = headings.map { |heading| [heading.texts.map(&:value).join.strip, heading.attributes['id']] }.to_h
        assert.call(text_content.call(module_node).include?(hostile_category), "#{label}: category label was lost or double escaped")
        assert.call(sections.size == published.map { |document| document.data['category'] }.uniq.size, "#{label}: category groups are incomplete")
      end
    end
    date_by_url = published.map { |document| [baseurl + document.url, document.date] }.to_h
    dates = archive_urls.map { |url| date_by_url.fetch(url) }
    assert.call(dates == dates.sort.reverse, "#{label}: archive is not sorted newest first across year groups")

    home = load_html.call(destination, 'index.html')
    module_node = with_class.call(home, 'site-discovery').first
    authored = with_class.call(home, 'home-authored-content').first
    introduction = with_class.call(home, 'home-introduction').first
    assert.call(text_content.call(REXML::XPath.first(introduction, './h1')) == homepage_title, "#{label}: editable homepage title does not control its visible heading")
    assert.call(authored && text_content.call(authored).include?('Editable homepage heading'), "#{label}: CMS homepage prose was lost")
    assert.call(REXML::XPath.match(authored, './/pre/code').map { |code| text_content.call(code) } == [homepage_code], "#{label}: authored homepage code changed")
    assert.call(REXML::XPath.match(authored, './/code').any? { |code| text_content.call(code) == 'a < b' }, "#{label}: authored inline code changed")
    assert.call(REXML::XPath.match(home, '//article').size == 1, "#{label}: nested article markup breaks the authored-content audit")
    assert.call(REXML::XPath.match(module_node, './/code | .//script | .//img').empty?, "#{label}: discovery modules introduced code or unescaped markup")
    cards = with_class.call(module_node, 'discovery-card')
    newest_urls = published.sort_by(&:date).reverse.first(6).map { |document| baseurl + document.url }
    assert.call(cards.flat_map { |card| links.call(card) } == newest_urls, "#{label}: recent writing is not the six newest published articles")
    personal = elements.call(module_node).find { |element| element.attributes['aria-labelledby'] == 'personal-essays' }
    coding = elements.call(module_node).find { |element| element.attributes['aria-labelledby'] == 'coding-notes' }
    assert.call(personal && coding, "#{label}: homepage does not separate essays and coding notes")
    personal_docs, coding_docs = published.partition { |document| configuration['personal_categories'].include?(document.data['category']) }
    [[personal, personal_docs], [coding, coding_docs]].each do |section, documents|
      assert.call(text_content.call(with_class.call(section, 'discovery-count').first).to_i == documents.size, "#{label}: homepage section count is wrong")
      expected = documents.sort_by(&:date).reverse.first(5).map { |document| baseurl + document.url }
      assert.call(list_links.call(section) == expected, "#{label}: homepage section includes the wrong articles")
    end
    assert.call(links.call(module_node).all? { |href| !href.start_with?('/') || href.start_with?(baseurl + '/') }, "#{label}: homepage links escape the configured baseurl")

    search = JSON.parse(File.read(File.join(destination, 'search-index.json')))
    searchable = published.reject { |document| document.data['excluded_in_search'] }
    assert.call(search.map { |entry| entry.fetch('url') }.sort == searchable.map { |document| baseurl + document.url }.sort, "#{label}: search index leaks hidden articles or omits published searchable articles")
    hostile_entry = search.find { |entry| entry['url'] == baseurl + '/Graph/2022-01-03-note/' }
    assert.call(hostile_entry && hostile_entry['title'] == hostile_title && hostile_entry['category'] == hostile_category, "#{label}: JSON title/category escaping changed the original text")
    assert.call(hostile_entry['tags'] == ['C++', '算法'] && hostile_entry['body'].include?('北京'), "#{label}: search index lost tags or Chinese body text")
    assert.call(File.read(File.join(source, 'index.md')) == homepage_source, "#{label}: discovery build altered the editable homepage source")
    last_configuration = configuration
  end

  # Existing category URLs must remain stable when an earlier-sorting category is added.
  inserted = { 'title' => 'New category article', 'date' => '2020-01-01', 'category' => 'A category inserted first' }
  File.write(File.join(source, '_docs/2020-01-01-added.md'), inserted.to_yaml + "---\nNew category.\n")
  insertion_config = last_configuration.merge('destination' => File.join(temporary, 'inserted-category'))
  insertion_site = Jekyll::Site.new(insertion_config)
  insertion_site.process
  categories = load_html.call(insertion_site.dest, 'categories/index.html')
  new_headings = with_class.call(categories, 'category-section').map { |section| REXML::XPath.first(section, './div/h2') }
  new_ids = new_headings.map { |heading| [heading.texts.map(&:value).join.strip, heading.attributes['id']] }.to_h
  assert.call(new_ids.size == stable_category_ids.size + 1, 'Inserting a category omitted or duplicated an existing category')
  assert.call(new_ids.values.uniq.size == new_ids.size, 'Inserting a category produced duplicate fragment IDs')
  stable_category_ids.each do |name, id|
    assert.call(new_ids[name] == id, "Existing category fragment changed after insertion: #{name}")
  end
end

puts "Discovery fixture checks passed: #{checks} assertions (Jekyll #{Jekyll::VERSION}, Liquid #{Liquid::VERSION})."
