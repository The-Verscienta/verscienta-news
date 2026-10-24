<script lang="ts">
  import type { PageData } from './$types';
  export let data: PageData;
</script>

<article class="mx-auto max-w-3xl">
  <div class="mb-3 flex items-center gap-2 text-xs"><span class="badge bg-primary/10 text-primary">{data.article.category ?? 'Wellness'}</span><span class="text-base-content/50">{data.article.published_at ?? ''}</span></div>
  <h1 class="font-serif text-3xl font-bold leading-tight tracking-tight">{data.article.title}</h1>
  {#if data.article.excerpt}<p class="mt-3 text-base leading-relaxed text-base-content/70">{data.article.excerpt}</p>{/if}
  <div class="prose prose-sm mt-6 max-w-none">
    <p class="text-sm text-base-content/60">Body from Kiln fired <code>/api/content/article/{data.article.slug}?format=json</code> (Portable Text). Fired <code>/:slug</code> is canonical.</p>
  </div>
  <aside class="mt-8 space-y-3 border-t border-base-300 pt-4 text-xs leading-relaxed text-base-content/60">
    <p><strong>Attribution:</strong> {data.article.category ?? 'Wellness'} · via source (see <a href="http://localhost:4000/{data.article.slug}" class="underline">fired Kiln page</a> for full attribution per <code>docs/source-rights.md</code>).</p>
    <p class="rounded-md border border-warning/20 bg-warning/5 p-3 text-warning">Not medical advice — for information only. Consult a qualified professional.</p>
    <p><span class="badge bg-base-200">Claim: Unreviewed</span> Slice 1 shows claim badge per <code>docs/moderation.md</code>; flag → stays in review queue.</p>
  </aside>
  <div class="mt-8 border-t border-base-300 pt-6">
    <h3 class="text-sm font-semibold">Comments</h3>
    <p class="mt-2 text-sm text-base-content/60">Deferred past Slice 1 (see <code>docs/social.md</code> — <code>VerscientaNews.FollowGraph</code> not <code>KilnCMS.Social</code>).</p>
  </div>
</article>
