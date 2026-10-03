import { fetchArticleBySlug } from '$lib/api/kiln';
import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params }) => {
  const article = await fetchArticleBySlug(params.slug);
  if (!article) throw error(404, 'Article not found');
  return { article };
};
