-- スタログ:大会のメダル(1位🥇・2位🥈・3位🥉)
-- Supabase の SQL Editor に全部貼り付けて Run を押す。何回実行しても大丈夫。
-- 先に 2026-10-ranking.sql と 2026-10-tournament.sql を実行しておくこと。
--
-- ・大会が終わったら、運営が「結果を確定してメダルを配る」を押す(finalize_tournament)
-- ・確定したときの個人の部の順位を、記録した人全員の分残す(同じ時間の人は同じ順位)
-- ・1〜3位にメダルが付き、ずっと名前の横に表示される
-- ・記録した人には、次に開いたとき「おめでとう!あなたは○位入賞」が出る

create table if not exists public.tournament_results (
  tournament_id bigint not null references public.tournaments(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  place         int not null check (place >= 1),
  minutes       bigint not null,
  primary key (tournament_id, user_id)
);
alter table public.tournament_results enable row level security;
-- 画面から直接読めるのは自分の結果だけ(メダルは get_medals で配る)
drop policy if exists "results_select" on public.tournament_results;
create policy "results_select" on public.tournament_results for select to authenticated using (user_id = auth.uid());

-- 結果を確定した日時(確定していなければ空)
alter table public.tournaments add column if not exists finalized_at timestamptz;

-- 結果を確定してメダルを配る(運営だけ。大会が終わってから)
create or replace function public.finalize_tournament(tid bigint)
returns int language plpgsql security definer set search_path = public as $$
declare t record; n int;
begin
  if not public.is_app_admin() then raise exception 'not_admin'; end if;
  select * into t from public.tournaments where id = tid;
  if not found then raise exception 'not_found'; end if;
  if ((now() at time zone 'Asia/Tokyo') - interval '4 hours')::date <= t.ends_on then raise exception 'not_ended'; end if;
  delete from public.tournament_results where tournament_id = tid;
  insert into public.tournament_results (tournament_id, user_id, place, minutes)
    select tid, user_id, rank() over (order by minutes desc), minutes
    from public._credited(t.starts_on, t.ends_on) where minutes > 0;
  get diagnostics n = row_count;
  update public.tournaments set finalized_at = now() where id = tid;
  return n;
end $$;

-- メダルの一覧(人ごとに、取ったメダルを良い順に並べた文字。例:🥇🥈)
create or replace function public.get_medals()
returns table (user_id uuid, medals text)
language sql security definer set search_path = public stable as $$
  select a.user_id,
         string_agg(case a.place when 1 then '🥇' when 2 then '🥈' else '🥉' end, '' order by a.place, a.tournament_id)
  from public.tournament_results a
  where a.place <= 3
  group by a.user_id;
$$;

-- 自分の大会結果(「おめでとう」の表示用)。participants は記録した人の数
create or replace function public.my_tournament_results()
returns table (tournament_id bigint, name text, prize text, place int, minutes bigint, participants bigint)
language sql security definer set search_path = public stable as $$
  select r.tournament_id, t.name, t.prize, r.place, r.minutes,
         (select count(*) from public.tournament_results x where x.tournament_id = r.tournament_id)
  from public.tournament_results r join public.tournaments t on t.id = r.tournament_id
  where r.user_id = auth.uid()
  order by r.tournament_id desc;
$$;

-- ランキングと大会の個人の部に、メダルの列を足す(戻り値が変わるので作り直す)
drop function if exists public.get_ranking(text);
create function public.get_ranking(period text)
returns table (rank bigint, name text, minutes bigint, is_me boolean, medals text)
language sql security definer set search_path = public stable as $$
  with k as (
    select to_char((now() at time zone 'Asia/Tokyo') - interval '4 hours', 'YYYY-MM-DD') as today,
           to_char((now() at time zone 'Asia/Tokyo') - interval '4 hours' - interval '6 days', 'YYYY-MM-DD') as week_start
  ),
  cr as (
    select * from public._credited(
      (select (case when period = 'week' then week_start else today end)::date from k),
      (select today::date from k))
  ),
  ranked as (
    select cr.user_id, cr.minutes, rank() over (order by cr.minutes desc) as r
    from cr join public.profiles p on p.id = cr.user_id and p.rank_opt_in
    where cr.minutes > 0
  )
  select ranked.r, coalesce(p.rank_name, '名無し'), ranked.minutes, ranked.user_id = auth.uid(), m.medals
  from ranked join public.profiles p on p.id = ranked.user_id
  left join public.get_medals() m on m.user_id = ranked.user_id
  where ranked.r <= 50 or ranked.user_id = auth.uid()
  order by ranked.r, p.rank_name;
$$;

drop function if exists public.get_tournament_people(bigint);
create function public.get_tournament_people(tid bigint)
returns table (rank bigint, name text, minutes bigint, is_me boolean, medals text)
language sql security definer set search_path = public stable as $$
  with t as (select starts_on, ends_on from public.tournaments where id = tid),
  cr as (select * from public._credited((select starts_on from t), (select ends_on from t))),
  ranked as (
    select cr.user_id, cr.minutes, rank() over (order by cr.minutes desc) as r
    from cr where cr.minutes > 0
  )
  select ranked.r,
         coalesce(case when p.rank_opt_in then p.rank_name end, p.name, '名無し'),
         ranked.minutes, ranked.user_id = auth.uid(), m.medals
  from ranked left join public.profiles p on p.id = ranked.user_id
  left join public.get_medals() m on m.user_id = ranked.user_id
  where ranked.r <= 50 or ranked.user_id = auth.uid()
  order by ranked.r;
$$;

do $$
declare f text;
begin
  foreach f in array array['public.finalize_tournament(bigint)', 'public.get_medals()', 'public.my_tournament_results()', 'public.get_ranking(text)', 'public.get_tournament_people(bigint)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
