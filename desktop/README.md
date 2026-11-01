# Nightingale Writer for Mac

An offline editor for `Nightingalelyy/nightingalelyy.github.io`. It works with the
same Markdown files as Pages CMS and publishes to the site's `main` branch.

## Using the app

Open **Nightingale Writer** from your Applications folder. The bundled article
library is available on the first launch without an internet connection.

1. Select an article, or use **New article** to start one.
2. Edit the title, category, date, and Markdown. Changes save on this Mac.
3. Use **Preview** to check the website's fonts, title, spacing, and article width.
   Choose **Desktop** or **Mobile** to check wrapping at each size. **Split** keeps
   the editor alongside the preview; a narrow pane can scroll horizontally.
   Inserted images are also stored locally.
4. Choose **Publish** when a saved version is ready to go online.

Publishing first checks the exact saved version for invalid metadata, accidental
template expressions, missing local images, and broken internal links. Errors
show a file and line number; the draft remains on this Mac until they are fixed.
The same checks run on GitHub for changes made through Pages CMS.

Publishing queues the selected version. If GitHub cannot be reached, the queue
stays on disk and retries while the app is open. Later edits remain local until
you choose Publish again. The app does not run a background service when closed.
The article progresses through **Queued**, **Uploaded**, **Building**, and
**Live**. **Failed** links to the build details. Live is confirmed by the deployed
website's source hash, including when a newer site build still contains the same
article. New edits remain a local draft while an earlier version is building.
If status cannot be refreshed, the app preserves the last verified time.

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

The preview bundles the site's Merriweather, Open Sans, and Inconsolata fonts,
so typography works offline. Desktop shows an 800 px article at a 1200 px site
viewport, with navigation cropped away. Mobile uses a 390 px viewport. Neither
mode scales the text. The app compiles the website's own Sass when built; future
website theme changes require a new app build. Code blocks use bundled Rouge
3.30.0, matching GitHub Pages, with the same token colors and code layout. Fence
labels such as `cpp`, `c++`, `python`, and `javascript` select the language;
unlabelled or unknown languages remain plain code. Legacy `?linenums` labels
behave as they do on the website. Code highlighting works offline using macOS's
system Ruby and never runs the code in an article. Publishing still uses Jekyll,
so Jekyll-only features such as Liquid can differ from the Markdown preview.

The writing toolbar inserts Markdown formatting, links, headings, lists, quotes,
and fenced code. Select a code language to insert a new block or change the block
containing the cursor. **Outline** jumps between article headings; headings inside
code blocks are excluded. **Find** searches within the article and supports replace.
Formatting and replacement use the editor's normal undo history.

**Details → Tags** accepts comma-separated labels. Tags are saved as a YAML list,
with the same limits in Pages CMS: up to 30 tags, each at most 80 characters.
Library search includes tags, title, category, and article text.

**Manage categories** previews a rename or merge and saves the affected articles
as local drafts. Filenames and published URLs remain unchanged. Queued or
conflicted articles must be resolved first. Review and publish each changed
article when ready; earlier versions remain in history.

Choose **Blank**, **Coding note**, **Personal essay**, or a saved template when
creating an article. **Templates** can save the current article as a reusable
starting point. New drafts use the title, category, and date from the creation
form, without inheriting a template's permalink or publication flags. Custom
templates stay on this Mac and are included in backups.

Paste a copied screenshot into the editor, or choose **Paste image**. **Optimize
images** resizes large images to 2400 pixels and compresses JPEG photos; PNG
screenshots retain transparency and animations stay unchanged. Uncheck it to
keep original image bytes (clipboard TIFF is converted to web-compatible PNG).
Original files on disk are never modified. Imported images remain local until
you publish an article referencing them.

Keyboard shortcuts: **⌘N** new article, **⌘S** save locally, **⌘R** refresh,
**⇧⌘P** publish, **⌘F** find in article, **⇧⌘F** search library, **⇧⌘V** paste image.
Closing the app waits for pending local saves.

## Private draft sync between Macs

Open **Private draft sync** in the sidebar and connect
`Nightingalelyy/nightingale-writer-drafts`. Connecting verifies access without
uploading writing. Choose **Sync drafts** to send saved drafts and their local
images, and download work from another Mac. Use the same repository and GitHub
CLI account on your other Mac. GitHub CLI must be installed and signed in as
`Nightingalelyy`; the app never stores a token in draft data or its bundle.

Private draft sync has its own button. **Website sync** retains the existing
download/publish-queue behavior. **Publish** remains the action that queues an
article for the public website and makes it available through Pages CMS.
Private sync never copies publishing queues, deletion actions, credentials,
history, or app settings to another Mac. It includes the unpublished images
referenced by the shared drafts.

Sync is manual in this version. Offline editing continues normally; choose
**Sync drafts** again when connected. If both Macs changed a draft, the panel
shows both versions and lets you keep this Mac's version or use the other one.
The displaced version remains in local history. Review and publish separately.
Publishing is blocked while that article has an unresolved private-sync conflict.

The app verifies that the repository is private, personally owned by you,
writable, and has no collaborators, invitations, or Pages site before every
transfer. Drafts use a dedicated `private-drafts` branch. Concurrent uploads
require the exact previously read revision and retain that revision as their
parent, so one device cannot overwrite another device's unreviewed work.
The public website repository is rejected as a draft destination.

The private repository uses GitHub access controls; synced content is not
end-to-end encrypted. Keep it private. **Disconnect** stops synchronization and
retains local writing and repository copies. Publishing, discarding, or deleting
a local draft does not erase its private cloud copy or Git history. Private sync
is independent of backup export/import; restoring a backup never enables sync.
Snapshots are limited to 64 MB, with at most 1,000 drafts and 1,000 images,
5 MB per article and 20 MB per image. Oversized or invalid data is rejected
without replacing local writing.

## History and backups

Choose **Delete…** to remove the selected article or editable page. There are two
separate confirmations:

1. **Remove from this app** removes it from the local library, including across
   restarts and syncs. Type `REMOVE` to confirm. Local-only drafts finish here.
2. For a published item, **Also delete from GitHub and the website?** checks the
   latest repository version and any remaining links to that page. Type `DELETE`
   and confirm again to delete its source file from GitHub. This step requires
   a connection and is never queued for an automatic retry.

Cancel the second step to keep the online article unchanged. Open **Deletions**
to restore a local removal, return to the GitHub confirmation, or check whether
a confirmed deletion has reached the website. An uploaded deletion is only
marked removed from the website after its deployment is verified. A failed
build can leave the previous page online even though its source was deleted.

GitHub changes made since the review block deletion until reviewed again.
Queued publications and conflicts must be cancelled or resolved first. Links
from remaining articles must be fixed before deleting their destination.
Deleting the homepage makes the root site URL unavailable; deleting the custom
not-found page leaves the hosting service's default error page.

Deletion removes the current source file. **Git history, local recovery history,
existing backups, and shared images are retained**; this is not a history purge.
Unpublished local changes remain recoverable when you restore a local removal.

Open **Article history** in the document toolbar to compare a saved revision
with the current article. **History & recovery** in the sidebar also shows
discarded drafts. **Restore as local draft** keeps a recovery copy of the current
work and does not publish. Cancel an existing queued publication before restoring
that article. History retains up to 100 revisions per article; rapid autosaves
are grouped to avoid filling the list with every keystroke.

**Backups** exports local drafts, images, categories, queued snapshots, and history
to a JSON file. Store this file privately: it contains unpublished writing and
is not encrypted. To restore, choose the file, review its contents, and select
**Restore locally**. Existing local drafts are preserved; conflicting imported
versions appear in history. Imported queued versions become drafts or history,
and never publish automatically. A checkpoint is saved before importing.

Automatic backups keep 20 daily snapshots, refreshing today's copy at most once
every five minutes when local writing changes. Recovery operations force a
checkpoint. Backups on the same disk help with accidental changes; export a copy
to a separate private location for protection if this Mac is lost or its disk fails.

If local draft storage cannot be decoded, the app opens the cached library in
read-only recovery mode. Use **Open Backups** to select a valid backup and review
the restore. The damaged state file is preserved in a private recovery checkpoint;
editing resumes only after restoration succeeds.

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
Node.js with npm. The installed app uses the system WebKit, Git, and Ruby; it does not
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
- `native/PrivateDraftGitHubTransport.swift`: verified private-repository transfers.
- `web/`: CodeMirror editor, frontmatter forms, sanitized Markdown preview.
- `scripts/build.mjs`: bundle, compile, seed, sign, and archive.

The desktop source directory is excluded from Jekyll output.

## Roadmap

The completed milestones cover publishing checks and deployment status, draft
recovery and backups, writing tools and content management, public-site
discovery, and private draft sync between Macs.

Next is maintenance and distribution: versioned Mac releases, safe updates with
rollback, automated preview-versus-website checks, and measurements for build
time, media size, and editor/search performance.
