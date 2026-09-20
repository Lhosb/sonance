# Changelog

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
