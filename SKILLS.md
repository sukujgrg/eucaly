# Lyrics Authoring Skill

Use this guide when creating, cleaning up, importing, or reviewing lyrics files for eucaly.
Lyrics files are plain UTF-8 text files, normally saved as `.txt`.

## Authoring Rules

- Author lyrics as projection-ready text, not as prose documentation.
- Keep one song per file unless the user explicitly wants a medley file.
- Browsing or editing lyrics should only affect Preview until the user explicitly loads Preview to Current.
- Do not invent copyright, license, CCLI song numbers, CCLI license numbers, authors, translators, or publishers.
- Preserve copyright and licensing metadata from trusted sources, but keep it out of projected lyric slides unless the user asks for a copyright slide.

## Supported Slide Schemes

### Plain blank-line lyrics

Use this for simple songs with no section labels. Each non-empty block becomes one slide.

```text
Come, Thou Fount of every blessing
Tune my heart to sing Thy grace

Streams of mercy, never ceasing
Call for songs of loudest praise
```

### Explicit slide breaks

Use `---` when exact slide boundaries matter. The formatter also normalizes three or more dashes to `---`.

```text
Holy, holy, holy
Lord God Almighty
---
Early in the morning
Our song shall rise to Thee
```

### Sectioned lyrics

Use supported headings to split slides and label thumbnails.

Supported primary headings:

- `Intro`
- `Verse`
- `Chorus`
- `Pre-Chorus`
- `Post-Chorus`
- `Bridge`
- `Instrumental`
- `Vamp`
- `Coda`
- `Ending`
- `Outro`
- `Tag`

Numbers are supported after headings, such as `Verse 1`, `Verse 2`, `Bridge 2`, and `Pre-Chorus 1`.

```text
Amazing Grace

Verse 1
Amazing grace! how sweet the sound
That saved a wretch like me

Chorus
Praise God, praise God
His mercy still remains
```

### Header variants and imports

The parser accepts common import styles:

- `Verse 1:`
- `[Verse 1]`
- `[ Chorus ]`
- `[Chorus:]`
- uppercase/lowercase variants

Recognized aliases:

- `Vers` and `Strophe` -> `Verse`
- `Refrain` and `Hook` -> `Chorus`
- `Pre`, `Prechorus`, and `Pre Chorus` -> `Pre-Chorus`

Prefer canonical headings when authoring new files.

### Multilingual and companion text

Use these markers inside a slide:

- `Meaning`
- `Translation`
- `Transliteration`

The renderer orders slide text as main lyrics, then Meaning, then Translation, then Transliteration, even if the input order differs. `Transalation` is accepted as a typo alias for `Translation`, but do not write new files that way.

```text
Verse 1
Prabhu tapai mahan hunuhunchha

Transliteration
Prabhu tapai mahan hunuhunchha

Meaning
Lord, You are great

Chorus
Hallelujah, hallelujah
```

### Lower-third projection

For lower-third use, author shorter slides. Keep each slide to the two or three lines intended to be visible together, then rely on the app lyrics position setting for bottom placement.

```text
Verse 1
Amazing grace! how sweet the sound
That saved a wretch like me
---
I once was lost, but now am found
Was blind, but now I see
```

### Medleys and repeated sections

For medleys, keep boundaries explicit and readable. Use title lines or section labels only if they should help operators. Do not rely on hidden comments because the parser treats ordinary non-empty text as lyrics.

```text
Song One

Verse 1
First song lyric

Chorus
First song chorus
---
Song Two

Verse 1
Second song lyric
```

If a repeated chorus must appear multiple times in the run order, duplicate the text where it belongs. eucaly does not use chord-chart style section references like `Chorus x2` as navigation commands.

## Copyright and Licensing Metadata

### General rules

- Copyright law and licensing are user responsibilities. As an agent, preserve provided metadata and avoid fabricating rights information.
- Do not remove copyright metadata from imported lyrics unless the user specifically asks for a projection-only copy.
- Do not include chord charts, commercial sheet music, or lyrics from unlicensed sources when the user has not provided the text.
- If lyrics are public domain, traditional, original, or licensed under a custom agreement, label that only when the user or source explicitly provides that status.
- For translations or transliterations, preserve translator and source metadata when provided.
- For scripture-based songs, preserve translation/version attribution when provided by the source.

### CCLI/SongSelect exports

Direct CCLI/SongSelect exports are supported. Common trailing metadata is parsed and stripped from projected slides when it appears as a dense metadata block at the end.

Preferred trailer shape:

```text
Verse
Line to project

Author Name
CCLI Song #1234567
© 2026 Publisher Name
For use solely with the SongSelect® Terms of Use. All rights reserved. www.ccli.com
CCLI License #7654321
```

The parser recognizes:

- `CCLI Song #...`
- `CCLI License #...`
- copyright lines beginning with `©`
- SongSelect rights lines containing terms-of-use, CCLI, or `ccli.com`
- the author line immediately before the CCLI song number

Keep this metadata at the end of the file. For CCLI/SongSelect trailers, the author line immediately before `CCLI Song #...` is mandatory in practice: the parser removes the nearest non-empty non-heading line before the CCLI song number as the author line. If no real author line is present, the last lyric line before the trailer can be stripped from the final slide. If the source does not provide an author, insert an explicit placeholder such as `Author unknown` rather than letting a lyric line sit directly above `CCLI Song #...`.

If CCLI-looking text appears in the middle of a song, the parser may treat it as lyric content unless it forms a trailer-like metadata block.

### Public domain and traditional songs

Use a simple metadata trailer only when the status is known.

```text
Amazing Grace

Verse 1
Amazing grace! how sweet the sound
That saved a wretch like me

Public Domain
Words: John Newton
```

This is human-readable metadata only. It is not currently parsed as CCLI metadata unless it uses recognized CCLI/SongSelect lines.

### Original or in-house songs

Preserve authorship and ownership clearly.

```text
Song Title

Verse 1
Original lyric text

Written by Person Name
© 2026 Church or Rights Holder
Used by permission.
```

If the user asks for a projected copyright slide, make it explicit with separators so it becomes its own slide.

```text
---
© 2026 Church or Rights Holder
Used by permission.
```

## Formatting Standards

- Prefer a standalone title as the first non-empty line, followed by a blank line or a section heading.
- Keep line lengths projection-friendly. Split dense paragraphs into shorter lyric lines.
- Avoid trailing spaces.
- Use one blank line between slides or sections unless using `---`.
- Use canonical headings for newly authored lyrics.
- Keep copyright/license metadata at the bottom.
- Do not add Markdown bullets, code fences, comments, chord symbols, or stage notes unless the user explicitly wants them projected.

## Review Checklist

- The file is plain text and one song or intentional medley.
- Slide boundaries are clear by blank lines, headings, or `---`.
- Headings are supported by `LyricsSectionCatalog`.
- Repeated choruses are duplicated where needed for projection order.
- Companion text uses `Meaning`, `Translation`, or `Transliteration`.
- Copyright and license metadata is preserved, sourced, and not invented.
- CCLI/SongSelect metadata, when present, is at the end of the file.
- No operator-only notes will accidentally project as lyrics.
