# Models, languages, and translation

Reference for `/lang`, `/model`, and `/translate`. The [README](../README.md#language-and-translation)
has the short version; this is the whole picture, including why the defaults are
what they are.

## Language

```text
listnr> /lang en           # English
listnr> /lang bn           # Bangla · also hi, es, fr, de, ja, zh
listnr> /lang auto         # detect once at the start of the session, then lock
```

Each language picks a sensible default model, so `/lang` is usually the only thing you touch. `/model` overrides it.

**Name the language rather than using `auto`.** Detection runs once per session and then locks, which is a large improvement over detecting per clip — that was the cause of auto mode's worst behaviour, because consecutive sentences of one conversation could be decoded as different languages and the output read as gibberish. It still has to make that one call on a second or two of speech, and naming the language costs you nothing.

### Why non-English used to look broken

Worth knowing, because it explains what changed and what the warnings mean. Whisper reports a confidence score per segment, and Listnr uses it to throw away hallucinated text. Those scores are **not comparable across writing systems**:

- Whisper's tokenizer is English-centric, so Bengali and Devanagari cost several times more tokens per word, each individually less confident. Correct Bangla averages around −1.2 on a scale where English speech sits above −0.9.
- Compression ratio flags repetition loops, but Indic and Han text is three bytes per character from a small repertoire, so an *ordinary* sentence compresses like a degenerate one.

Listnr used to apply the English numbers to every language. Correct Bangla scored as a hallucination, got discarded, and nothing was logged — the language looked like it simply did not work. Thresholds are now keyed on writing system, and when segments *are* dropped you get a line saying so:

```text
! dropped 3 low-confidence segment(s) [lang=bn, script=indic]. If speech is missing, try /model whisper-large-v2
```

### Models

`listnr models list` prints this at any time. `★` is the English default, `→en` means the model can translate.

| Model | Size | Languages | Translates | Role |
|---|---|---|---|---|
| `whisper-base.en` | 139 MB | English | — | **★ Default for `/lang en`.** Fast and accurate |
| `whisper-small.en` | 463 MB | English | — | English, more accurate, slower |
| `whisper-tiny` | 73 MB | all | ✓ | Too weak to rely on; useful for A/B tests |
| `whisper-base` | 139 MB | all | ✓ | Multilingual sibling of the English default |
| `whisper-small` | 207 MB | all | ✓ | Lightest usable multilingual. OK for es/fr/de, weak on Bangla |
| `whisper-medium` | 1.4 GB | all | ✓ | **Default for `es`/`fr`/`de`** |
| `whisper-large-v2` | 908 MB | all | ✓ | **Most accurate for Bangla and Hindi. Default when translating** |
| `whisper-large-v3-turbo-fast` | 615 MB | all | ✗ | **Default for `bn`/`hi`/`ja`/`zh`/`auto`.** Quantized |
| `whisper-large-v3-turbo` | 1.5 GB | all | ✗ | Full precision. Slower for no real accuracy gain |

Three things about this table are not obvious:

**The non-English defaults are not the most accurate option, on purpose.** They aim to keep pace with a live conversation, because a model that cannot is worse than a smaller one — the lane pipeline drops audio it cannot transcribe in time, so you lose whole utterances rather than getting slightly rougher text. Move up with `/model whisper-large-v2` when accuracy matters more than latency.

**`whisper-large-v2` is smaller than `whisper-medium` *and* better.** It is a quantized build, so medium is never the right choice for Bangla or Hindi. Pick large-v2 or, if 908 MB is too much, `whisper-small`.

**large-v2 rather than a v3 for the accuracy pick is deliberate.** `large-v3-turbo` is distilled from thirty-two decoder layers down to four, and that loss lands hardest on the languages with the least training data behind them — exactly Bangla and Hindi.

Be realistic about the ceiling. Whisper is much weaker on Bangla than on English at every size. English feeling polished while Bangla feels rough is partly the models, not only the configuration.

## Translating to English

Speak Bangla, Hindi, or anything else Whisper supports, and get an English transcript:

```text
listnr> /translate                              # toggle; transcript comes out English
```

```sh
listnr start --language bn --translate --seconds 60
```

This is Whisper's own `translate` task, so there is no second model, no extra pass, and no added latency beyond the model itself. Four things to know:

**It only goes into English.** Whisper cannot target any other language. There is no Bangla → Hindi. English in with `/translate` on is a no-op, and Listnr tells you so.

**The original wording is not kept.** Every line is English. If the native transcript is the record you need, leave `/translate` off.

**The turbo models cannot do it — silently.** OpenAI fine-tuned `large-v3-turbo` for transcription only; it "will return the original language even if `--task translate` is specified." No error, just the wrong language for the length of your meeting. Since the turbo build is Listnr's *transcription* default for `bn`/`hi`/`ja`/`zh`, Listnr handles this for you:

- Turning on `/translate` re-picks the model (→ `whisper-large-v2`) instead of leaving one that ignores the request.
- Naming an incapable model explicitly is **refused before the session starts**, with the capable ones listed.
- `listnr models list` marks capable models with `→en`.

**The default here favours quality over size**, unlike the transcription defaults, because translation is a harder task and degrades faster as models shrink:

| `/model` | Size | Translation quality |
|---|---|---|
| `whisper-small` | 207 MB | Lightest usable. Rough, but intelligible for Hindi |
| `whisper-large-v2` | 908 MB | **Default.** Best available |
| `whisper-medium` | 1.4 GB | Good, but larger than large-v2 and worse — no reason to pick it |
| `whisper-tiny`, `whisper-base` | 73 / 139 MB | Not worth running |

There is no 200 MB model that turns Bangla speech into clean English. `whisper-small` translating Bangla will be noticeably rougher than `whisper-base.en` transcribing English.
