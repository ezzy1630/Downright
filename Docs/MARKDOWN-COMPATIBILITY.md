# Markdown compatibility

Downright treats the file's exact source as authoritative. Its portable
baseline is CommonMark; GitHub-flavored Markdown is the default compatibility
target for tables, task lists, strikethrough, autolinks, and ordinary README
HTML. The Contents / Outline compatibility view can compare the open document
with GitHub, CommonMark, and other built-in targets without changing the file.

Downright extensions include math, Mermaid, callouts, wikilinks, front matter,
footnotes, path tokens, and additional document extensions. They are ordinary
source syntax, never a required proprietary dialect. Unsupported targets are
reported with exact ranges and reversible proposals where a safe conversion is
available; Downright does not silently normalize an extension away.

## Math

Math is typeset natively, with no WebView or network access. Inline math uses
`$…$` or `\(…\)`; display math uses `$$…$$`, `\[…\]`, or a fenced block tagged
`math`, `latex`, `tex`, or `katex`. A single `$` must sit flush against its
content and is ignored around plain amounts, so prices and shell variables stay
prose.

Most LaTeX written for KaTeX, MathJax, Typora, and Obsidian renders, including
`align`, `equation`, `gathered`, `cases`, matrix and `array` blocks, `\dfrac`,
`\operatorname`, `\boldsymbol`, `\not`, and typed Unicode symbols. Text inside
`\text{}` may use any script, including Chinese, Japanese, and Korean. A few
decorations render approximately: `\big` delimiters keep their normal size,
`\boxed` drops its frame, and `\tag{n}` appears as "(n)" at the end of the
formula. `\overset`, `\underset`, `\stackrel`, `\xrightarrow`, `\overbrace`,
`\underbrace`, `\phantom`, and `\hspace` are not supported yet; a formula that
uses them shows its source text instead of rendering incorrectly.

## Raw HTML

Document mode natively presents a conservative, non-executing subset commonly
found in README files: aligned paragraphs, headings, strong and emphasized
text, links, local images, line breaks, details and summaries, and basic table
structure. The original tags remain in source and reappear at the caret for
editing.

Unknown tags, malformed markup, event attributes, executable URLs, and other
unsafe input remain inert literal source. Remote image tags are never fetched;
they remain visibly preserved while safe surrounding presentation can still be
rendered. HTML export applies its own escaping rules and never treats raw file
HTML as trusted output.
