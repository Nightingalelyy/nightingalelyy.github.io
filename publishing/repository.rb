# frozen_string_literal: true
require_relative 'validator'
require 'pathname'

module Publishing
  module Repository
    module_function

    def request(source)
      source = File.realpath(source)
      document_paths = Dir.glob(File.join(source, '_docs', '**', '*.md')).map { |path| Pathname.new(path).relative_path_from(Pathname.new(source)).to_s }
      document_paths.concat(%w[index.md 404.md admin/index.md].select { |path| File.file?(File.join(source, path)) })
      document_paths.select! { |path| Publishing.authored_path?(path) }
      documents = document_paths.sort.map do |path|
        absolute = File.join(source, path)
        raise ArgumentError, 'Article symlinks are not supported' if File.symlink?(absolute)
        raise ArgumentError, 'Article exceeds the size limit' if File.size(absolute) > MAX_DOCUMENT_BYTES
        { 'path' => path, 'rawContent' => File.read(absolute, encoding: 'UTF-8') }
      end
      config = Psych.safe_load(File.read(File.join(source, '_config.yml')), permitted_classes: [Date, Time], aliases: false)
      files = []
      visit = lambda do |directory, relative|
        Dir.children(directory).sort.each do |name|
          next if name.start_with?('.', '_') || (relative.empty? && %w[desktop publishing tests vendor].include?(name))
          absolute = File.join(directory, name)
          path = relative.empty? ? name : "#{relative}/#{name}"
          next if File.symlink?(absolute)
          if File.directory?(absolute)
            visit.call(absolute, path)
          else
            files << path if Publishing.static_path?(path)
          end
        end
      end
      visit.call(source, '')
      # Authored documents contribute their own routes in Validator. Never add
      # a deleted homepage or 404 route merely because it used to be present.
      # These other site-owned pages intentionally contain Liquid templates.
      routes = []
      routes << '/search/' if File.file?(File.join(source, 'search.html'))
      routes << '/changelog/' if File.file?(File.join(source, 'changelog.html'))
      routes << '/archive/' if File.file?(File.join(source, 'archive.html'))
      routes << '/categories/' if File.file?(File.join(source, 'categories.html'))
      routes << '/search-index.json' if File.file?(File.join(source, 'search-index.json'))
      routes << '/css/main.css' if File.file?(File.join(source, 'css/main.scss'))
      routes << '/feed.xml' if Array(config['plugins']).include?('jekyll-feed')
      routes << '/sitemap.xml' if Array(config['plugins']).include?('jekyll-sitemap')
      { 'schemaVersion' => VERSION, 'documents' => documents, 'files' => files, 'routes' => routes,
        'site' => { 'url' => config.fetch('url', 'https://nightingalelyy.github.io'), 'baseurl' => config['baseurl'].to_s } }
    end
  end
end
