-- スタログ:大会(全国大会の個人の部+グループ対抗の部)
-- Supabase の SQL Editor に全部貼り付けて Run を押す。何回実行しても大丈夫。
--
-- ・大会を開けるのは運営(app_admins に入っている人)だけ
-- ・個人の部:全員が出る。ランキング用の名前を決めている人はその名前、決めていない人は「匿名の勉強家」で載る
-- ・グループ対抗の部:運営が出場させたグループだけが出る。メンバー全員の合計時間で順位を決める
-- ・数える時間はランキングと同じ(1本で数えるのは、前に撮ってから実際にたった時間まで)

-- ========== 運営 ==========
create table if not exists public.app_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.app_admins enable row level security;  -- 決まりを作らないので、画面からは誰も読めない

-- 運営として自分を登録する
insert into public.app_admins (user_id)
  select id from auth.users where email = 'yoshitaro726kitamura@icloud.com'
  on conflict do nothing;

create or replace function public.is_app_admin()
returns boolean language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.app_admins where user_id = auth.uid());
$$;

-- ========== 大会 ==========
create table if not exists public.tournaments (
  id         bigint generated always as identity primary key,
  name       text not null check (char_length(name) between 1 and 30),
  starts_on  date not null,
  ends_on    date not null,
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on and ends_on - starts_on <= 30)
);
alter table public.tournaments enable row level security;
drop policy if exists "tournaments_select" on public.tournaments;
create policy "tournaments_select" on public.tournaments for select to authenticated using (true);

alter table public.tournaments add column if not exists prize text check (prize is null or char_length(prize) <= 100);
alter table public.groups add column if not exists contest_opt_in boolean not null default false;

drop function if exists public.create_tournament(text, date, date);
create or replace function public.create_tournament(nm text, s date, e date, pz text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare n text := btrim(coalesce(nm, '')); p text := nullif(btrim(coalesce(pz, '')), ''); new_id bigint;
begin
  if not public.is_app_admin() then raise exception 'not_admin'; end if;
  if char_length(n) not between 1 and 30 then raise exception 'bad_name'; end if;
  if s is null or e is null or e < s or e - s > 30 then raise exception 'bad_dates'; end if;
  if p is not null and char_length(p) > 100 then raise exception 'bad_prize'; end if;
  insert into public.tournaments (name, starts_on, ends_on, prize) values (n, s, e, p) returning id into new_id;
  return new_id;
end $$;

create or replace function public.delete_tournament(tid bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_app_admin() then raise exception 'not_admin'; end if;
  delete from public.tournaments where id = tid;
end $$;

-- グループ対抗に出す/出さない(運営だけが決める)
create or replace function public.set_group_contest(gid public.groups.id%type, opt boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_app_admin() then raise exception 'not_admin'; end if;
  update public.groups set contest_opt_in = opt where id = gid;
end $$;

-- 運営用:全部のグループの一覧(名前・人数・出場しているか)
create or replace function public.admin_list_groups()
returns table (id text, name text, members bigint, contest_opt_in boolean)
language plpgsql security definer set search_path = public stable as $$
begin
  if not public.is_app_admin() then raise exception 'not_admin'; end if;
  return query
    select gr.id::text, gr.name, count(gm.user_id), gr.contest_opt_in
    from public.groups gr left join public.group_members gm on gm.group_id = gr.id
    group by gr.id, gr.name, gr.contest_opt_in
    order by gr.contest_opt_in desc, count(gm.user_id) desc, gr.name;
end $$;

-- 期間中に数える時間(中だけで使う。画面からは直接呼べない)
create or replace function public._credited(d_from date, d_to date)
returns table (user_id uuid, minutes bigint)
language sql security definer set search_path = public stable as $$
  with c as (
    select c.user_id, c.day_key::date as d, c.ts, c.minutes,
           lag(c.ts) over (partition by c.user_id, c.day_key order by c.ts) as prev_ts
    from public.clips c
    where c.day_key::date between d_from and d_to
  )
  select user_id,
         sum(least(minutes, greatest(0, floor(extract(epoch from (
           ts - coalesce(prev_ts, ((d + time '04:00') at time zone 'Asia/Tokyo'))
         )) / 60))))::bigint
  from c group by user_id;
$$;

-- 個人の部(全員参加。上位50人と自分)
create or replace function public.get_tournament_people(tid bigint)
returns table (rank bigint, name text, minutes bigint, is_me boolean)
language sql security definer set search_path = public stable as $$
  with t as (select starts_on, ends_on from public.tournaments where id = tid),
  cr as (select * from public._credited((select starts_on from t), (select ends_on from t))),
  ranked as (
    select cr.user_id, cr.minutes, rank() over (order by cr.minutes desc) as r
    from cr
    where cr.minutes > 0
  )
  select ranked.r,
         case when p.rank_opt_in and p.rank_name is not null then p.rank_name else '匿名の勉強家' end,
         ranked.minutes, ranked.user_id = auth.uid()
  from ranked left join public.profiles p on p.id = ranked.user_id
  where ranked.r <= 50 or ranked.user_id = auth.uid()
  order by ranked.r;
$$;

-- グループ対抗の部(出ると決めたグループ・合計時間。上位30グループと自分のグループ)
drop function if exists public.get_tournament_groups(bigint);
create or replace function public.get_tournament_groups(tid bigint)
returns table (rank bigint, name text, members bigint, total_minutes bigint, is_mine boolean)
language sql security definer set search_path = public stable as $$
  with t as (select starts_on, ends_on from public.tournaments where id = tid),
  cr as (select * from public._credited((select starts_on from t), (select ends_on from t))),
  g as (
    select gr.id, gr.name, count(gm.user_id) as members,
           coalesce(sum(cr.minutes), 0)::bigint as total_minutes,
           bool_or(gm.user_id = auth.uid()) as is_mine
    from public.groups gr
    join public.group_members gm on gm.group_id = gr.id
    left join cr on cr.user_id = gm.user_id
    where gr.contest_opt_in
    group by gr.id, gr.name
  ),
  ranked as (select g.*, rank() over (order by total_minutes desc) as r from g)
  select r, name, members, total_minutes, coalesce(is_mine, false)
  from ranked
  where r <= 30 or is_mine
  order by r, name;
$$;

-- 画面から呼べるのはログインしている人だけ(ログインしていない人や、中だけで使うものは呼べない)
do $$
declare f text;
begin
  foreach f in array array[
    'public.is_app_admin()', 'public.create_tournament(text, date, date, text)', 'public.delete_tournament(bigint)',
    'public.set_group_contest(' || format_type((select atttypid from pg_attribute where attrelid = 'public.groups'::regclass and attname = 'id'), null) || ', boolean)',
    'public.get_tournament_people(bigint)', 'public.get_tournament_groups(bigint)', 'public._credited(date, date)', 'public.admin_list_groups()',
    'public.set_ranking(boolean, text)', 'public.my_ranking()', 'public.get_ranking(text)'
  ] loop
    if to_regprocedure(f) is not null then
      execute format('revoke all on function %s from public, anon', f);
      if f <> 'public._credited(date, date)' then
        execute format('grant execute on function %s to authenticated', f);
      else
        execute format('revoke all on function %s from authenticated', f);
      end if;
    end if;
  end loop;
end $$;
