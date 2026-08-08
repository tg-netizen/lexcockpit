-- Allow the LexCockpit Mac app (anon / publishable key) to READ the waiting list.
-- The view uses security_invoker, so RLS on base tables must allow anon SELECT
-- for queued rows (+ news_sources for the join). Writes stay service-role only.

grant select on public.review_queue to anon, authenticated;

-- Base tables used by review_queue (security_invoker = true)
drop policy if exists "Anon read queued ingested_items" on public.ingested_items;
create policy "Anon read queued ingested_items"
  on public.ingested_items for select
  to anon
  using (status = 'queued');

drop policy if exists "Anon read news_sources" on public.news_sources;
create policy "Anon read news_sources"
  on public.news_sources for select
  to anon
  using (true);

-- Explicitly no write path for anon
revoke insert, update, delete on public.ingested_items from anon;
revoke insert, update, delete on public.articles from anon;
revoke insert, update, delete on public.news_sources from anon;
revoke insert, update, delete on public.pipeline_runs from anon;
