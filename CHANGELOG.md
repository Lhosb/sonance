# Changelog

## Release tag provenance

Sonance releases use annotated tags. The tag object and the commit it peels to
are distinct Git objects:

| Release | Tag object | Release commit | Relationship to `main` |
| --- | --- | --- | --- |
| `v0.1.0` | `f5c163bdfa4256210afd889cb70de86f8248cc4c` | `5360f8fd8609eae39edb5dfab8a07f6439a0b137` | The release commit is an ancestor of `main`. |
| `v0.2.0` | `0ac6e6bd1289d4a27edb9c1a40ae1427f6b66397` | `848f6894a6022b5a32ae2b6b0c6898ac84986fa0` | The release commit is not an ancestor of `main`, and no commit on `main` reproduces its tree. |
| `v0.3.0` | `cf8e613e9a9b3b3b576df4e20e61e63ec25dffe6` | `66393972a8b57ee116afec0fbeb879a0c410dbca` | The release commit is not an ancestor of `main`; its tree matches `7aabc963fe1770882ea6bf1d6df2a0da341e1cc6` on `main`. |
| `v0.4.0` | `7428f026f7acd262b0d0880498faf59d96bf8795` | `1115824c8fec533037c35aaf4ec091bb42ac63df` | The release commit is an ancestor of `main`. |

## 0.4.0

This is an additive release:

- Descriptor values implement `Value#as_json` and `Value#to_json`, producing
  real JSON values instead of the `Object#to_json` inspect form.
- Subprocess stdout and stderr reads are bounded by `MAX_STREAM_BYTES`.
- The Python and numpy stack is pinned, and `NOTICE` records licence and source
  URIs.
- The canonical CPU gate matches CPU model names case-insensitively, producing
  consistent golden-gate results across runners with identical trees.

## 0.3.0

This is a breaking release:

- The gem is now `sonance`, the Ruby namespace is `Sonance`, and the executable
  is `sonance`. There is no compatibility namespace shim.
- Descriptor ids are producer-qualified:

  | Previous id | 0.3.0 id |
  | --- | --- |
  | `valence_emomusic` | `valence_emomusic` |
  | `arousal_emomusic` | `arousal_emomusic` |
  | `danceability` | `danceability_musicnn` |
  | `mood_acoustic` | `mood_acoustic_musicnn` |
  | `mood_relaxed` | `mood_relaxed_musicnn` |
  | `mood_happy` | `mood_happy_musicnn` |
  | `musicnn_embedding` | `embedding_musicnn` |
  | `bpm` | `bpm_rhythm2013` |
  | `beat_confidence` | `beat_confidence_rhythm2013` |

  No aliases are provided for the previous ids.
- Tags `v0.1.0` and `v0.2.0` remain fetchable and are the compatibility
  mechanism for consumers that still require the pre-0.3 namespace and
  previous descriptor ids.
