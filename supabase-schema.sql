-- Арсенал / общая база учёта склада
-- Выполнить целиком в Supabase: SQL Editor -> New query -> Run.

create extension if not exists pgcrypto;

create table if not exists public.weapons (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default 'Другое',
  serial_number text,
  notes text,
  status text not null default 'stock' check (status in ('stock', 'issued', 'written_off')),
  assigned_to text,
  assigned_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists weapons_serial_number_unique
  on public.weapons (lower(serial_number))
  where serial_number is not null and length(trim(serial_number)) > 0;

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  weapon_id uuid references public.weapons(id) on delete set null,
  weapon_name text not null,
  action text not null check (action in ('Приход', 'Выдача', 'Возврат', 'Списание')),
  player_name text,
  performed_by text not null,
  details text,
  created_at timestamptz not null default now()
);

create index if not exists transactions_created_at_idx on public.transactions (created_at desc);
create index if not exists transactions_weapon_id_idx on public.transactions (weapon_id);

alter table public.weapons enable row level security;
alter table public.transactions enable row level security;

-- Чтение и операции доступны только вошедшим пользователям Supabase.
drop policy if exists "weapons_select_authenticated" on public.weapons;
create policy "weapons_select_authenticated" on public.weapons
  for select to authenticated using (true);

drop policy if exists "weapons_insert_authenticated" on public.weapons;
create policy "weapons_insert_authenticated" on public.weapons
  for insert to authenticated with check (true);

drop policy if exists "weapons_update_authenticated" on public.weapons;
create policy "weapons_update_authenticated" on public.weapons
  for update to authenticated using (true) with check (true);

drop policy if exists "transactions_select_authenticated" on public.transactions;
create policy "transactions_select_authenticated" on public.transactions
  for select to authenticated using (true);

drop policy if exists "transactions_insert_authenticated" on public.transactions;
create policy "transactions_insert_authenticated" on public.transactions
  for insert to authenticated with check (true);

-- Поступление: создание единицы оружия и запись в журнал происходят одной транзакцией.
create or replace function public.inventory_add_weapon(
  p_name text,
  p_category text,
  p_serial text,
  p_notes text,
  p_actor text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация';
  end if;
  if nullif(trim(p_name), '') is null or nullif(trim(p_actor), '') is null then
    raise exception 'Название оружия и сотрудник обязательны';
  end if;

  insert into public.weapons (name, category, serial_number, notes, status)
  values (trim(p_name), coalesce(nullif(trim(p_category), ''), 'Другое'), nullif(trim(p_serial), ''), nullif(trim(p_notes), ''), 'stock')
  returning id into v_id;

  insert into public.transactions (weapon_id, weapon_name, action, performed_by, details)
  values (v_id, trim(p_name), 'Приход', trim(p_actor), nullif(trim(p_notes), ''));

  return v_id;
end;
$$;

-- Выдача, возврат или списание: изменение статуса и запись журнала атомарны.
create or replace function public.inventory_move_weapon(
  p_weapon_id uuid,
  p_action text,
  p_actor text,
  p_player text default null,
  p_note text default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_weapon public.weapons%rowtype;
  v_log_player text;
begin
  if auth.uid() is null then
    raise exception 'Требуется авторизация';
  end if;
  if nullif(trim(p_actor), '') is null then
    raise exception 'Укажите сотрудника, проводящего операцию';
  end if;

  select * into v_weapon
  from public.weapons
  where id = p_weapon_id
  for update;

  if not found then
    raise exception 'Оружие не найдено';
  end if;

  if p_action = 'Выдача' then
    if v_weapon.status <> 'stock' then
      raise exception 'Оружие не числится на складе';
    end if;
    if nullif(trim(p_player), '') is null then
      raise exception 'Укажите игрока';
    end if;
    update public.weapons
      set status = 'issued', assigned_to = trim(p_player), assigned_at = now(), updated_at = now()
      where id = p_weapon_id;
    v_log_player := trim(p_player);

  elsif p_action = 'Возврат' then
    if v_weapon.status <> 'issued' then
      raise exception 'Оружие не числится выданным';
    end if;
    v_log_player := v_weapon.assigned_to;
    update public.weapons
      set status = 'stock', assigned_to = null, assigned_at = null, updated_at = now()
      where id = p_weapon_id;

  elsif p_action = 'Списание' then
    if v_weapon.status <> 'stock' then
      raise exception 'Списать можно только оружие, находящееся на складе';
    end if;
    update public.weapons
      set status = 'written_off', assigned_to = null, assigned_at = null, updated_at = now()
      where id = p_weapon_id;

  else
    raise exception 'Неизвестная операция';
  end if;

  insert into public.transactions (weapon_id, weapon_name, action, player_name, performed_by, details)
  values (p_weapon_id, v_weapon.name, p_action, v_log_player, trim(p_actor), nullif(trim(p_note), ''));
end;
$$;

revoke all on function public.inventory_add_weapon(text, text, text, text, text) from public, anon;
revoke all on function public.inventory_move_weapon(uuid, text, text, text, text) from public, anon;
grant execute on function public.inventory_add_weapon(text, text, text, text, text) to authenticated;
grant execute on function public.inventory_move_weapon(uuid, text, text, text, text) to authenticated;

-- Через клиентский API таблицы доступны только для чтения.
-- Запись и изменение выполняются только функциями выше, чтобы нельзя было
-- поменять статус оружия без соответствующей записи в журнале.
revoke all on public.weapons from anon, authenticated;
revoke all on public.transactions from anon, authenticated;
grant select on public.weapons to authenticated;
grant select on public.transactions to authenticated;

-- Включить Realtime для таблиц, чтобы изменения появлялись у остальных участников без перезагрузки.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'weapons'
  ) then
    alter publication supabase_realtime add table public.weapons;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'transactions'
  ) then
    alter publication supabase_realtime add table public.transactions;
  end if;
end $$;