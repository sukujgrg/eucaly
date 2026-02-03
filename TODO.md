# TODO

- Add optional media compatibility validation (AVAsset.isPlayable / track inspection) with async timeout and caching to avoid slowing thumbnails or playback.
- Add typo-tolerant search suggestions for library text search (`Did you mean ...?`) in a safe no-results flow:
  build a lightweight term-frequency index during reindex, propose nearest terms (trigram/edit-distance), and let user explicitly accept suggested query.
- Decide recursive behavior for `Root` (TBD):
  current behavior lists files recursively and also indexes recursively; evaluate whether list should be non-recursive while keeping recursive search indexing.
