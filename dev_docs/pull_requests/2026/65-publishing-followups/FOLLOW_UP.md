# Follow-up — PR #65

| Finding | Source | Resolution |
|---|---|---|
| Custom filter keys not normalised | vibe | Fixed in dbc033f; test in `list_published_test.exs` |
| `<Image>` size insert fooled by quoted text, `height` not checked | codex | Fixed in 95a1a80; test in `image_dimensions_test.exs` |
| Custom filter raised on a map value, nil matched nothing | codex, zai | Fixed in 95a1a80 |
| Unusable key with nil matched; two spellings collapsed | codex (re-review) | Fixed in a14fbcc |
| Non-string author width raised; Storage exit not caught | codex, zai | Fixed in 95a1a80; integers accepted in dbc033f |
| Stale slug set under a long snapshot | codex | Not a reachable request path; recorded |
| Markup core never emits (`<IMG`, `>` in alt, script) | codex | Not reachable; pattern tightened to `<img\s` |
| Display-error precedence with two bad SEO texts | zai | Message order only; recorded |
| Label with invalid UTF-8 raised | codex (label commits) | Fixed in a69992f; test in `version_access_test.exs` |
| Disabled Public button's hint not focusable | codex (label commits) | Fixed in a69992f |
| Crafted save of an older version's label | codex (label commits) | Same as every sidebar field; recorded |
