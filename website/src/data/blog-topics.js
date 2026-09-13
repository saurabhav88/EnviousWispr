export const BLOG_TOPICS = [
  { id: "getting-started", label: "Getting started" },
  { id: "writing-productivity", label: "Writing and productivity" },
  { id: "privacy-offline", label: "Privacy and offline" },
  { id: "tips-troubleshooting", label: "Tips and troubleshooting" },
  { id: "behind-enviouswispr", label: "Behind EnviousWispr" },
];
export function topicLabel(id) {
  return BLOG_TOPICS.find((topic) => topic.id === id)?.label ?? "Article";
}
