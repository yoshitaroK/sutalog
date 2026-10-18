-- スタログ:グループのチャット
-- Supabase の SQL Editor に全部貼り付けて Run を押す。何回実行しても大丈夫。

-- groups.id の型に合わせて表を作る
do $$
declare t text;
begin
  select format_type(a.atttypid, a.atttypmod) into t
  from pg_attribute a
  where a.attrelid = 'public.groups'::regclass and a.attname = 'id';
  execute format($f$
    create table if not exists public.messages (
      id         bigint generated always as identity primary key,
      group_id   %s not null references public.groups(id) on delete cascade,
      user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
      body       text not null check (char_length(body) between 1 and 500),
      created_at timestamptz not null default now()
    )$f$, t);
end $$;

create index if not exists messages_group_time on public.messages (group_id, created_at desc);

alter table public.messages enable row level security;

-- 読めるのはそのグループのメンバーだけ
drop policy if exists "messages_select" on public.messages;
create policy "messages_select" on public.messages for select to authenticated
  using (exists (select 1 from public.group_members m where m.group_id = messages.group_id and m.user_id = auth.uid()));

-- 書けるのはメンバーが自分の名前でだけ
drop policy if exists "messages_insert" on public.messages;
create policy "messages_insert" on public.messages for insert to authenticated
  with check (
    user_id = auth.uid()
    and exists (select 1 from public.group_members m where m.group_id = messages.group_id and m.user_id = auth.uid())
  );

-- 消せるのは自分のメッセージだけ
drop policy if exists "messages_delete" on public.messages;
create policy "messages_delete" on public.messages for delete to authenticated
  using (user_id = auth.uid());

-- 新しいメッセージをすぐ届ける(リアルタイム)
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'messages') then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;
