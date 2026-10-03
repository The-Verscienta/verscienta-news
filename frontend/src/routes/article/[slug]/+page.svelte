<script lang="ts">
  import type { PageData } from './$types';
  export let data: PageData;
</script>

<article class="mx-auto max-w-3xl">
  <div class="mb-3 flex items-center gap-2 text-xs"><span class="badge bg-primary/10 text-primary">{data.article.category ?? 'Wellness'}</span><span class="text-base-content/50">{data.article.published_at ?? ''}</span></div>
  <h1 class="font-serif text-3xl font-bold leading-tight tracking-tight">{data.article.title}</h1>
  {#if data.article.excerpt}<p class="mt-3 text-base leading-relaxed text-base-content/70">{data.article.excerpt}</p>{/if}
  <div class="prose prose-sm mt-6 max-w-none">
    <p class="text-sm text-base-content/60">Article body renders from Kiln fired artifact blocks. Wire <code>/api/content/article/:slug?format=json</code> → TipTap/Portable Text renderer. See <code>docs/rendering.md</code>.</p>
  </div>
  <div class="mt-8 border-t border-base-300 pt-6">
    <h3 class="text-sm font-semibold">Comments</h3>
    <p class="mt-2 text-sm text-base-content/60">Threaded comments via <code>VerscientaNews.Social</code> + Phoenix Channels. This shell is static until `mix ash.migrate` for social domain.</p>
  </div>
</article>
