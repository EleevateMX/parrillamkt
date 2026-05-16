-- ═══════════════════════════════════════════════════════════════
-- ApagonesMid · Supabase Schema v1
-- Correr completo en el SQL Editor de Supabase (orden importa).
-- Luego pega tu SUPABASE_URL y SUPABASE_ANON_KEY en index.html.
-- ═══════════════════════════════════════════════════════════════

-- Extensiones
create extension if not exists "pgcrypto";

-- ─── profiles: contacto privado del reportante ────────────────
-- Solo el service_role (Supabase dashboard / admin) puede leer.
create table if not exists public.profiles (
  id          uuid primary key default gen_random_uuid(),
  name        text,
  phone       text,
  device_id   text,
  created_at  timestamptz not null default now()
);

-- ─── zones: colonias / sectores de Mérida ─────────────────────
create table if not exists public.zones (
  id          serial primary key,
  name        text not null,
  city        text not null default 'Mérida',
  center_lat  double precision,
  center_lng  double precision,
  radius_m    integer default 800
);

-- Seed inicial: algunas colonias (ampliar después)
insert into public.zones (name, center_lat, center_lng, radius_m) values
  ('Centro',              20.9674, -89.6237, 1200),
  ('García Ginerés',      20.9716, -89.6280,  900),
  ('Itzimná',             20.9842, -89.6105, 1100),
  ('México Norte',        20.9758, -89.5970,  900),
  ('Francisco de Montejo',20.9970, -89.6500, 1500),
  ('Pacabtún',            20.9410, -89.6320, 1100),
  ('Caucel',              21.0240, -89.7140, 1800),
  ('Las Américas',        21.0270, -89.6020, 1200)
on conflict do nothing;

-- ─── reports: incidencias (apagón / agua) ─────────────────────
create table if not exists public.reports (
  id                   uuid primary key default gen_random_uuid(),
  type                 text not null check (type in ('power','water')),
  subtype              text check (subtype in ('home','lighting','leak','outage','pressure','quality')),
  lat                  double precision not null,
  lng                  double precision not null,
  zone                 text,
  zone_id              integer references public.zones(id) on delete set null,
  severity             text not null default 'moderate' check (severity in ('low','moderate','critical')),
  description          text,
  photo_url            text,
  status               text not null default 'active' check (status in ('active','resolved','dismissed')),
  reporter_id          uuid references public.profiles(id) on delete set null,
  reporter_device      text,                                            -- anon device id
  confirmations_count  integer not null default 0,
  reported_at          timestamptz not null default now(),
  resolved_at          timestamptz
);

create index if not exists reports_status_idx     on public.reports (status);
create index if not exists reports_type_idx       on public.reports (type);
create index if not exists reports_reported_at_idx on public.reports (reported_at desc);

-- ─── confirmations: corroboraciones / resoluciones colaborativas
create table if not exists public.confirmations (
  id          uuid primary key default gen_random_uuid(),
  report_id   uuid not null references public.reports(id) on delete cascade,
  device_id   text not null,
  kind        text not null check (kind in ('also_affected','resolved')),
  created_at  timestamptz not null default now(),
  unique (report_id, device_id, kind)
);

-- ─── notification subs: suscripción anónima por zona ──────────
create table if not exists public.notification_subs (
  device_id   text primary key,
  zone_ids    integer[] default '{}',
  push_token  text,
  topic       text default 'all',
  created_at  timestamptz not null default now()
);

-- ─── reports_public: vista sin PII (lo que lee el cliente) ────
create or replace view public.reports_public as
select
  id, type, subtype, lat, lng, zone, zone_id, severity, description, photo_url,
  status, confirmations_count, reported_at, resolved_at
from public.reports;

-- ─── triggers: counter de confirmaciones + auto-resolución ────
create or replace function public._after_confirmation()
returns trigger language plpgsql security definer as $$
begin
  if new.kind = 'resolved' then
    update public.reports
      set status      = 'resolved',
          resolved_at = coalesce(resolved_at, now())
      where id = new.report_id;
  else
    update public.reports
      set confirmations_count = confirmations_count + 1
      where id = new.report_id;
  end if;
  return new;
end $$;

drop trigger if exists trg_after_confirmation on public.confirmations;
create trigger trg_after_confirmation
  after insert on public.confirmations
  for each row execute function public._after_confirmation();

-- ═══════════════════════════════════════════════════════════════
-- RLS · Row Level Security
-- ═══════════════════════════════════════════════════════════════
alter table public.profiles          enable row level security;
alter table public.zones             enable row level security;
alter table public.reports           enable row level security;
alter table public.confirmations     enable row level security;
alter table public.notification_subs enable row level security;

-- profiles: solo INSERT desde el cliente (privado, sin lectura pública)
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles
  for insert to anon, authenticated with check (true);

-- zones: lectura pública
drop policy if exists zones_read on public.zones;
create policy zones_read on public.zones
  for select to anon, authenticated using (true);

-- reports: lectura y creación pública. NO update/delete desde anon.
drop policy if exists reports_read on public.reports;
create policy reports_read on public.reports
  for select to anon, authenticated using (true);

drop policy if exists reports_insert on public.reports;
create policy reports_insert on public.reports
  for insert to anon, authenticated with check (true);

-- confirmations: lectura y creación pública (idempotente vía unique)
drop policy if exists confirmations_read on public.confirmations;
create policy confirmations_read on public.confirmations
  for select to anon, authenticated using (true);

drop policy if exists confirmations_insert on public.confirmations;
create policy confirmations_insert on public.confirmations
  for insert to anon, authenticated with check (true);

-- notification_subs: el dueño del device_id puede leer/escribir su fila
drop policy if exists subs_select on public.notification_subs;
create policy subs_select on public.notification_subs
  for select to anon, authenticated using (true);

drop policy if exists subs_upsert on public.notification_subs;
create policy subs_upsert on public.notification_subs
  for insert to anon, authenticated with check (true);

drop policy if exists subs_update on public.notification_subs;
create policy subs_update on public.notification_subs
  for update to anon, authenticated using (true) with check (true);

-- ═══════════════════════════════════════════════════════════════
-- Realtime · publica cambios para el feed live
-- ═══════════════════════════════════════════════════════════════
do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='reports'
  ) then
    execute 'alter publication supabase_realtime add table public.reports';
  end if;
  if not exists (
    select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='confirmations'
  ) then
    execute 'alter publication supabase_realtime add table public.confirmations';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- Storage · bucket para fotos de reportes
-- Correr UNA VEZ. En el Storage Dashboard verifica que esté Public.
-- ═══════════════════════════════════════════════════════════════
-- insert into storage.buckets (id, name, public) values ('reports', 'reports', true)
--   on conflict (id) do nothing;
-- Y políticas: Storage > reports > Policies > New Policy:
--   - SELECT: allow public
--   - INSERT: allow anon/authenticated
