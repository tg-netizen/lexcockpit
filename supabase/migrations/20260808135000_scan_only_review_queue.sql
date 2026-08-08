-- Free scan-only mode: interesting RSS hits land on a waiting list (`queued`)
-- for human review. No LLM / no auto-drafts required.

alter table public.ingested_items
  drop constraint if exists ingested_items_status_check;

alter table public.ingested_items
  add constraint ingested_items_status_check
  check (status in (
    'fetched', 'evaluated', 'queued', 'rejected', 'drafted', 'error', 'duplicate'
  ));

comment on column public.ingested_items.status is
  'fetched → evaluated → queued (waiting list) | rejected | drafted | error';

-- Human review waiting list (keyword-flagged, not yet drafted)
create or replace view public.review_queue
with (security_invoker = true)
as
select
  i.id,
  i.title,
  i.source_url,
  i.snippet,
  i.published_at,
  i.relevance_score,
  i.relevance_reason,
  i.status,
  i.created_at,
  s.name as source_name,
  s.slug as source_slug,
  s.region
from public.ingested_items i
left join public.news_sources s on s.id = i.source_id
where i.status = 'queued'
order by i.relevance_score desc nulls last, i.created_at desc;

grant select on public.review_queue to authenticated;
