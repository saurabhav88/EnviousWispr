// What the in-app help check (#3275) may do with a help article that matches a
// feedback message. Read by the help collection schema (src/content.config.ts)
// and the help catalog generator (scripts/generate-help-article-catalog.mjs).
//   can_resolve          the user may mark the problem solved, and it is not sent
//   show_but_always_send the card is shown, and the report is still sent
//   never_intervene      the article is never shown as a card
export const DEFLECTION_POLICIES = ["can_resolve", "show_but_always_send", "never_intervene"];
