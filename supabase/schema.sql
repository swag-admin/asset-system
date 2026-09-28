-- =====================================================================
--  設備資產管理系統：資料庫結構
--  在 Supabase 專案的「SQL Editor」貼上整份檔案並按 Run，只需執行一次。
--  重複執行也安全（會略過已存在的物件並更新函式）。
-- =====================================================================

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------
-- 1. 資料表
-- ---------------------------------------------------------------------

-- 管理員／唯讀角色（一般員工不需要列在這裡，員工資料有 Email 即可登入）
create table if not exists public.roles (
  email      text primary key check (email = lower(email) and email like '%@%'),
  role       text not null check (role in ('admin','viewer')),
  created_at timestamptz not null default now()
);

create table if not exists public.settings (
  id         int primary key default 1 check (id = 1),
  company    text not null default '',
  app_url    text not null default '',
  categories text[] not null default array['筆記型電腦','桌上型電腦','螢幕','手機','平板','測試機','周邊配件','網路設備','辦公家具','其他'],
  terms      text not null default E'一、上列設備為公司財產，僅限公務使用。\n二、保管人應善盡保管責任，如因故意或重大過失致設備遺失或損壞，須依公司規定負賠償責任。\n三、離職或職務調動時，應將設備完整歸還行政部並辦理歸還手續。\n四、未經許可不得私自轉借、變賣、拆卸或更換設備零件。',
  updated_at timestamptz not null default now()
);
insert into public.settings (id) values (1) on conflict do nothing;

create table if not exists public.employees (
  id         uuid primary key default gen_random_uuid(),
  emp_no     text not null unique,
  name       text not null,
  dept       text not null default '',
  email      text,
  slack_id   text not null default '',
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists employees_email_uq on public.employees (lower(email)) where email is not null and email <> '';
create index if not exists employees_name_trgm on public.employees using gin (name gin_trgm_ops);

create table if not exists public.assets (
  id            uuid primary key default gen_random_uuid(),
  tag           text not null unique,
  name          text not null,
  cat           text not null default '其他',
  brand         text not null default '',
  model         text not null default '',
  serial        text not null default '',
  os            text not null default '',
  location      text not null default '',
  status        text not null default 'available'
                check (status in ('available','in_use','borrowed','repair','lost','retired')),
  holder_id     uuid references public.employees(id) on delete restrict,
  holder_name   text not null default '',          -- 由觸發器自動維護，供搜尋用
  due_date      date,
  purchase_date date,
  warranty_end  date,
  cost          numeric(12,0),
  note          text not null default '',
  photos        jsonb not null default '[]'::jsonb,  -- [{p: 原圖路徑, t: 縮圖路徑}]
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    text not null default '',
  search        text generated always as (
                  lower(tag || ' ' || name || ' ' || brand || ' ' || model || ' ' || serial || ' ' ||
                        os || ' ' || location || ' ' || cat || ' ' || note || ' ' || holder_name)
                ) stored,
  constraint borrowed_needs_due check (status <> 'borrowed' or due_date is not null),
  constraint held_needs_holder check (status not in ('in_use','borrowed') or holder_id is not null)
);
create index if not exists assets_search_trgm on public.assets using gin (search gin_trgm_ops);
create index if not exists assets_status_idx  on public.assets (status);
create index if not exists assets_cat_idx     on public.assets (cat);
create index if not exists assets_holder_idx  on public.assets (holder_id);
create index if not exists assets_updated_idx on public.assets (updated_at desc);
create index if not exists assets_name_idx    on public.assets (name);
create index if not exists assets_due_idx     on public.assets (due_date) where status = 'borrowed';

create table if not exists public.asset_events (
  id       bigint generated always as identity primary key,
  asset_id uuid not null references public.assets(id) on delete cascade,
  at       timestamptz not null default now(),
  by_email text not null default '',
  action   text not null
);
create index if not exists asset_events_asset_idx on public.asset_events (asset_id, at desc);

create table if not exists public.signoffs (
  id              uuid primary key default gen_random_uuid(),
  no              text not null unique,
  type            text not null check (type in ('issue','borrow','return','inventory')),
  employee_id     uuid references public.employees(id) on delete set null,
  employee_name   text not null,
  emp_no          text not null default '',
  dept            text not null default '',
  signer_email    text,                                -- 只有這個 Email 的人能線上簽名
  items           jsonb not null,
  created_at      timestamptz not null default now(),
  created_by      text not null default '',
  voided          boolean not null default false,
  paper_signed_at timestamptz,
  signed_at       timestamptz,
  signature       jsonb,                               -- {d: SVG 路徑, w, h}
  search          text generated always as (lower(no || ' ' || employee_name || ' ' || emp_no || ' ' || dept)) stored
);
create index if not exists signoffs_created_idx on public.signoffs (created_at desc);
create index if not exists signoffs_emp_idx     on public.signoffs (employee_id);
create index if not exists signoffs_signer_idx  on public.signoffs (lower(signer_email));
create index if not exists signoffs_pending_idx on public.signoffs (created_at desc)
  where not voided and signed_at is null and paper_signed_at is null;
create index if not exists signoffs_search_trgm on public.signoffs using gin (search gin_trgm_ops);

-- ---------------------------------------------------------------------
-- 2. 身分與權限輔助函式
-- ---------------------------------------------------------------------
create or replace function public.my_email() returns text
language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''))
$$;

create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from public.roles where email = public.my_email() and public.my_email() <> ''),
    case when exists (select 1 from public.employees
                      where lower(email) = public.my_email() and public.my_email() <> '' and active)
         then 'member' end)
$$;

create or replace function public.is_admin() returns boolean
language sql stable as $$ select public.app_role() = 'admin' $$;

create or replace function public.is_staff() returns boolean
language sql stable as $$ select public.app_role() in ('admin','viewer') $$;

create or replace function public.my_employee_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from public.employees
  where lower(email) = public.my_email() and public.my_email() <> '' limit 1
$$;

create or replace function public.status_label(s text) returns text
language sql immutable as $$
  select case s when 'available' then '在庫可用' when 'in_use' then '使用中' when 'borrowed' then '借用中'
                when 'repair' then '維修中' when 'lost' then '遺失' when 'retired' then '已報廢' else coalesce(s,'—') end
$$;

create or replace function public.gen_so_no() returns text
language sql volatile as $$
  select 'SO-' || to_char(now() at time zone 'Asia/Taipei', 'YYYYMMDD') || '-' ||
         upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))
$$;
alter table public.signoffs alter column no set default public.gen_so_no();
alter table public.signoffs alter column created_by set default public.my_email();

-- ---------------------------------------------------------------------
-- 3. 觸發器
-- ---------------------------------------------------------------------

-- 資產：自動填入更新時間、更新者、保管人姓名
create or replace function public.tg_assets_before() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := public.my_email();
  if new.status not in ('in_use','borrowed','repair') then new.holder_id := null; end if;
  if new.status <> 'borrowed' then new.due_date := null; end if;
  new.holder_name := coalesce((select name from public.employees where id = new.holder_id), '');
  return new;
end $$;
drop trigger if exists assets_before on public.assets;
create trigger assets_before before insert or update on public.assets
  for each row execute function public.tg_assets_before();

-- 資產：自動寫入異動紀錄
create or replace function public.tg_assets_after() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  acts text[] := '{}';
  oldn int; newn int;
begin
  if tg_op = 'INSERT' then
    acts := array['建立資產'];
  else
    if (to_jsonb(new) - 'updated_at' - 'updated_by' - 'search' - 'holder_name')
       = (to_jsonb(old) - 'updated_at' - 'updated_by' - 'search' - 'holder_name') then
      return null;
    end if;
    if new.holder_id is distinct from old.holder_id then
      if new.holder_id is null then
        acts := acts || ('由 ' || coalesce(nullif(old.holder_name,''),'—') || ' 歸還');
      elsif new.status = 'borrowed' then
        acts := acts || ('借給 ' || new.holder_name || '，應還 ' || coalesce(new.due_date::text,''));
      else
        acts := acts || ('保管人變更為 ' || new.holder_name);
      end if;
    elsif new.status = 'borrowed' and new.due_date is distinct from old.due_date then
      acts := acts || ('歸還日改為 ' || new.due_date::text);
    end if;
    if new.status is distinct from old.status then
      acts := acts || ('狀態：' || public.status_label(old.status) || ' → ' || public.status_label(new.status));
    end if;
    oldn := jsonb_array_length(old.photos); newn := jsonb_array_length(new.photos);
    if newn > oldn then acts := acts || ('新增 ' || (newn - oldn) || ' 張照片');
    elsif newn < oldn then acts := acts || ('刪除 ' || (oldn - newn) || ' 張照片'); end if;
    if cardinality(acts) = 0 then acts := array['更新資料']; end if;
  end if;
  insert into public.asset_events (asset_id, by_email, action)
    select new.id, public.my_email(), a from unnest(acts) a;
  return null;
end $$;
drop trigger if exists assets_after on public.assets;
create trigger assets_after after insert or update on public.assets
  for each row execute function public.tg_assets_after();

-- 員工改名時，同步更新資產上的保管人姓名（讓搜尋保持正確）
create or replace function public.tg_employees_name() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' and new.name is distinct from old.name then
    update public.assets set holder_name = new.name where holder_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists employees_name on public.employees;
create trigger employees_name before update on public.employees
  for each row execute function public.tg_employees_name();

-- 簽收單：簽名只能透過 sign_signoff() 寫入；已簽收的單據不可再修改
create or replace function public.tg_signoffs_guard() returns trigger
language plpgsql as $$
declare signing boolean := coalesce(current_setting('app.signing', true), '') = '1';
begin
  if tg_op = 'INSERT' then
    if not signing then new.signed_at := null; new.signature := null; end if;
    return new;
  end if;
  if old.signed_at is not null then
    raise exception '已線上簽收的單據不可修改';
  end if;
  if (new.signed_at is distinct from old.signed_at or new.signature is distinct from old.signature) and not signing then
    raise exception '簽名只能由員工本人簽署';
  end if;
  if old.paper_signed_at is not null and new.voided and not old.voided then
    raise exception '已簽回的單據不可作廢';
  end if;
  if new.items is distinct from old.items or new.signer_email is distinct from old.signer_email
     or new.employee_id is distinct from old.employee_id then
    raise exception '簽收單建立後不可修改內容，請作廢後重新建立';
  end if;
  return new;
end $$;
drop trigger if exists signoffs_guard on public.signoffs;
create trigger signoffs_guard before insert or update on public.signoffs
  for each row execute function public.tg_signoffs_guard();

-- 至少保留一位管理員，避免把自己鎖在門外
create or replace function public.tg_roles_guard() returns trigger
language plpgsql as $$
begin
  if not exists (select 1 from public.roles where role = 'admin') then
    raise exception '至少需要保留一位管理員';
  end if;
  return null;
end $$;
drop trigger if exists roles_guard on public.roles;
create constraint trigger roles_guard after update or delete on public.roles
  deferrable initially deferred for each row execute function public.tg_roles_guard();

-- ---------------------------------------------------------------------
-- 4. 伺服器端功能（RPC）
-- ---------------------------------------------------------------------

-- 目前登入者的身分
create or replace function public.whoami() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'email', public.my_email(),
    'role', public.app_role(),
    'employee', (select to_jsonb(e) from public.employees e where e.id = public.my_employee_id()))
$$;

-- 資產統計（與列表使用完全相同的篩選條件）
create or replace function public.asset_stats(p_words text[] default '{}', p_cat text default '',
                                              p_holder uuid default null, p_noholder boolean default false)
returns jsonb language sql stable as $$
  with f as (
    select status, (status = 'borrowed' and due_date < (now() at time zone 'Asia/Taipei')::date) as over
    from public.assets a
    where (p_cat = '' or a.cat = p_cat)
      and (p_holder is null or a.holder_id = p_holder)
      and (not p_noholder or a.holder_id is null)
      and not exists (select 1 from unnest(p_words) w where w <> '' and a.search not like '%' || w || '%')
  )
  select jsonb_build_object(
    'all', count(*),
    'available', count(*) filter (where status = 'available'),
    'in_use',    count(*) filter (where status = 'in_use'),
    'borrowed',  count(*) filter (where status = 'borrowed'),
    'repair',    count(*) filter (where status = 'repair'),
    'lost',      count(*) filter (where status = 'lost'),
    'retired',   count(*) filter (where status = 'retired'),
    'overdue',   count(*) filter (where over),
    'total',     (select count(*) from public.assets),
    'holders',   (select count(distinct holder_id) from public.assets where holder_id is not null))
  from f
$$;

create or replace function public.signoff_stats(p_words text[] default '{}') returns jsonb
language sql stable as $$
  with f as (select * from public.signoffs s
             where not exists (select 1 from unnest(p_words) w where w <> '' and s.search not like '%' || w || '%'))
  select jsonb_build_object(
    'all', count(*),
    'pending', count(*) filter (where not voided and signed_at is null and paper_signed_at is null),
    'done',    count(*) filter (where not voided and (signed_at is not null or paper_signed_at is not null)),
    'void',    count(*) filter (where voided))
  from f
$$;

-- 每位員工的名下資產數與待簽數
create or replace function public.employee_counts() returns table (employee_id uuid, assets bigint, pending bigint)
language sql stable as $$
  select e.id,
         (select count(*) from public.assets a where a.holder_id = e.id),
         (select count(*) from public.signoffs s where s.employee_id = e.id and not s.voided
                 and s.signed_at is null and s.paper_signed_at is null)
  from public.employees e
$$;

-- 建立簽收單（內容由伺服器依目前資產資料產生）
create or replace function public.create_signoff(p_employee uuid, p_type text, p_assets uuid[]) returns uuid
language plpgsql as $$
declare e public.employees; new_id uuid;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  select * into e from public.employees where id = p_employee;
  if not found then raise exception '找不到員工'; end if;
  insert into public.signoffs (type, employee_id, employee_name, emp_no, dept, signer_email, items)
  select p_type, e.id, e.name, e.emp_no, e.dept, nullif(lower(e.email), ''),
         jsonb_agg(jsonb_build_object('id', a.id, 'tag', a.tag, 'name', a.name,
                   'bm', concat_ws(' ', nullif(a.brand,''), nullif(a.model,''), nullif(a.os,'')),
                   'serial', a.serial, 'due', case when a.status = 'borrowed' then a.due_date end) order by a.tag)
  from public.assets a where a.id = any(p_assets) and a.holder_id = e.id
  having count(*) > 0
  returning id into new_id;
  if new_id is null then raise exception '請至少選擇一項該員工名下的設備'; end if;
  return new_id;
end $$;

-- 為所有名下有設備的在職員工產生盤點確認單
create or replace function public.create_inventory_signoffs() returns int
language plpgsql as $$
declare n int;
begin
  if not public.is_admin() then raise exception '需要管理員權限'; end if;
  insert into public.signoffs (type, employee_id, employee_name, emp_no, dept, signer_email, items)
  select 'inventory', e.id, e.name, e.emp_no, e.dept, nullif(lower(e.email), ''),
         jsonb_agg(jsonb_build_object('id', a.id, 'tag', a.tag, 'name', a.name,
                   'bm', concat_ws(' ', nullif(a.brand,''), nullif(a.model,''), nullif(a.os,'')),
                   'serial', a.serial, 'due', case when a.status = 'borrowed' then a.due_date end) order by a.tag)
  from public.employees e join public.assets a on a.holder_id = e.id
  where e.active
  group by e.id;
  get diagnostics n = row_count;
  return n;
end $$;

-- 員工線上簽名：只能簽自己的、未作廢、未簽過的單
create or replace function public.sign_signoff(p_id uuid, p_sig jsonb) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare r public.signoffs;
begin
  select * into r from public.signoffs where id = p_id for update;
  if not found then raise exception '找不到簽收單'; end if;
  if r.signer_email is null or lower(r.signer_email) <> public.my_email() or public.my_email() = '' then
    raise exception '只能簽署自己的簽收單';
  end if;
  if r.voided then raise exception '此簽收單已作廢'; end if;
  if r.signed_at is not null or r.paper_signed_at is not null then raise exception '此簽收單已完成簽收'; end if;
  if p_sig is null or length(coalesce(p_sig ->> 'd', '')) < 10 or length(p_sig::text) > 200000 then
    raise exception '簽名資料無效';
  end if;
  perform set_config('app.signing', '1', true);
  update public.signoffs
     set signed_at = now(),
         signature = jsonb_build_object('d', p_sig ->> 'd', 'w', (p_sig ->> 'w')::int, 'h', (p_sig ->> 'h')::int)
   where id = p_id;
  perform set_config('app.signing', '', true);
  return now();
end $$;

-- ---------------------------------------------------------------------
-- 5. 資料列層級權限（RLS）：真正的權限在這裡強制執行
--    函式包在 (select ...) 裡，讓資料庫每次查詢只判斷一次身分，而不是每一列都判斷（資料多時差很多）
-- ---------------------------------------------------------------------
alter table public.roles        enable row level security;
alter table public.settings     enable row level security;
alter table public.employees    enable row level security;
alter table public.assets       enable row level security;
alter table public.asset_events enable row level security;
alter table public.signoffs     enable row level security;

revoke all on all tables    in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant  execute on all functions in schema public to authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to authenticated;

do $$ declare t text; p record; begin
  foreach t in array array['roles','settings','employees','assets','asset_events','signoffs'] loop
    for p in select policyname from pg_policies where schemaname = 'public' and tablename = t loop
      execute format('drop policy %I on public.%I', p.policyname, t);
    end loop;
  end loop;
end $$;

create policy roles_read   on public.roles for select to authenticated using ((select public.is_admin()) or email = (select public.my_email()));
create policy roles_write  on public.roles for all    to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy settings_read  on public.settings for select to authenticated using ((select public.app_role()) is not null);
create policy settings_write on public.settings for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy employees_read  on public.employees for select to authenticated
  using ((select public.is_staff()) or (lower(email) = (select public.my_email()) and (select public.my_email()) <> ''));
create policy employees_write on public.employees for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy assets_read  on public.assets for select to authenticated
  using ((select public.is_staff()) or holder_id = (select public.my_employee_id()));
create policy assets_write on public.assets for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));

create policy events_read on public.asset_events for select to authenticated using ((select public.is_staff()));

create policy signoffs_read on public.signoffs for select to authenticated
  using ((select public.is_staff()) or employee_id = (select public.my_employee_id())
         or (lower(signer_email) = (select public.my_email()) and (select public.my_email()) <> ''));
create policy signoffs_insert on public.signoffs for insert to authenticated with check ((select public.is_admin()));
create policy signoffs_update on public.signoffs for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy signoffs_delete on public.signoffs for delete to authenticated using ((select public.is_admin()) and voided);

-- ---------------------------------------------------------------------
-- 6. 照片儲存空間
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('asset-photos', 'asset-photos', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

drop policy if exists "asset photos admin insert" on storage.objects;
drop policy if exists "asset photos admin update" on storage.objects;
drop policy if exists "asset photos admin delete" on storage.objects;
create policy "asset photos admin insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'asset-photos' and (select public.is_admin()));
create policy "asset photos admin update" on storage.objects for update to authenticated
  using (bucket_id = 'asset-photos' and (select public.is_admin()));
create policy "asset photos admin delete" on storage.objects for delete to authenticated
  using (bucket_id = 'asset-photos' and (select public.is_admin()));

-- ---------------------------------------------------------------------
-- 7. 設定第一位管理員：把下面的 Email 改成你自己的，取消註解後執行
-- ---------------------------------------------------------------------
-- insert into public.roles (email, role) values ('you@yourcompany.com', 'admin') on conflict (email) do update set role = 'admin';
