# Yuyang Liu's Blog

Jekyll site at <https://nightingalelyy.github.io>, built from `main` and published
by the **Publish website** GitHub Actions workflow after validation succeeds.
The design is based on CloudCannon's Edition theme.

## Edit the site

Open <https://nightingalelyy.github.io/admin/> and follow **Open Pages CMS**.
Sign in with the `Nightingalelyy` GitHub account.

- **Articles:** edit existing write-ups or select **New** to create an article.
- **Homepage:** edit the homepage title and content.
- **Not found page:** edit the message displayed for missing pages.
- **Site settings:** edit the site title and description.
- **Images:** upload images to use in articles and pages.

For a new article, enter a title, date, category, and body. The editor generates a
date-based filename from the title when you save. Articles default to the **Articles** category; use an existing
category for a LeetCode write-up. The category determines the navigation section,
and the order field sorts articles within that section. Lower numbers appear first.
Optional **Tags** help find related writing. Use up to 30 labels of at most 80
characters each; Pages CMS and Nightingale Writer save these as a YAML list.

The article editor supports formatted text and Markdown source. Use the source
switch for existing articles with C++ code blocks or HTML such as `<sup>`. Review
the result before saving. Uploaded images are stored in `images/uploads/`.

**Save writes to `main` and starts the publishing checks.** The workflow checks
metadata, template expressions, local image/link targets, and whether code text
survives the full site build. A failed check keeps the previous website online;
open the failed workflow for file names and line numbers, correct the source,
and save again. A GitHub commit is not proof that its website deployment is live.
Saved CMS work is public in this repository, even if deployment fails. Git
history keeps earlier versions of each file. Use Nightingale Writer for private
offline drafts.

Existing filenames are kept when editing, so changing a title does not change its
URL. File renaming is disabled in the CMS to protect existing links.

## Browse the site

The homepage shows recent writing plus Coding notes and Personal essays. Its
title and introductory content still come from the editable homepage file.
In **Site settings → Personal essay categories**, list the exact category names
that belong to personal writing; other categories appear under Coding notes.

**Archive** lists all published articles by year. **Categories** groups the same
articles with stable section links. Publishing a new article updates these views
and the search index automatically, without changing existing article URLs.
Future and unpublished articles follow Jekyll's publication settings.

**Search** matches English and Chinese text across titles, categories, tags, and
article content. Problem numbers such as `525` prioritize the matching title.
Search runs locally in the browser from a static JSON index. The query stays in
the page URL for sharing; there is no third-party search service.

The mobile menu supports keyboard focus, Escape, and outside-click dismissal.
Article headings have section links, and code blocks have a **Copy** button that
preserves their original text. Article typography and width match the existing
Nightingale Writer preview.

## Pages CMS connection and access

The Pages CMS GitHub App should use **Only select repositories**, with only
`nightingalelyy.github.io` selected. Open this repository on `main` in Pages CMS;
the editor reads `.pages.yml` from that branch.

Publishing access is controlled by GitHub repository write permissions and Pages
CMS collaborator invitations. For an owner-only setup, keep GitHub collaborators
and pending invitations empty and do not invite CMS collaborators. The public
Admin link does not grant editing access. No password or access token is stored
in this repository.

## Content and configuration

- `_docs/`: articles, organized into category folders.
- `index.md`: homepage.
- `_layouts/default.html`: shared page and navigation layout.
- `_layouts/home.html` and `_includes/discovery-home.html`: editable homepage plus generated article lists.
- `archive.html` and `categories.html`: public browsing pages.
- `search-index.json` and `scripts/search*.js`: static Chinese/English search.
- `scripts/site.js`: mobile navigation, heading links, and code copying.
- `css/main.scss` and `_sass/`: styles.
- `_config.yml`: Jekyll configuration.
- `.pages.yml`: CMS fields, collections, and media configuration.
- `publishing/`: shared offline content checks and site build verification.
- `.github/workflows/pages.yml`: validated build and deployment.

Pages CMS merges configured fields into existing metadata so fields outside the
editor schema are retained. Empty template and placeholder files are excluded
from the article list. The existing `_posts`/changelog template is separate from
the article collection.

## Local development

The repository pins Jekyll 3.10.0, kramdown 2.4.0, and Rouge 3.30.0 with its
plugins in `Gemfile` and `Gemfile.lock`. CI uses Ruby 3.3, Bundler 2.4.22, and Node 24.

```sh
bundle install
bundle exec jekyll serve
```

Open <http://localhost:4000>. For the same verified production build used by CI:

```sh
bundle exec ruby publishing/validate_repository.rb --build --destination _site
node --test tests/*.test.mjs
bundle exec ruby publishing/test_discovery.rb
```

Keep the repository's Pages publishing source set to **GitHub Actions**. Legacy
branch publishing bypasses this workflow's deployment gate. The workflow emits
`publication-manifest.json` with the deployed commit and source hashes for the
desktop app to verify which article versions are live.
