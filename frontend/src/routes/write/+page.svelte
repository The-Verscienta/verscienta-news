<script lang="ts">
  let title = ''; let body = '';
  async function publish() {
    const res = await fetch('http://localhost:4000/api/json', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ data: { type: 'article', attributes: { title, blocks: [{ _type: 'rich_text', content: body }] } } }) });
    alert(res.ok ? 'Draft created (check /editor in Kiln)' : `Failed ${res.status}`);
  }
</script>

<div class="mx-auto max-w-3xl card p-6">
  <h1 class="font-serif text-xl font-semibold">Write an article</h1>
  <p class="mt-1 text-sm text-base-content/60">Rich markdown + TipTap. Images/video via Kiln Media. This demo posts a draft to <code>/api/json</code>.</p>
  <input class="field-input mt-4" placeholder="Title" bind:value={title} />
  <textarea class="field-input mt-3 min-h-40" placeholder="Body (markdown)" bind:value={body}></textarea>
  <button class="btn btn-primary mt-4" on:click={publish}>Publish draft</button>
</div>
