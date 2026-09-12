// Product outcome: readers can find later articles and browse every archive page.
import test from "node:test";
import assert from "node:assert/strict";
import {
  archivePath,
  blogPage,
  filterBlogPosts,
  normalizeBlogState,
  readingMinutes,
} from "../../src/utils/blog-core.js";
import { topicLabel } from "../../src/data/blog-topics.js";

const posts = Array.from({ length: 35 }, (_, index) => ({
  title: `Article ${index + 1}`,
  description: "A writing guide",
  tags: [],
  topic: "writing-productivity",
}));
posts[24] = {
  title: "Dictation for parents",
  description: "One-handed writing",
  tags: ["family"],
  topic: "writing-productivity",
};
posts[34] = {
  title: "Private dictation",
  description: "On your Mac",
  tags: ["offline"],
  topic: "privacy-offline",
};

test("search finds an article beyond the first and second archive pages", () => {
  assert.deepEqual(
    filterBlogPosts(posts, { query: "PARENTS", topic: "" }).map(
      (post) => post.title,
    ),
    ["Dictation for parents"],
  );
  assert.deepEqual(
    filterBlogPosts(posts, { query: "offline", topic: "privacy-offline" }).map(
      (post) => post.title,
    ),
    ["Private dictation"],
  );
  assert.equal(
    filterBlogPosts(posts, { query: "offline", topic: "writing-productivity" })
      .length,
    0,
  );
});

test("native archive pages cover the collection once without gaps", () => {
  assert.deepEqual(
    [1, 2, 3].map((page) => blogPage(posts, page).posts.length),
    [12, 12, 11],
  );
  assert.deepEqual(
    [1, 2, 3].flatMap((page) => blogPage(posts, page).posts),
    posts,
  );
  assert.equal(blogPage(posts, 2).posts[0].title, "Article 13");
  assert.equal(archivePath(1), "/blog/");
  assert.equal(archivePath(3), "/blog/page/3/");
});

test("empty results and stale pagination still have a usable page state", () => {
  assert.deepEqual(blogPage([], 50), { page: 1, totalPages: 1, posts: [] });
  assert.equal(blogPage(posts, 999).page, 3);
  assert.equal(blogPage(posts, -1).page, 1);
  assert.deepEqual(
    normalizeBlogState(
      { topic: "retired-topic", page: "2", query: "email" },
      3,
    ),
    { topic: "", query: "email", page: 3 },
  );
});

test("uncategorized future posts remain discoverable without a false topic label", () => {
  const post = { title: "A new guide", description: "", tags: [] };
  assert.equal(topicLabel(undefined), "Article");
  assert.deepEqual(filterBlogPosts([post], { query: "new", topic: "" }), [
    post,
  ]);
});

test("reading estimates never show zero and exclude code blocks", () => {
  assert.equal(readingMinutes(""), 1);
  assert.equal(readingMinutes("word ".repeat(440)), 2);
  assert.equal(
    readingMinutes("A short guide.\n```js\n" + "code ".repeat(1000) + "\n```"),
    1,
  );
});
