-- スタログ:「ナイス(👏)」と「みんなで目標」のための設定
-- Supabase の SQL Editor に全部貼り付けて Run を押す。何回実行しても大丈夫。

-- ========== ① ナイス(👏) ==========
-- clips.id の型(bigint / uuid など)に合わせて表を作る
do $$
declare t text;
begin
  select format_type(a.atttypid, a.atttypmod) into t
  from pg_attribute a
  where a.attrelid = 'public.clips'::regclass and a.attname = 'id';
  execute format($f$
    create table if not exists public.reactions (
      clip_id    %s not null references public.clips(id) on delete cascade,
      user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
      created_at timestamptz not null default now(),
      primary key (clip_id, user_id)
    )$f$, t);
end $$;

alter table public.reactions enable row level security;

-- 見られる動画(=同じグループの動画)のナイスだけ見られる
drop policy if exists "reactions_select" on public.reactions;
create policy "reactions_select" on public.reactions for select to authenticated
  using (exists (select 1 from public.clips c where c.id = clip_id));

-- 自分の名前で、見られる動画に、他人の動画にだけナイスできる
drop policy if exists "reactions_insert" on public.reactions;
create policy "reactions_insert" on public.reactions for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.clips c where c.id = clip_id and c.user_id <> auth.uid())
  );

-- 取り消せるのは自分のナイスだけ
drop policy if exists "reactions_delete" on public.reactions;
create policy "reactions_delete" on public.reactions for delete to authenticated
  using (user_id = auth.uid());

-- ========== ② みんなで目標 ==========
alter table public.groups add column if not exists goal_minutes int not null default 600;

-- 目標を変えられるのはそのグループのメンバーだけ(30分〜100時間)
create or replace function public.set_group_goal(gid public.groups.id%type, minutes int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if minutes < 30 or minutes > 6000 then raise exception 'bad_goal'; end if;
  if not exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid()) then
    raise exception 'not_member';
  end if;
  update public.groups set goal_minutes = minutes where id = gid;
end $$;

revoke all on function public.set_group_goal(public.groups.id%type, int) from public;
grant execute on function public.set_group_goal(public.groups.id%type, int) to authenticated;
