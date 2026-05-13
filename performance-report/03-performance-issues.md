# Performance issues found

## Fixed in this pass

1. **Composer keystrokes invalidated PiAgentScreen**
   - Symptom: delayed input when long transcript is selected.
   - Cause: composer state lived in the large parent screen.
   - Fix: isolated composer into `PiAgentComposerPanel`.

2. **Long transcript eager rendering**
   - Symptom: slow session switching and long-chat rendering.
   - Cause: transcript stack used eager `VStack`.
   - Fix: switched to `LazyVStack`; regression smoke test still passes.

3. **Per-thread plan event scanning**
   - Symptom: O(n²) work in long transcripts with plan events.
   - Cause: `planEvents(for:in:)` scanned timeline items for each thread.
   - Fix: one pass builds `planEventsByThreadID`.

4. **Repeated attachment parsing and image decoding**
   - Symptom: user-message attachment parsing/preview decode appeared in profiles.
   - Fix: cached parsed attachment metadata and preview images.

5. **Model options missing for new chats before global discovery finished**
   - Symptom: new draft chats could briefly have no model list, affecting model UI/title generation.
   - Fix: fallback to existing session model options and title-generation fallback model.

6. **Background refresh contention**
   - Symptom: `FileWatchFingerprint.make` appears during input/session switching.
   - Fix: auto-refresh interval reduced from every 2s to every 6s.

## Still worth tracking

1. **ContentView/sidebar derived-property cost**
   - Final profiles still show `ContentView.body`, `filteredAgents`, `hasAgentWarnings`, `hasSkillWarnings`, and related derived properties.
   - Impact is lower than transcript/composer issues, but caching these at AppViewModel refresh boundaries would further reduce render work.

2. **Transcript disk load on cold session switches**
   - Lazy transcript loading is async, but decoding a persisted transcript still appears in switching profiles.
   - Consider prefetching adjacent/recent sessions or storing a compact render cache if cold-switch latency remains visible with very large histories.

3. **Repository changes refresh on session switch**
   - `prepareRepoChangesForSelectedPiAgentSession` appears in final switch traces.
   - Consider deferring repo changes refresh until the repo-changes panel is opened, or using stale-while-revalidate data.
