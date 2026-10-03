<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchPublishedArticles, type Article } from '$lib/api/kiln';
  let articles: Article[] = [];
  let error: string | null = null;
  let active = 'For You';
  const tabs = ['For You', 'Following', 'Nutrition', 'Herbalism', 'Mindfulness'];
  onMount(async () => {
    try { articles = await fetchPublishedArticles(); } catch (e: unknown) { error = e instanceof Error ? e.message : 'load failed'; }
  });
</script>

<div class="grid gap-6 lg:grid-cols-[1fr_300px]">
  <div>
    <div class="mb-4 flex gap-1 overflow-x-auto border-b border-base-300">
      {#each tabs as t}
        <button class="border-b-2 px-3 py-2 text-sm whitespace-nowrap {active===t ? 'border-primary text-base-content' : 'border-transparent text-base-content/60'}" on:click={() => active=t}>{t}</button>
      {/each}
    </div>
    {#if error}
      <div class="card p-6 text-sm">Backend not reachable ({error}). Run <code>docker compose up -d postgres</code> + <code>cd kiln_cms && mix phx.server</code>.</div>
    {:else if articles.length === 0}
      <div class="card p-8 text-center text-sm text-base-content/60">
        <p class="font-medium text-base-content">No articles yet</p>
        <p class="mt-1">Seed Kiln (`mix run priv/repo/seeds.exs`) or wait for Broadway ingestion (see <code>docs/ingestion.md</code>).</p>
      </div>
    {:else}
      <div class="grid gap-4">
        {#each articles as a}
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
      <h3 class="text-sm font-semibold">Vitality</h3>
      <p class="mt-1 text-xs text-base-content/60">Read, comment, publish, curate — earn points & badges.</p>
      <div class="mt-3 grid grid-cols-3 gap-2 text-center">
        <div class="rounded-md bg-base-200 p-2"><div class="text-sm font-bold">12</div><div class="text-xs text-base-content/50">Streak</div></div>
        <div class="rounded-md bg-base-200 p-2"><div class="text-sm font-bold">1.4k</div><div class="text-xs text-base-content/50">Points</div></div>
        <div class="rounded-md bg-base-200 p-2"><div class="text-sm font-bold">Lv 7</div><div class="text-xs text-base-content/50">Level</div></div>
      </div>
      <a href="/rewards" class="btn btn-ghost mt-3 w-full text-xs">Reward Store →</a>
    </div>
    <div class="card p-4">
      <h3 class="text-sm font-semibold">Communities</h3>
      <ul class="mt-2 space-y-1 text-sm"><li><a href="/c/mindful-eating" class="underline">Mindful Eating</a> · 2.1k</li><li><a href="/c/herb-lab" class="underline">Herb Lab</a> · 1.4k</li></ul>
    </div>
    <div class="card p-4">
      <h3 class="text-sm font-semibold">Leaderboard (weekly)</h3>
      <ol class="mt-2 space-y-1 text-sm text-base-content/70"><li>1. amira · 920 pts</li><li>2. kenji · 840</li><li>3. priya · 790</li></ol>
    </div>
  </aside>
</div>
