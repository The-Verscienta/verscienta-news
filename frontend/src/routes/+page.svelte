<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchPublishedArticles, type Article } from '$lib/api/kiln';
  let articles: Article[] = [];
  let error: string | null = null;
  let active = 'All';
  const cats = ['All', 'Nutrition', 'Herbalism', 'Mindfulness'];
  onMount(async () => {
    try { articles = await fetchPublishedArticles(); } catch (e: unknown) { error = e instanceof Error ? e.message : 'load failed'; }
  });
  $: filtered = active === 'All' ? articles : articles.filter((a) => (a.category ?? '').toLowerCase() === active.toLowerCase());
</script>

<div class="grid gap-6 lg:grid-cols-[1fr_300px]">
  <div>
    <div class="mb-4 flex gap-1 overflow-x-auto border-b border-base-300">
      {#each cats as t}
        <button class="border-b-2 px-3 py-2 text-sm whitespace-nowrap {active===t ? 'border-primary text-base-content' : 'border-transparent text-base-content/60'}" on:click={() => active=t}>{t}</button>
      {/each}
    </div>
    {#if error}
      <div class="card p-6 text-sm">Backend not reachable ({error}). Run <code>docker compose up -d postgres</code> + <code>cd kiln_cms && mix phx.server</code>.</div>
    {:else if filtered.length === 0}
      <div class="card p-8 text-center text-sm text-base-content/60">
        <p class="font-medium text-base-content">No articles yet</p>
        <p class="mt-1">Slice 1: seed Kiln (`mix run priv/repo/seeds.exs`) — see <code>docs/slice-1.md</code>. Delivery is Kiln fired <code>/:slug</code> + reader <code>/article/[slug]</code>.</p>
      </div>
    {:else}
      <div class="grid gap-4">
        {#each filtered as a}
          <a href="/article/{a.slug}" class="card flex gap-4 p-4 hover:bg-base-200/40">
            {#if a.cover_url}<img src={a.cover_url} alt="" class="h-20 w-28 rounded-md object-cover" />{/if}
            <div class="min-w-0">
              <div class="flex gap-2"><span class="badge bg-secondary/10 text-secondary text-xs">{a.category ?? 'Wellness'}</span>{#if a.published_at}<span class="text-xs text-base-content/50">{new Date(a.published_at).toLocaleDateString()}</span>{/if}</div>
              <h2 class="mt-1 font-serif text-base font-semibold leading-tight line-clamp-2">{a.title}</h2>
              {#if a.excerpt}<p class="mt-1 line-clamp-2 text-sm text-base-content/60">{a.excerpt}</p>{/if}
            </div>
          </a>
        {/each}
      </div>
    {/if}
  </div>
  <aside class="space-y-4">
    <div class="card p-4">
      <h3 class="text-sm font-semibold">Slice 1</h3>
      <p class="mt-1 text-xs leading-relaxed text-base-content/60">Fired Kiln pages with attribution + <em>Not medical advice</em> disclaimer + claim badge. Vitality, follows, For You, and rooms are <a href="/docs/slice-1.md" class="underline">deferred</a> until this is readable.</p>
      <a href="/search" class="btn btn-ghost mt-3 w-full text-xs">Search (Kiln FTS) →</a>
    </div>
    <div class="card p-4">
      <h3 class="text-sm font-semibold">Author</h3>
      <p class="mt-1 text-xs text-base-content/60">Write in Kiln <a href="http://localhost:4000/editor" class="underline">/editor</a> (review queue), not in Svelte.</p>
    </div>
  </aside>
</div>
