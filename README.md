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
- `publishing/`: shared offline content checks and site build verification.
- `.github/workflows/pages.yml`: validated build and deployment.

Pages CMS merges configured fields into existing metadata so fields outside the
editor schema are retained. Empty template and placeholder files are excluded
from the article list. The existing `_posts`/changelog template is separate from
the article collection.

## Local development

The repository pins Jekyll 3.10.0, kramdown 2.4.0, and Rouge 3.30.0 with its
plugins in `Gemfile` and `Gemfile.lock`. CI uses Ruby 3.3 and Bundler 2.4.22.

```sh
bundle install
bundle exec jekyll serve
```

Open <http://localhost:4000>. For the same verified production build used by CI:

```sh
bundle exec ruby publishing/validate_repository.rb --build --destination _site
```

Keep the repository's Pages publishing source set to **GitHub Actions**. Legacy
branch publishing bypasses this workflow's deployment gate. The workflow emits
`publication-manifest.json` with the deployed commit and source hashes for the
desktop app to verify which article versions are live.
