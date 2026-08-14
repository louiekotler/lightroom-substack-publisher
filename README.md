# lightroom-substack-publisher

Select photos in Lightroom Classic, fill in a title, and export them as a
Substack post.

A Lightroom **export destination**: choose *Substack Post* in the Export dialog,
type a title and subtitle, and the whole selection becomes one post — photos in
the order they were taken, each captioned with its date.

```
Lightroom  ──►  substack-post  ──►  Substack
 (renders)      (orders, captions,
                 uploads, posts)
```

## Why the pieces are separate

Lightroom renders; [substack-automation](https://github.com/louiekotler/substack-automation)
talks to Substack. The plug-in is Lua glue that hands one to the other, so
neither has to know how the other works — and the command-line tool stays usable
on its own, for photos that never went through Lightroom.

## Why an export, not a publish service

A Substack post is a one-time push. Lightroom's publish services exist to keep a
collection *in sync* with somewhere else — tracking which photos changed, which
need re-publishing, which were removed. None of that means anything to a post
that has already gone out, and every post would leave a stale collection behind.

An export is the honest shape: you pick photos, they become a post, and that's
the end of it.

## Install

Requires Lightroom Classic 10 or later and
[substack-automation](https://github.com/louiekotler/substack-automation), set up
and working from the command line first — including the password sign-in it
needs, which Substack does not enable by default.

Copy `lightroom/SubstackPost.lrplugin` somewhere Lightroom can see it (for
example `~/Pictures/Lightroom Plugins/`), then add it in Lightroom via
**File ▸ Plug-in Manager ▸ Add**.

In the Plug-in Manager, fill in:

| | |
|---|---|
| **substack-post path** | full path to the executable, e.g. `/path/to/substack-automation/.venv/bin/substack-post` |
| **.env file** | full path to the `.env` holding your Substack credentials |
| **Notify contacts** | optional; only if you use *Notify contacts* |

Press **Test**. It signs in and reports your publication, without posting
anything. Your credentials stay in the `.env` file — Lightroom never sees them.

## Making a post

Select photos, then **File ▸ Export…** and choose **Substack Post** as the
destination.

| Option | |
|---|---|
| **Title** | required; cleared each time, so no post inherits the last one's headline |
| **Subtitle** | optional |
| **Draft / Publish** | draft by default |
| **Email subscribers** | publish only; on by default, matching Substack |
| **Notify contacts** | publish only; texts your contact list via macOS Messages once the post is live |
| **Sign-off**, **Caption format** | optional overrides; blank means `substack-post`'s own defaults |

Choosing **Publish** asks for confirmation first, naming your publication, the
number of photos, and whether subscribers will be emailed. **Publishing cannot
be undone** — a draft can be edited or thrown away in Substack, a published post
cannot be unsent.

When it's done, the plug-in shows the post's URL and offers to open it.

## Order and captions come from EXIF

Photos are ordered by when they were taken, and each caption is that date. Both
are read out of the exported file's EXIF, so **the Metadata section of the
Export dialog matters**: *Copyright Only* strips the capture time, and the post
comes out unordered and uncaptioned. The plug-in warns you in the dialog when
the current setting would do that.

*Remove Location Info* is left under your control — a post is public, and
whether it carries the coordinates of your house is your decision, not this
plug-in's.

Photos with no capture time at all go last, in the order you selected them.

## How the plug-in calls substack-post

Everything the Lua side assumes, in case you want to point it at a fork or a
different publisher.

```
<command> <photo-dir> --title <t> [--subtitle <s>]
                      [--publish] [--no-email] [--notify] [--notify-list <p>]
                      [--signoff <text>] [--caption-format <fmt>]
                      --env-file <path> --yes --format kv
```

- `<photo-dir>` is a temporary folder holding this post's photos and nothing
  else. The plug-in creates it, and deletes it however the export ends.
- `--yes` is always passed: Lightroom gives the subprocess no terminal, so the
  tool must never prompt. The confirmation you saw was the plug-in's own.
- `--format kv` asks for `key=value` lines on stdout. The plug-in needs `status`
  (`draft` or `published`) and `url`; `photos`, `notified_ok` and
  `notified_failed` fill in the result dialog. Anything on stderr is ignored.
- `<command> --check --env-file <path> --format kv` verifies the configuration
  without posting, and answers with `ok=1`, `publication`, and `user`. That is
  what **Test** calls, and what runs before a publish.
- A failure means exiting non-zero and printing `error: <message>`. That message
  is shown to the user verbatim, so it has to read as a sentence.

`kv` rather than JSON so that parsing takes one `string.match`, which keeps a
third-party JSON library out of the plug-in bundle.

## Tests

The Lua that builds those commands is tested against a stand-in for
`substack-post`, through a real shell — so the quoting is genuinely exercised.
Needs `lua` on your PATH; nothing contacts Substack.

```bash
lua tests/test_substack_cli.lua
```

## License

MIT.
