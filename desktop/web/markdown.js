import MarkdownIt from 'markdown-it';

// Match the site's GFM hard_wrap setting: Enter is a visible line break.
const renderer = new MarkdownIt({ html: true, linkify: true, breaks: true });

export function renderMarkdown(source) {
  return renderer.render(source);
}
