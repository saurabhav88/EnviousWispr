import { getPublishedPosts } from "../utils/posts";
import { presentPost } from "../utils/blog-presentation";
export async function GET() {
  return new Response(
    JSON.stringify(
      await Promise.all((await getPublishedPosts()).map(presentPost)),
    ),
    {
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        "X-Robots-Tag": "noindex",
      },
    },
  );
}
