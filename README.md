# Yuyang Liu's Blog

Jekyll site at <https://nightingalelyy.github.io>, published by GitHub Pages from
the root of `main`. The design is based on CloudCannon's Edition theme.

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

The article editor supports formatted text and Markdown source. Use the source
switch for existing articles with C++ code blocks or HTML such as `<sup>`. Review
the result before saving. Uploaded images are stored in `images/uploads/`.

**Save writes to `main` and starts publication.** Wait for the GitHub Pages build
to finish, then check the live page. Saved work is not a private draft: this is a
public repository. Git history keeps earlier versions of each file.

Existing filenames are kept when editing, so changing a title does not change its
URL. File renaming is disabled in the CMS to protect existing links.

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
- `css/main.scss` and `_sass/`: styles.
- `_config.yml`: Jekyll configuration.
- `.pages.yml`: CMS fields, collections, and media configuration.

Pages CMS merges configured fields into existing metadata so fields outside the
editor schema are retained. Empty template and placeholder files are excluded
from the article list. The existing `_posts`/changelog template is separate from
the article collection.

## Local development

The repository pins Jekyll 3.8.4 and its plugins in `Gemfile` and `Gemfile.lock`.
With a compatible Ruby/Bundler environment:

```sh
bundle install
bundle exec jekyll serve
```

Open <http://localhost:4000>. For a production-mode build:

```sh
JEKYLL_ENV=production bundle exec jekyll build
```

GitHub Pages uses its managed Jekyll build, so its installed versions may differ
from the historical local lockfile.
