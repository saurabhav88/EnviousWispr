import {
  archivePath,
  blogPage,
  filterBlogPosts,
  normalizeBlogState,
} from "../utils/blog-core.js";

const root = document.querySelector("[data-blog-page]");
if (root) {
  const search = document.querySelector("#article-search");
  const topic = document.querySelector("#topic-select");
  const grid = document.querySelector("#article-grid");
  const count = document.querySelector("#result-count");
  const clear = document.querySelector("#clear-filters");
  const empty = document.querySelector("#empty-state");
  const paging = document.querySelector("#pagination-wrap");
  const error = document.querySelector("#search-error");
  const initialPage = Number(root.dataset.blogPage);
  const initial = {
    cards: grid.innerHTML,
    paging: paging.innerHTML,
    count: count.textContent,
  };
  let state = normalizeBlogState(history.state?.ewBlog, initialPage);
  let catalogPromise;
  let catalog;
  let version = 0;

  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  function card(post) {
    const article = element("article", "article-card");
    const cover = element("a", "card-cover");
    cover.href = post.url;
    cover.tabIndex = -1;
    cover.setAttribute("aria-hidden", "true");
    if (post.artwork) {
      const image = element("img", "artwork-image");
      Object.assign(image, {
        src: post.artwork.src,
        srcset: post.artwork.srcset,
        sizes:
          "(min-width: 1400px) 424px, (min-width: 851px) calc((100vw - 96px) / 3), (min-width: 601px) calc((100vw - 64px) / 2), calc(100vw - 32px)",
        width: post.artwork.width,
        height: post.artwork.height,
        alt: "",
        loading: "lazy",
        decoding: "async",
      });
      cover.append(image);
    } else {
      const fallback = element("div", "artwork-fallback");
      const logo = element("img");
      Object.assign(logo, {
        src: "/favicon.svg",
        width: 60,
        height: 60,
        alt: "",
      });
      fallback.append(logo);
      cover.append(fallback);
    }
    const info = element("div", "card-info");
    const heading = element("h2");
    const link = element("a", "", post.title);
    link.href = post.url;
    heading.append(link);
    const bottom = element("div", "card-bottom");
    const arrow = element("a", "", "→");
    arrow.href = post.url;
    arrow.setAttribute("aria-label", `Read ${post.title}`);
    bottom.append(element("span", "", `${post.minutes} min read`), arrow);
    info.append(
      element("span", "topic", post.topicLabel),
      heading,
      element("p", "", post.description),
      bottom,
    );
    article.append(cover, info);
    return article;
  }

  function save() {
    // Query text stays in this history entry, never in URLs or analytics.
    history.replaceState({ ...history.state, ewBlog: state }, "");
  }

  function restoreArchive() {
    grid.innerHTML = initial.cards;
    paging.innerHTML = initial.paging;
    grid.hidden = false;
    empty.hidden = true;
    count.textContent = initial.count;
  }

  async function loadCatalog() {
    if (catalog) return catalog;
    if (!catalogPromise) {
      catalogPromise = fetch("/blog-search.json", {
        signal: AbortSignal.timeout(10000),
      })
        .then((response) => {
          if (!response.ok) throw new Error("Search catalog unavailable");
          return response.json();
        })
        .then((posts) => {
          if (
            !Array.isArray(posts) ||
            posts.some(
              (post) =>
                typeof post.title !== "string" ||
                typeof post.description !== "string" ||
                !post.url?.startsWith("/blog/"),
            )
          )
            throw new Error("Invalid search catalog");
          catalog = posts;
          return posts;
        })
        .finally(() => {
          catalogPromise = undefined;
        });
    }
    return catalogPromise;
  }

  function pagination(totalPages, active) {
    if (totalPages < 2) {
      paging.replaceChildren();
      return;
    }
    const nav = element("nav", "pagination");
    nav.setAttribute("aria-label", "Article pages");
    const pages = element("div");
    function control(page, label, direction = false) {
      const disabled = page < 1 || page > totalPages;
      const button = element(
        active ? "button" : disabled ? "span" : "a",
        direction ? "page-direction" : "",
        label,
      );
      if (active) {
        button.dataset.page = String(page);
        button.disabled = disabled;
      } else if (!disabled) button.href = `${archivePath(page)}#articles`;
      else button.classList.add("unavailable");
      if (!direction) {
        button.setAttribute("aria-label", `Page ${page}`);
        if (page === state.page) button.setAttribute("aria-current", "page");
      }
      return button;
    }
    for (let page = 1; page <= totalPages; page++)
      pages.append(control(page, String(page)));
    nav.append(
      control(state.page - 1, "← Previous", true),
      pages,
      control(state.page + 1, "Next →", true),
    );
    paging.replaceChildren(nav);
  }

  async function render() {
    const current = ++version;
    const active = !!state.query.trim() || !!state.topic;
    clear.hidden = !active;
    error.hidden = true;
    if (!active) {
      state.page = initialPage;
      save();
      restoreArchive();
      grid.removeAttribute("aria-busy");
      return;
    }
    grid.setAttribute("aria-busy", "true");
    count.textContent = "Loading articles…";
    try {
      const posts = await loadCatalog();
      if (current !== version) return;
      const matches = filterBlogPosts(posts, state);
      const result = blogPage(matches, state.page);
      state.page = result.page;
      save();
      grid.replaceChildren(...result.posts.map(card));
      grid.hidden = !matches.length;
      empty.hidden = !!matches.length;
      count.textContent = `${matches.length} ${matches.length === 1 ? "article" : "articles"}${active ? " found" : ""}`;
      pagination(result.totalPages, active);
    } catch {
      if (current !== version) return;
      restoreArchive();
      error.hidden = false;
    } finally {
      if (current === version) grid.removeAttribute("aria-busy");
    }
  }

  function change() {
    state = normalizeBlogState({
      query: search.value,
      topic: topic.value,
      page: 1,
    });
    save();
    void render();
  }
  function reset() {
    state = { query: "", topic: "", page: initialPage };
    search.value = "";
    topic.value = "";
    save();
    void render();
    search.focus();
  }
  search.disabled = false;
  topic.disabled = false;
  search.value = state.query;
  topic.value = state.topic;
  search.addEventListener("input", change);
  topic.addEventListener("change", change);
  search.form.addEventListener("submit", (event) => {
    event.preventDefault();
    change();
  });
  clear.addEventListener("click", reset);
  document.querySelector("#empty-reset").addEventListener("click", reset);
  document.querySelector("#retry-search").addEventListener("click", () => {
    void render();
  });
  paging.addEventListener("click", async (event) => {
    const button = event.target.closest("button[data-page]");
    if (!button || button.disabled) return;
    state.page = Number(button.dataset.page);
    save();
    await render();
    document.querySelector("#articles").scrollIntoView({ behavior: "instant" });
    paging
      .querySelector('[aria-current="page"]')
      ?.focus({ preventScroll: true });
  });
  window.addEventListener("pageshow", () => {
    state = normalizeBlogState(history.state?.ewBlog, initialPage);
    search.value = state.query;
    topic.value = state.topic;
    void render();
  });
  void render();
}
