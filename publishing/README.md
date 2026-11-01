# Publishing checks

The Mac app and website deployment use the same offline Ruby validator. The
library accepts article text and a manifest of publishable files and URLs; it
does not read files named by an article, fetch external URLs, evaluate Liquid,
or execute example code. Source text and legacy filenames are never rewritten.

`validate_request.rb` reads one JSON request on stdin:

```json
{
  "schemaVersion": 1,
  "documents": [{"path": "_docs/example.md", "rawContent": "..."}],
  "files": ["images/uploads/example.png"],
  "routes": ["/", "/example/"],
  "site": {"url": "https://nightingalelyy.github.io", "baseurl": ""}
}
```

It returns `schemaVersion`, `ok`, `issues`, and a document/code-block `summary`.
Each issue has `severity`, `path`, `line`, `code`, and `message`. Invalid content
returns a normal JSON response with `ok: false`; malformed requests exit 2.
The native app supplies the exact publication snapshot and only assets included
in that publication. Local saves are allowed while publication issues are fixed.

The validator checks metadata, calendar dates, duplicate keys/URLs, Liquid,
unclosed top-level code fences, local images, and internal page/file links.
Category names and tags share the editor limits: 80 characters per name and
at most 30 tags. Tags use a list of strings; legacy Jekyll tag strings are accepted.
Reference links and raw HTML links/images use the Markdown parser. Remote links
are not fetched, and URL fragments are not checked. A local check reflects the
Mac's current repository cache; the deployment repeats checks on the final tree.

Liquid is evaluated before Markdown on the website, even inside code. Authored
articles, homepage, 404 page, and admin page cannot contain unprotected Liquid.
For an intentional literal example, use balanced `{% raw %}` / `{% endraw %}`
blocks. Site-owned layouts, search, and changelog retain their intentional Liquid.

## Commands

```sh
ruby publishing/test_validator.rb
bundle install
bundle exec ruby publishing/test_build.rb
bundle exec ruby publishing/validate_repository.rb --build --destination _site
```

The build pins Jekyll 3.10.0, kramdown 2.4.0, GFM parser 1.1.0, Rouge 3.30.0,
Liquid 4.0.4, and the site's production plugin versions. It uses Jekyll safe mode;
the old custom `_plugins` filter remains inactive, as with branch-based Pages.
The output audit compares code text from the original source with built article
HTML, including fenced, indented, inline, and raw HTML code. It does not normalize
away whitespace differences. Fixtures prove invalid source and template-induced
code corruption cannot produce a successful publication manifest.

Article dates use the site's `Asia/Shanghai` timezone. A date-only article written
after midnight in China can publish immediately, even while the UTC build runner
is on the previous date. Fixed-clock fixtures verify this boundary and retain
Jekyll's normal future-date filtering.

Successful builds write `publication-manifest.json` containing the commit,
build time, and each published source file's SHA-256 and actual Jekyll URL.
It contains only information about published files, never local draft state.

`.github/workflows/pages.yml` runs these checks for main and desktop development
pushes, main pull requests, and manual dispatch. Only a successful main build can
upload and deploy the site. **The repository's Pages source must be set to GitHub
Actions for this workflow to replace the old branch deployment.** Adding the
workflow alone does not disable that old deployment path. A blocked deployment
keeps the previous website live; the committed source remains visible in the
public repository.

## Bundled dependencies

`vendor/` contains unmodified libraries and their licenses from the pinned
RubyGems releases listed in `vendor/SOURCES.json`. These parsers support Ruby
2.6, so the installed Mac app requires neither Node.js nor a Jekyll installation.
The complete Jekyll build runs in CI on Ruby 3.3. Dependency updates must keep the
native validator and deployment fixtures passing together.
