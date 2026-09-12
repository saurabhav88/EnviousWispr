import { BLOG_TOPICS } from "../data/blog-topics.js";
export const BLOG_PAGE_SIZE = 12;
export function archivePath(page = 1) {
  return page === 1 ? "/blog/" : `/blog/page/${page}/`;
}
export function readingMinutes(body = "") {
  const words = body
    .replace(/```[\s\S]*?```/g, "")
    .replace(/<[^>]*>/g, "")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
  return Math.max(1, Math.round(words.length / 220));
}
export function normalizeBlogState(value, defaultPage = 1) {
  return {
    query: typeof value?.query === "string" ? value.query.slice(0, 200) : "",
    topic: BLOG_TOPICS.some((topic) => topic.id === value?.topic)
      ? value.topic
      : "",
    page:
      Number.isSafeInteger(value?.page) && value.page > 0
        ? value.page
        : defaultPage,
  };
}
export function filterBlogPosts(posts, state) {
  const query = state.query.trim().normalize("NFKC").toLocaleLowerCase("en");
  return posts.filter((post) => {
    if (state.topic && post.topic !== state.topic) return false;
    return (
      !query ||
      [post.title, post.description, ...(post.tags ?? [])]
        .join(" ")
        .normalize("NFKC")
        .toLocaleLowerCase("en")
        .includes(query)
    );
  });
}
export function blogPage(posts, requestedPage) {
  const totalPages = Math.max(1, Math.ceil(posts.length / BLOG_PAGE_SIZE));
  const page = Math.min(
    Math.max(1, Number.isSafeInteger(requestedPage) ? requestedPage : 1),
    totalPages,
  );
  return {
    page,
    totalPages,
    posts: posts.slice((page - 1) * BLOG_PAGE_SIZE, page * BLOG_PAGE_SIZE),
  };
}
