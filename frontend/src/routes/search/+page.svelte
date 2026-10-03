<script lang="ts">
  let q = ''; let hits: unknown[] = [];
  async function doSearch() {
    const res = await fetch(`http://localhost:4000/api/search?query=${encodeURIComponent(q)}`);
    hits = res.ok ? ((await res.json()).results ?? []) : [];
  }
</script>

<div class="mx-auto max-w-3xl">
  <h1 class="font-serif text-xl font-semibold">Search</h1>
  <p class="text-sm text-base-content/60">Typo-tolerant, faceted search via Meilisearch (profile <code>search</code>). Falls back to Postgres FTS.</p>
  <div class="mt-4 flex gap-2"><input class="field-input flex-1" placeholder="e.g. ashwagandha dosage" bind:value={q} on:keydown={(e)=> e.key==='Enter' && doSearch()} /><button class="btn btn-primary" on:click={doSearch}>Search</button></div>
  <div class="mt-6 space-y-3">{#each hits as h}<div class="card p-3 text-sm">{JSON.stringify(h)}</div>{/each}</div>
</div>
