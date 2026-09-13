// Share buttons — handles the article rail and BlogShareRow.
// Clipboard telemetry follows a successful write. Social telemetry records the
// click intent because popup blockers can prevent a composer from opening.
// For email (mailto:) we fire on click since the OS hands off and we can't observe.
(function () {
  const slug = window.location.pathname
    .replace(/^\/blog\//, "")
    .replace(/\/$/, "");
  const title = document.title;

  const fireTelemetry = (network: string) => {
    const w = window as unknown as {
      posthog?: { capture?: (e: string, p: object) => void };
    };
    if (
      typeof w.posthog !== "undefined" &&
      typeof w.posthog.capture === "function"
    ) {
      w.posthog.capture("share_clicked", { network, slug });
    }
  };

  const status = document.getElementById("share-status");
  const announce = (msg: string) => {
    if (status) status.textContent = msg;
  };

  const composeUrl = () => {
    // Prefer section-anchor when scroll-spy has marked an active heading.
    const activeId = document.documentElement.dataset.tocActive;
    const base =
      document.querySelector<HTMLLinkElement>("link[rel=canonical]")?.href ||
      window.location.origin + window.location.pathname;
    return activeId ? `${base}#${activeId}` : base;
  };

  const handleClick = async (btn: HTMLButtonElement) => {
    const network = btn.getAttribute("data-share");
    if (!network) return;
    const url = composeUrl();

    if (network === "copy") {
      try {
        await navigator.clipboard.writeText(url);
        fireTelemetry("copy");
        announce("Link copied to clipboard");
        flashSuccess(btn, "Copied!");
      } catch {
        announce("Copy failed. Use your browser’s URL bar instead.");
      }
      return;
    }

    if (network === "email") {
      const subject = encodeURIComponent(title);
      const body = encodeURIComponent(`${title}\n\n${url}`);
      const href = `mailto:?subject=${subject}&body=${body}`;
      fireTelemetry("email");
      window.location.href = href;
      return;
    }

    if (network === "x") {
      const intent = `https://x.com/intent/tweet?text=${encodeURIComponent(title)}&url=${encodeURIComponent(url)}`;
      fireTelemetry("x");
      window.open(intent, "_blank", "noopener,noreferrer");
      return;
    }

    if (network === "linkedin") {
      const intent = `https://www.linkedin.com/sharing/share-offsite/?url=${encodeURIComponent(url)}`;
      fireTelemetry("linkedin");
      window.open(intent, "_blank", "noopener,noreferrer");
      return;
    }
  };

  const flashSuccess = (btn: HTMLButtonElement, label: string) => {
    const labelEl = btn.querySelector<HTMLElement>('[class$="-btn-label"]');
    const original = labelEl?.textContent;
    if (labelEl) labelEl.textContent = label;
    btn.classList.add("share-btn-success");
    setTimeout(() => {
      if (labelEl && typeof original === "string")
        labelEl.textContent = original;
      btn.classList.remove("share-btn-success");
    }, 1800);
  };

  document
    .querySelectorAll<HTMLButtonElement>("[data-share]")
    .forEach((btn) => {
      btn.addEventListener("click", () => {
        void handleClick(btn);
      });
    });
})();

// Heading IDs are authored by Astro's Markdown renderer and shared with both
// server-rendered contents lists. Do not mint a second set in the browser.
const headings = [
  ...document.querySelectorAll<HTMLElement>(
    ".reading-body h2[id], .reading-body h3[id]",
  ),
];
const links = [
  ...document.querySelectorAll<HTMLAnchorElement>("[data-toc-target]"),
];
let pending = false;
function updateHeading() {
  const top =
    Math.max(
      Number.parseFloat(
        getComputedStyle(document.documentElement).scrollPaddingTop,
      ) || 0,
      document.querySelector(".chrome-header")?.getBoundingClientRect()
        .bottom ?? 100,
    ) + 1;
  let active: string | undefined;
  for (const heading of links.length ? headings : []) {
    if (heading.getBoundingClientRect().top <= top) active = heading.id;
    else break;
  }
  if (active) document.documentElement.dataset.tocActive = active;
  else delete document.documentElement.dataset.tocActive;
  for (const link of links) {
    if (link.dataset.tocTarget === active)
      link.setAttribute("aria-current", "location");
    else link.removeAttribute("aria-current");
  }
  pending = false;
}
addEventListener(
  "scroll",
  () => {
    if (!pending) {
      pending = true;
      requestAnimationFrame(updateHeading);
    }
  },
  { passive: true },
);
addEventListener("resize", updateHeading);
updateHeading();

// Keep code copying available at every viewport, with an honest failure result.
document
  .querySelectorAll<HTMLPreElement>(".reading-body pre")
  .forEach((pre) => {
    const plainText = pre.textContent ?? "";
    const button = document.createElement("button");
    button.className = "copy-btn";
    button.textContent = "Copy";
    button.setAttribute("aria-label", "Copy code");
    button.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(
          pre.querySelector("code")?.textContent ?? plainText,
        );
        button.textContent = "Copied";
      } catch {
        button.textContent = "Could not copy";
      }
      setTimeout(() => {
        button.textContent = "Copy";
      }, 2000);
    });
    pre.append(button);
  });
document
  .querySelectorAll<HTMLTableElement>(".reading-body table")
  .forEach((table) => {
    table.tabIndex = 0;
    if (!table.hasAttribute("aria-label"))
      table.setAttribute("aria-label", "Article table");
  });
