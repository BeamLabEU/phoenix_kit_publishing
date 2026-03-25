## 0.1.0 - 2026-03-25

### Added
- Extract Publishing module from PhoenixKit into standalone `phoenix_kit_publishing` package
- Implement `PhoenixKit.Module` behaviour with all required callbacks
- Add 4 Ecto schemas: PublishingGroup, PublishingPost, PublishingVersion, PublishingContent
- Add dual URL modes: timestamp-based (blog/news) and slug-based (docs/FAQ)
- Add multi-language support with per-language content per version
- Add version management (create, publish, archive, clone)
- Add collaborative editing with Phoenix.Presence (owner/spectator locking)
- Add two-layer caching: ListingCache (`:persistent_term`) and Renderer (ETS, 6hr TTL)
- Add Markdown + PHK component rendering (Image, Hero, CTA, Video, Headline, Subheadline, EntityForm)
- Add PageBuilder XML parser (Saxy) for inline PHK components
- Add admin LiveViews: Index, Listing, Editor, Preview, PostShow, Settings
- Add public Controller with language detection, slug resolution, pagination, and smart fallbacks
- Add Oban workers for AI translation and primary language migration
- Add PubSub broadcasting for real-time admin updates
- Add route module with `admin_routes/0`, `admin_locale_routes/0`, and `public_routes/0`
- Add `css_sources/0` for Tailwind CSS scanning support
- Add migration module (run by parent app) with `IF NOT EXISTS` guards for all 4 tables
- Add unit and integration test suites
