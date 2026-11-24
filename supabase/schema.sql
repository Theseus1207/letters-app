-- =========================================================
-- 信箋與漂流瓶：Supabase 資料庫設定
-- 用法：Supabase 後台 → SQL Editor → 貼上整份 → Run
-- =========================================================
-- 設計重點：
--   * letters / blocks / reports 三張表開了 RLS 但「不給任何 policy」，
--     前端無法直接讀寫，只能透過下面的函式（RPC）操作。
--     這樣陌生人的帳號 id、暱稱都不會外流，漂流瓶才是真的匿名。
--   * profiles 只能看到、修改自己的那一筆。
-- =========================================================

-- ---------- 1. 使用者暱稱 ----------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null unique check (char_length(nickname) between 2 and 20),
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

drop policy if exists "read own profile"   on public.profiles;
drop policy if exists "create own profile" on public.profiles;
drop policy if exists "update own profile" on public.profiles;
create policy "read own profile"   on public.profiles for select to authenticated using (id = auth.uid());
create policy "create own profile" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "update own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------- 1b. 管理者、漂流瓶主題 ----------
-- 第一位管理者要用 SQL 指定（見 make-admin.sql），之後可以在 App 的「管理」頁新增其他管理者
create table if not exists public.admins (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;   -- 刻意不建 policy

create table if not exists public.topics (
  id          bigint generated always as identity primary key,
  emoji       text not null default '🌊' check (char_length(emoji) between 1 and 8),
  name        text not null unique check (char_length(btrim(name)) between 1 and 20),
  description text not null default '' check (char_length(description) <= 100),
  sort_order  int  not null default 0,
  is_active   boolean not null default true,     -- 停用：不能再丟這個主題的瓶子，也不會顯示在列表
  created_at  timestamptz not null default now()
);
alter table public.topics enable row level security;   -- 刻意不建 policy，讀寫都走函式

-- 預設主題（只有在一個主題都沒有時才會建立）
insert into public.topics (emoji, name, description, sort_order)
select * from (values
  ('💭', '心情', '說說今天的心情', 10),
  ('☀️', '日常', '生活裡的小事', 20),
  ('🌙', '深夜', '睡不著時想說的話', 30),
  ('🎵', '推薦', '好歌、好書、好店', 40),
  ('🤔', '煩惱', '想聽聽陌生人的建議', 50)
) as v(emoji, name, description, sort_order)
where not exists (select 1 from public.topics);

-- ---------- 2. 信件（一般信 + 漂流瓶共用） ----------
create table if not exists public.letters (
  id           bigint generated always as identity primary key,
  sender_id    uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid references public.profiles(id) on delete cascade,      -- 漂流中的瓶子是 null
  kind         text not null check (kind in ('letter', 'bottle')),
  status       text not null check (status in ('sent', 'floating', 'picked')),
  subject      text not null default '' check (char_length(subject) <= 100),
  body_html    text not null check (char_length(body_html) between 1 and 20000),
  reply_to     bigint references public.letters(id) on delete set null,
  topic_id     bigint references public.topics(id) on delete set null,  -- 漂流瓶的主題；主題被刪掉就變成「不限主題」
  picked_at    timestamptz,
  read_at      timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists letters_recipient_idx on public.letters (recipient_id, created_at desc);
create index if not exists letters_sender_idx    on public.letters (sender_id, created_at desc);
-- 舊版資料庫升級用：補上 topic_id 欄位
alter table public.letters add column if not exists topic_id bigint references public.topics(id) on delete set null;
create index if not exists letters_floating_idx  on public.letters (created_at) where status = 'floating';
create index if not exists letters_floating_topic_idx on public.letters (topic_id) where status = 'floating';
alter table public.letters enable row level security;   -- 刻意不建 policy

-- ---------- 3. 封鎖、檢舉 ----------
create table if not exists public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
alter table public.blocks enable row level security;

create table if not exists public.reports (
  id          bigint generated always as identity primary key,
  letter_id   bigint not null references public.letters(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  reason      text not null default '' check (char_length(reason) <= 500),
  created_at  timestamptz not null default now(),
  unique (letter_id, reporter_id)
);
alter table public.reports enable row level security;
-- 檢舉內容請到 Supabase 後台 Table Editor → reports 查看

-- ---------- 內部小工具 ----------
create or replace function public._is_blocked(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.blocks
    where (blocker_id = a and blocked_id = b) or (blocker_id = b and blocked_id = a)
  );
$$;

-- 寄信前的共同檢查：有登入、有暱稱、內容不是空的、沒超過每日上限
create or replace function public._check_can_write(me uuid, p_body text)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if me is null then raise exception '請先登入'; end if;
  if not exists (select 1 from public.profiles where id = me) then
    raise exception '請先設定暱稱';
  end if;
  if p_body is null
     or btrim(replace(regexp_replace(p_body, '<[^>]*>', '', 'g'), '&nbsp;', ' ')) = '' then
    raise exception '信件內容不能是空的';
  end if;
  if char_length(p_body) > 20000 then raise exception '信件太長了'; end if;
  if (select count(*) from public.letters
      where sender_id = me and created_at > now() - interval '1 day') >= 100 then
    raise exception '今天寄太多信了，明天再來吧';
  end if;
end $$;

-- ---------- 4. 對外的功能（前端用 supabase.rpc 呼叫） ----------

-- 寫信給指定暱稱
create or replace function public.send_letter(p_to text, p_subject text, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  target uuid;
  new_id bigint;
begin
  perform public._check_can_write(me, p_body);
  select id into target from public.profiles where nickname = btrim(p_to);
  -- 找不到和被封鎖用同一句話，避免透露「對方封鎖了你」
  if target is null or public._is_blocked(me, target) then
    raise exception '找不到這位收件人，或對方目前無法收信';
  end if;
  if target = me then raise exception '不能寫信給自己喔'; end if;

  insert into public.letters (sender_id, recipient_id, kind, status, subject, body_html)
  values (me, target, 'letter', 'sent', left(coalesce(btrim(p_subject), ''), 100), p_body)
  returning id into new_id;
  return new_id;
end $$;

-- 丟漂流瓶（每天最多 5 個）；p_topic_id 為 null 代表「不限主題」
drop function if exists public.throw_bottle(text, text);
create or replace function public.throw_bottle(p_subject text, p_body text, p_topic_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  new_id bigint;
begin
  perform public._check_can_write(me, p_body);
  if p_topic_id is not null and not exists (select 1 from public.topics where id = p_topic_id and is_active) then
    raise exception '這個主題已經關閉了，換一個吧';
  end if;
  if (select count(*) from public.letters
      where sender_id = me and kind = 'bottle' and reply_to is null
        and created_at > now() - interval '1 day') >= 5 then
    raise exception '今天已經丟了 5 個瓶子，明天再來吧';
  end if;

  insert into public.letters (sender_id, recipient_id, kind, status, subject, body_html, topic_id)
  values (me, null, 'bottle', 'floating', left(coalesce(btrim(p_subject), ''), 100), p_body, p_topic_id)
  returning id into new_id;
  return new_id;
end $$;

-- 撿漂流瓶（每天最多 10 個）；回傳撿到的信件 id，沒有瓶子時回傳 null
-- p_topic_id 為 null：任何主題都可以撿到
drop function if exists public.pick_bottle();
create or replace function public.pick_bottle(p_topic_id bigint default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  b bigint;
begin
  if me is null then raise exception '請先登入'; end if;
  if (select count(*) from public.letters
      where recipient_id = me and kind = 'bottle' and reply_to is null
        and picked_at > now() - interval '1 day') >= 10 then
    raise exception '今天已經撿了 10 個瓶子，讓海休息一下吧';
  end if;

  -- skip locked：兩個人同時撿，不會撿到同一個瓶子
  select l.id into b
  from public.letters l
  where l.status = 'floating'
    and l.sender_id <> me
    and not public._is_blocked(me, l.sender_id)
    and (p_topic_id is null or l.topic_id = p_topic_id)
  order by random()
  limit 1
  for update skip locked;

  if b is null then return null; end if;

  update public.letters
  set recipient_id = me, status = 'picked', picked_at = now()
  where id = b;
  return b;
end $$;

-- 回信（只能回寄給自己的信；漂流瓶的回信仍保持匿名）
create or replace function public.reply_letter(p_letter_id bigint, p_body text)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  orig public.letters%rowtype;
  new_id bigint;
begin
  perform public._check_can_write(me, p_body);
  select * into orig from public.letters where id = p_letter_id;
  if not found or orig.recipient_id is distinct from me then
    raise exception '只能回覆寄給你的信';
  end if;
  if public._is_blocked(me, orig.sender_id) then
    raise exception '目前無法回覆這封信';
  end if;

  insert into public.letters (sender_id, recipient_id, kind, status, subject, body_html, reply_to, topic_id)
  values (
    me, orig.sender_id, orig.kind, 'sent',
    left('Re: ' || regexp_replace(orig.subject, '^(Re: )+', ''), 100),
    p_body, orig.id, orig.topic_id
  )
  returning id into new_id;
  return new_id;
end $$;

-- 我的信箱（收到的 + 寄出的）。漂流瓶不回傳對方暱稱
drop function if exists public.my_mailbox();
create or replace function public.my_mailbox()
returns table (
  id bigint, kind text, status text, direction text, other_name text,
  subject text, body_html text, reply_to bigint, read_at timestamptz, created_at timestamptz,
  topic_emoji text, topic_name text
)
language sql stable security definer set search_path = public as $$
  select
    l.id, l.kind, l.status,
    case when l.sender_id = auth.uid() then 'out' else 'in' end,
    case
      when l.kind = 'bottle' then null
      when l.sender_id = auth.uid() then (select p.nickname from public.profiles p where p.id = l.recipient_id)
      else (select p.nickname from public.profiles p where p.id = l.sender_id)
    end,
    l.subject, l.body_html, l.reply_to, l.read_at,
    case when l.recipient_id = auth.uid() and l.picked_at is not null then l.picked_at else l.created_at end,
    t.emoji, t.name
  from public.letters l
  left join public.topics t on t.id = l.topic_id
  where (l.sender_id = auth.uid() or l.recipient_id = auth.uid())
    -- 封鎖之後，對方的信就不再出現在收件匣
    and not (
      l.recipient_id = auth.uid()
      and exists (select 1 from public.blocks bl where bl.blocker_id = auth.uid() and bl.blocked_id = l.sender_id)
    )
  order by 10 desc
  limit 300;
$$;

-- 標示已讀
create or replace function public.mark_read(p_letter_id bigint)
returns void language sql security definer set search_path = public as $$
  update public.letters set read_at = now()
  where id = p_letter_id and recipient_id = auth.uid() and read_at is null;
$$;

-- 用信件封鎖寄件人（漂流瓶看不到對方是誰，所以用信件 id 封鎖）
create or replace function public.block_sender(p_letter_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  s uuid;
begin
  select sender_id into s from public.letters where id = p_letter_id and recipient_id = me;
  if s is null then raise exception '找不到這封信'; end if;
  insert into public.blocks (blocker_id, blocked_id) values (me, s) on conflict do nothing;
end $$;

-- 檢舉信件
create or replace function public.report_letter(p_letter_id bigint, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if not exists (select 1 from public.letters where id = p_letter_id and recipient_id = me) then
    raise exception '只能檢舉寄給你的信';
  end if;
  insert into public.reports (letter_id, reporter_id, reason)
  values (p_letter_id, me, left(coalesce(p_reason, ''), 500))
  on conflict do nothing;
end $$;

-- ---------- 5. 權限：只有登入的人能呼叫對外函式，內部工具誰都不能直接呼叫 ----------
revoke execute on function public._is_blocked(uuid, uuid)       from public, anon, authenticated;
revoke execute on function public._check_can_write(uuid, text)  from public, anon, authenticated;

revoke execute on function public.send_letter(text, text, text)  from public, anon;
revoke execute on function public.throw_bottle(text, text, bigint) from public, anon;
revoke execute on function public.pick_bottle(bigint)            from public, anon;
revoke execute on function public.reply_letter(bigint, text)     from public, anon;
revoke execute on function public.my_mailbox()                   from public, anon;
revoke execute on function public.mark_read(bigint)              from public, anon;
revoke execute on function public.block_sender(bigint)           from public, anon;
revoke execute on function public.report_letter(bigint, text)    from public, anon;

grant execute on function public.send_letter(text, text, text)  to authenticated;
grant execute on function public.throw_bottle(text, text, bigint) to authenticated;
grant execute on function public.pick_bottle(bigint)            to authenticated;
grant execute on function public.reply_letter(bigint, text)     to authenticated;
grant execute on function public.my_mailbox()                   to authenticated;
grant execute on function public.mark_read(bigint)              to authenticated;
grant execute on function public.block_sender(bigint)           to authenticated;
grant execute on function public.report_letter(bigint, text)    to authenticated;

-- =========================================================
-- 6. 推播訂閱（每個人每台裝置一筆）
-- =========================================================
create extension if not exists pg_net with schema extensions;

create table if not exists public.push_subscriptions (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  endpoint   text not null unique check (char_length(endpoint) <= 1000 and endpoint like 'https://%'),
  p256dh     text not null check (char_length(p256dh) <= 200),
  auth       text not null check (char_length(auth) <= 100),
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;   -- 刻意不建 policy

-- 儲存這台裝置的推播訂閱（同一台裝置換帳號登入時，會改綁新帳號）
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
begin
  if me is null then raise exception '請先登入'; end if;
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth)
  values (me, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
  -- 每人最多保留 10 台裝置
  delete from public.push_subscriptions
  where user_id = me and id not in (
    select id from public.push_subscriptions where user_id = me order by created_at desc limit 10
  );
end $$;

-- 登出時移除這台裝置的訂閱
create or replace function public.delete_push_subscription(p_endpoint text)
returns void language sql security definer set search_path = public as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- 呼叫 Edge Function 發推播。網址與密碼存在 Supabase Vault（見 setup-push.sql）
-- 還沒設定時會直接跳過，不影響其他功能
create or replace function public._send_push(p_user uuid, p_type text, p_kind text, p_letter_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  fn_url    text;
  fn_secret text;
  unread    int;
begin
  if not exists (select 1 from public.push_subscriptions where user_id = p_user) then return; end if;
  select decrypted_secret into fn_url    from vault.decrypted_secrets where name = 'push_function_url';
  select decrypted_secret into fn_secret from vault.decrypted_secrets where name = 'push_webhook_secret';
  if fn_url is null or fn_secret is null then return; end if;

  select count(*) into unread
  from public.letters l
  where l.recipient_id = p_user and l.read_at is null
    and not exists (select 1 from public.blocks b where b.blocker_id = p_user and b.blocked_id = l.sender_id);

  perform net.http_post(
    url     := fn_url,
    body    := jsonb_build_object('user_id', p_user, 'type', p_type, 'kind', p_kind,
                                  'letter_id', p_letter_id, 'unread', unread),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', fn_secret),
    timeout_milliseconds := 5000
  );
end $$;

revoke execute on function public.save_push_subscription(text, text, text) from public, anon;
revoke execute on function public.delete_push_subscription(text)          from public, anon;
grant  execute on function public.save_push_subscription(text, text, text) to authenticated;
grant  execute on function public.delete_push_subscription(text)          to authenticated;
revoke execute on function public._send_push(uuid, text, text, bigint)    from public, anon, authenticated;

-- =========================================================
-- 7. 通知觸發器
--    * 有人寄信 / 回信給你 → new_letter
--    * 你丟的漂流瓶被撿到 → bottle_picked（不透露是誰撿的）
--    同時送兩種：
--      a. Realtime（App 開著時，畫面立刻更新）
--      b. Web Push（App 關著也會跳通知）
-- =========================================================
create or replace function public._notify_letter()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  target uuid;
  ev     text;
begin
  if tg_op = 'INSERT' and new.recipient_id is not null then
    target := new.recipient_id; ev := 'new_letter';
  elsif tg_op = 'UPDATE' and old.status = 'floating' and new.status = 'picked' then
    target := new.sender_id; ev := 'bottle_picked';
  else
    return null;
  end if;

  begin
    perform realtime.send(jsonb_build_object('id', new.id, 'kind', new.kind),
                          ev, 'inbox:' || target::text, true);
  exception when others then null;   -- 通知失敗不影響寄信
  end;

  begin
    perform public._send_push(target, ev, new.kind, new.id);
  exception when others then null;
  end;

  return null;
end $$;
revoke execute on function public._notify_letter() from public, anon, authenticated;

drop trigger if exists letters_notify on public.letters;
create trigger letters_notify
  after insert or update of status on public.letters
  for each row execute function public._notify_letter();

-- Realtime：每位使用者的私人頻道 inbox:<id>，只有本人能收聽
drop policy if exists "receive own inbox notifications" on realtime.messages;
create policy "receive own inbox notifications" on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'broadcast'
    and (select realtime.topic()) = 'inbox:' || (select auth.uid())::text
  );

-- =========================================================
-- 8. 漂流瓶主題與管理者
-- =========================================================

-- 目前登入的人是不是管理者（App 用來決定要不要顯示「管理」頁）
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public._require_admin()
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception '只有管理者可以這樣做'; end if;
end $$;

-- 主題列表：一般人只看到啟用中的；管理者看到全部
-- floating_count：現在海上有幾個這個主題、可以撿的瓶子
create or replace function public.list_topics()
returns table (
  id bigint, emoji text, name text, description text,
  sort_order int, is_active boolean, floating_count bigint
)
language sql stable security definer set search_path = public as $$
  select t.id, t.emoji, t.name, t.description, t.sort_order, t.is_active,
    (select count(*) from public.letters l
      where l.topic_id = t.id and l.status = 'floating' and l.sender_id <> auth.uid())
  from public.topics t
  where t.is_active or public.is_admin()
  order by t.sort_order, t.id;
$$;

-- 新增（p_id 為 null）或修改主題
create or replace function public.admin_save_topic(
  p_id bigint, p_emoji text, p_name text, p_description text, p_is_active boolean default true
)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  new_id bigint;
begin
  perform public._require_admin();
  if coalesce(btrim(p_name), '') = '' then raise exception '主題名稱不能是空的'; end if;
  begin
    if p_id is null then
      insert into public.topics (emoji, name, description, is_active, sort_order)
      values (coalesce(nullif(btrim(p_emoji), ''), '🌊'), btrim(p_name), coalesce(btrim(p_description), ''),
              coalesce(p_is_active, true),
              (select coalesce(max(sort_order), 0) + 10 from public.topics))
      returning id into new_id;
    else
      update public.topics
      set emoji = coalesce(nullif(btrim(p_emoji), ''), '🌊'), name = btrim(p_name),
          description = coalesce(btrim(p_description), ''), is_active = coalesce(p_is_active, is_active)
      where id = p_id
      returning id into new_id;
      if new_id is null then raise exception '找不到這個主題'; end if;
    end if;
  exception
    when unique_violation then raise exception '已經有叫「%」的主題了', btrim(p_name);
    when check_violation then raise exception '名稱最多 20 字、說明最多 100 字、圖示最多 8 個字元';
  end;
  return new_id;
end $$;

-- 刪除主題：這個主題的瓶子會保留，變成「不限主題」
create or replace function public.admin_delete_topic(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._require_admin();
  delete from public.topics where id = p_id;
end $$;

-- 調整順序：p_dir = -1 往上，1 往下
create or replace function public.admin_move_topic(p_id bigint, p_dir int)
returns void language plpgsql security definer set search_path = public as $$
declare
  cur int; nid bigint; nsort int;
begin
  perform public._require_admin();
  -- 先把順序重新編號成 10, 20, 30…，避免有相同的號碼
  update public.topics t set sort_order = r.rn * 10
  from (select id, row_number() over (order by sort_order, id) as rn from public.topics) r
  where t.id = r.id;

  select sort_order into cur from public.topics where id = p_id;
  if cur is null then raise exception '找不到這個主題'; end if;
  if p_dir < 0 then
    select id, sort_order into nid, nsort from public.topics where sort_order < cur order by sort_order desc limit 1;
  else
    select id, sort_order into nid, nsort from public.topics where sort_order > cur order by sort_order asc limit 1;
  end if;
  if nid is null then return; end if;
  update public.topics set sort_order = nsort where id = p_id;
  update public.topics set sort_order = cur  where id = nid;
end $$;

-- 管理者名單
create or replace function public.admin_list_admins()
returns table (nickname text, is_me boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public._require_admin();
  return query
    select p.nickname, p.id = auth.uid()
    from public.admins a join public.profiles p on p.id = a.user_id
    order by a.created_at;
end $$;

create or replace function public.admin_add_admin(p_nickname text)
returns void language plpgsql security definer set search_path = public as $$
declare
  target uuid;
begin
  perform public._require_admin();
  select id into target from public.profiles where nickname = btrim(p_nickname);
  if target is null then raise exception '找不到暱稱「%」的使用者', btrim(p_nickname); end if;
  insert into public.admins (user_id) values (target) on conflict do nothing;
end $$;

create or replace function public.admin_remove_admin(p_nickname text)
returns void language plpgsql security definer set search_path = public as $$
declare
  target uuid;
begin
  perform public._require_admin();
  select a.user_id into target
  from public.admins a join public.profiles p on p.id = a.user_id
  where p.nickname = btrim(p_nickname);
  if target is null then raise exception '這位不是管理者'; end if;
  if (select count(*) from public.admins) <= 1 then raise exception '至少要保留一位管理者'; end if;
  delete from public.admins where user_id = target;
end $$;

revoke execute on function public._require_admin() from public, anon, authenticated;
revoke execute on function public.is_admin()                                        from public, anon;
revoke execute on function public.list_topics()                                     from public, anon;
revoke execute on function public.admin_save_topic(bigint, text, text, text, boolean) from public, anon;
revoke execute on function public.admin_delete_topic(bigint)                        from public, anon;
revoke execute on function public.admin_move_topic(bigint, int)                     from public, anon;
revoke execute on function public.admin_list_admins()                               from public, anon;
revoke execute on function public.admin_add_admin(text)                             from public, anon;
revoke execute on function public.admin_remove_admin(text)                          from public, anon;
grant execute on function public.is_admin()                                        to authenticated;
grant execute on function public.list_topics()                                     to authenticated;
grant execute on function public.admin_save_topic(bigint, text, text, text, boolean) to authenticated;
grant execute on function public.admin_delete_topic(bigint)                        to authenticated;
grant execute on function public.admin_move_topic(bigint, int)                     to authenticated;
grant execute on function public.admin_list_admins()                               to authenticated;
grant execute on function public.admin_add_admin(text)                             to authenticated;
grant execute on function public.admin_remove_admin(text)                          to authenticated;
