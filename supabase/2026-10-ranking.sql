-- スタログ:全国勉強時間ランキング
-- Supabase の SQL Editor に全部貼り付けて Run を押す。何回実行しても大丈夫。
--
-- ・ランキングに載るのは「参加する」を選んだ人だけ。名前はランキング用の名前(本名でなくてよい)
-- ・ごまかし防止:1本の記録で数えるのは「前に撮ってから実際にたった時間」まで
--   (その日の1本目は朝4時から)。2秒ずつ連打して5時間ずつ足す、ができない

alter table public.profiles add column if not exists rank_opt_in boolean not null default false;
alter table public.profiles add column if not exists rank_name text;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_rank_name_len') then
    alter table public.profiles add constraint profiles_rank_name_len check (rank_name is null or char_length(rank_name) between 1 and 12);
  end if;
end $$;

-- 参加する/やめる、ランキング用の名前を変える(自分の分だけ)
create or replace function public.set_ranking(opt boolean, nm text)
returns void language plpgsql security definer set search_path = public as $$
declare n text := nullif(btrim(coalesce(nm, '')), '');
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  if opt and n is null then raise exception 'name_required'; end if;
  if n is not null and char_length(n) > 12 then raise exception 'name_too_long'; end if;
  update public.profiles set rank_opt_in = opt, rank_name = coalesce(n, rank_name) where id = auth.uid();
end $$;

-- 自分が参加しているか
create or replace function public.my_ranking()
returns table (opt_in boolean, rank_name text)
language sql security definer set search_path = public stable as $$
  select p.rank_opt_in, p.rank_name from public.profiles p where p.id = auth.uid();
$$;

-- ランキング(period:'today' か 'week')。上位50人と自分の順位を返す
create or replace function public.get_ranking(period text)
returns table (rank bigint, name text, minutes bigint, is_me boolean)
language sql security definer set search_path = public stable as $$
  with k as (
    select to_char((now() at time zone 'Asia/Tokyo') - interval '4 hours', 'YYYY-MM-DD') as today,
           to_char((now() at time zone 'Asia/Tokyo') - interval '4 hours' - interval '6 days', 'YYYY-MM-DD') as week_start
  ),
  c as (
    select c.user_id, c.day_key::date as d, c.ts, c.minutes,
           lag(c.ts) over (partition by c.user_id, c.day_key order by c.ts) as prev_ts
    from public.clips c
    join public.profiles p on p.id = c.user_id and p.rank_opt_in
    cross join k
    where c.day_key::date <= k.today::date
      and c.day_key::date >= (case when period = 'week' then k.week_start else k.today end)::date
  ),
  credited as (
    select user_id,
           least(minutes, greatest(0, floor(extract(epoch from (
             ts - coalesce(prev_ts, ((d + time '04:00') at time zone 'Asia/Tokyo'))
           )) / 60)))::bigint as m
    from c
  ),
  tot as (
    select user_id, sum(m) as minutes from credited group by user_id having sum(m) > 0
  ),
  ranked as (
    select user_id, minutes, rank() over (order by minutes desc) as r from tot
  )
  select ranked.r, coalesce(p.rank_name, '名無し'), ranked.minutes, ranked.user_id = auth.uid()
  from ranked join public.profiles p on p.id = ranked.user_id
  where ranked.r <= 50 or ranked.user_id = auth.uid()
  order by ranked.r, p.rank_name;
$$;

revoke all on function public.set_ranking(boolean, text) from public;
revoke all on function public.my_ranking() from public;
revoke all on function public.get_ranking(text) from public;
grant execute on function public.set_ranking(boolean, text) to authenticated;
grant execute on function public.my_ranking() to authenticated;
grant execute on function public.get_ranking(text) to authenticated;
