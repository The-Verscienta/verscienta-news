const KILN = import.meta.env.VITE_KILN_URL ?? 'http://localhost:4000';

export type Article = {
  id: string; slug: string; title: string; excerpt?: string;
  category?: string; tags?: string[]; published_at?: string;
  blocks?: unknown[]; cover_url?: string;
};

export async function fetchPublishedArticles(q?: string): Promise<Article[]> {
  const url = q ? `/api/content/article?filter[query]=${encodeURIComponent(q)}` : '/api/content/article';
  const res = await fetch(`${KILN}${url}`, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error(`kiln ${res.status}`);
  const data = await res.json();
  return (data.data ?? data ?? []) as Article[];
}

export async function fetchArticleBySlug(slug: string): Promise<Article | null> {
  const res = await fetch(`${KILN}/api/content/article/${slug}`, { headers: { accept: 'application/json' } });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`kiln ${res.status}`);
  const data = await res.json();
  return (data.data ?? data) as Article;
}

export async function searchArticles(query: string) {
  const res = await fetch(`${KILN}/api/search?query=${encodeURIComponent(query)}`);
  if (!res.ok) return [];
  return (await res.json()).results ?? [];
}
