# Nightingale Writer for Mac

An offline editor for `Nightingalelyy/nightingalelyy.github.io`. It works with the
same Markdown files as Pages CMS and publishes to the site's `main` branch.

## Using the app

Open **Nightingale Writer** from your Applications folder. The bundled article
library is available on the first launch without an internet connection.

1. Select an article, or use **New article** to start one.
2. Edit the title, category, date, and Markdown. Changes save on this Mac.
3. Use the preview to check formatting. Inserted images are also stored locally.
4. Choose **Publish** when a saved version is ready to go online.

Publishing queues the selected version. If GitHub cannot be reached, the queue
stays on disk and retries while the app is open. Later edits remain local until
you choose Publish again. The app does not run a background service when closed.
Publishing to GitHub starts the site's existing GitHub Pages build; it is not an
instant deployment.

**Refresh** downloads changes made through Pages CMS. If the same article changed
online and locally, publication stops for review. The app retains the base,
queued, and remote versions. Save a resolution locally, then choose Publish.
It never force-pushes.

Use **+** beside **Categories** to add a category. Empty categories are kept on
this Mac across restarts. Select a category and choose **New article** to start
writing in it. You can also type a new category into an existing article's
Category field. A category appears on the website when an article in it is published.

The **Homepage** and **Not found page** can also be edited. Existing filenames and
unmanaged frontmatter are preserved. New article names are generated from their
date and title. External image URLs may not load offline; images inserted through
the app are available locally.

Press **Enter** for a visible line break in both the preview and the published
site. Leave a blank line to start a separate paragraph. Code blocks keep their
original spacing and line breaks.

Keyboard shortcuts: **⌘N** new article, **⌘S** save locally, **⌘R** refresh,
**⇧⌘P** publish. Closing the app waits for pending local saves.

## Local storage and credentials

Data lives in `~/Library/Application Support/Nightingale Writer/`:

- `repository.git`: managed cache of the site repository.
- `state.json`: saved local drafts, publication snapshots, and conflict state.
- `assets/`: locally inserted images.
- `history/`: recovery copies of discarded or replaced drafts.

The app uses a dedicated repository and does not modify your development
checkout. Back up this directory to preserve unpublished work. **Help → Show Local
Data** opens it in Finder.

Git uses the Mac's existing credential helper, including GitHub CLI credentials.
No token is stored in the app configuration or bundled repository. If publishing
asks for authentication, run `gh auth login` and `gh auth setup-git` in Terminal,
then retry. Git also needs your existing `user.name` and `user.email` configuration.
GitHub enforces the repository's publishing permissions.

## Build and test

Requires an Apple Silicon Mac, macOS 13 or later, Xcode Command Line Tools, and
Node.js with npm. The installed app uses the system WebKit and Git; it does not
need Node.js or a running web server.

```sh
cd desktop
npm ci
npm test
npm run build
```

Outputs:

- `dist/Nightingale Writer.app`
- `dist/Nightingale Writer.zip`

The build bundles the website's local `main` branch as an offline seed. Frontend
libraries are bundled locally. The app is signed ad hoc for local use; it is not
an Apple-notarized public distribution.

The integration tests use temporary local Git remotes. They cover persisted
offline drafts, exact queued publication snapshots, conflict handling, image
staging, path restrictions, and unrelated-file preservation. They never publish
test content to the real website.

## Implementation

- `native/Main.swift`: macOS window, menus, image picker, constrained WebKit bridge.
- `native/RepositoryStore.swift`: local state and Git publication.
- `web/`: CodeMirror editor, frontmatter forms, sanitized Markdown preview.
- `scripts/build.mjs`: bundle, compile, seed, sign, and archive.

The desktop source directory is excluded from Jekyll output.
