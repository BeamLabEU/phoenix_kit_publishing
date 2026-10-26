# PR #62 — follow-up

- The 3 `ListPostsTest` failures and two unformatted test files are on `main` too.
- The editor's AI-translate modal events are gated on `publishing.manage` (the save's own check) before `AITranslate.Embed`, which otherwise dispatches with no permission check. Switch to the Embed's `authorize:` option once phoenix_kit_ai releases it.
