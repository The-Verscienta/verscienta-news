<script lang="ts">
  import '../app.css';
</script>

<header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/80 backdrop-blur supports-[backdrop-filter]:bg-base-100/70">
  <div class="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-3">
    <a href="/" class="flex items-center gap-2 font-serif text-lg font-semibold tracking-tight">Verscienta<span class="text-primary">News</span></a>
    <nav class="hidden items-center gap-1 sm:flex">
      {#each ["Nutrition","Herbalism","Mindfulness","Movement","TCM","Ayurveda","Environment"] as cat}
        <a href="/category/{cat.toLowerCase()}" class="rounded-md px-2.5 py-1.5 text-sm text-base-content/70 hover:bg-base-200 hover:text-base-content">{cat}</a>
      {/each}
    </nav>
    <div class="flex items-center gap-2">
      <a href="/search" class="field-input w-32 sm:w-48" aria-label="Search">Search…</a>
      <a href="http://localhost:4000/editor" class="btn btn-primary text-sm">Write in Kiln</a>
    </div>
  </div>
</header>
<main class="mx-auto max-w-6xl px-4 py-6">
  <slot />
</main>
<footer class="border-t border-base-300 py-8 text-center text-xs text-base-content/50">
  Verscienta News · Wellness, curated. · <a href="http://localhost:4000/api/json/swaggerui" class="underline">API Docs</a>
</footer>
