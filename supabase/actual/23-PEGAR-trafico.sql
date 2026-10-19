-- OpsFlow · tráfico en tiempo real (TomTom) por zona (10 oct 2026)
-- La función "trafico" consulta TomTom cada 10 min y guarda aquí lo relevante; los teléfonos solo leen de aquí.
-- La clave de TomTom vive SOLO en los secretos de Supabase (TOMTOM_KEY). Se puede ejecutar varias veces.

-- 1. Incidencias actuales (se reemplazan en cada consulta) y estado de la última consulta -------------
create table if not exists public.trafico (
  id          text primary key,              -- id de TomTom
  tipo        int not null,                  -- iconCategory de TomTom (1 accidente, 6 atasco, 7 carril, 8 vía cerrada, 9 obras)
  gravedad    int not null default 0,        -- magnitudeOfDelay 0..4
  municipio   text,
  zona        text not null default 'General' check (zona in ('Norte', 'Centro', 'Sur', 'General')),
  desde_calle text, hasta_calle text,
  retraso_min int not null default 0,
  km          numeric(6,1) not null default 0,
  detalle     text,
  hasta       timestamptz,                   -- cuándo se espera que termine
  lat double precision, lng double precision,
  visto_en    timestamptz not null default now()
);
create table if not exists public.trafico_estado (
  id int primary key default 1 check (id = 1),
  actualizado_en timestamptz, error text
);
insert into public.trafico_estado (id) values (1) on conflict (id) do nothing;

alter table public.trafico enable row level security;
alter table public.trafico_estado enable row level security;
revoke all on public.trafico, public.trafico_estado from anon, authenticated;

-- 2. Zona de un pueblo: la de tus apartamentos en ese pueblo (la más frecuente); si no hay, General ---------
create or replace function public._zona_de_pueblo(p_pueblo text)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.zona::text from public.propiedades p
    where p.activa and lower(regexp_replace(p.pueblo, '[^[:alpha:]]', '', 'g'))
                     = lower(regexp_replace(coalesce(p_pueblo, ''), '[^[:alpha:]]', '', 'g'))
      and coalesce(p_pueblo, '') <> ''
    group by p.zona order by count(*) desc limit 1), 'General')
$$;
revoke execute on function public._zona_de_pueblo(text) from public, anon, authenticated;

-- 3. Guardar una consulta (solo el servidor): reemplaza todas las incidencias de golpe ---------------------
create or replace function public.trafico_guardar(p_incidencias jsonb, p_error text default null)
returns int language plpgsql security definer set search_path = ''
as $$
declare n int := 0;
begin
  if p_error is not null then
    update public.trafico_estado set error = left(p_error, 300) where id = 1;
    return 0;
  end if;
  delete from public.trafico where true;   -- Supabase exige WHERE
  insert into public.trafico (id, tipo, gravedad, municipio, zona, desde_calle, hasta_calle, retraso_min, km, detalle, hasta, lat, lng)
  select x->>'id', (x->>'tipo')::int, coalesce((x->>'gravedad')::int, 0), x->>'municipio', public._zona_de_pueblo(x->>'municipio'),
         left(x->>'desde', 120), left(x->>'hasta_calle', 120), coalesce((x->>'retraso_min')::int, 0), coalesce((x->>'km')::numeric, 0),
         left(x->>'detalle', 300), nullif(x->>'fin', '')::timestamptz, (x->>'lat')::double precision, (x->>'lng')::double precision
  from jsonb_array_elements(coalesce(p_incidencias, '[]'::jsonb)) x
  where x->>'id' is not null
  on conflict (id) do nothing;
  get diagnostics n = row_count;
  update public.trafico_estado set actualizado_en = now(), error = null where id = 1;
  return n;
end $$;
revoke execute on function public.trafico_guardar(jsonb, text) from public, anon, authenticated;
grant  execute on function public.trafico_guardar(jsonb, text) to service_role;

-- Municipios ya conocidos (para no volver a preguntar a TomTom por los mismos): solo el servidor
create or replace function public.trafico_conocidos()
returns table (id text, municipio text) language sql stable security definer set search_path = ''
as $$ select t.id, t.municipio from public.trafico t $$;
revoke execute on function public.trafico_conocidos() from public, anon, authenticated;
grant  execute on function public.trafico_conocidos() to service_role;

-- ¿Hace falta consultar TomTom? (si la última consulta tiene menos de 5 min, no: protege el cupo gratuito)
create or replace function public.trafico_toca()
returns boolean language sql stable security definer set search_path = ''
as $$ select coalesce((select actualizado_en from public.trafico_estado where id = 1) < now() - interval '5 minutes', true) $$;
revoke execute on function public.trafico_toca() from public, anon, authenticated;
grant  execute on function public.trafico_toca() to service_role;

-- 4. Lo que ve la app: drivers, líderes y Operación ---------------------------------------------------
create or replace function public.trafico_actual()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_departamento() = 'Drivers' or public.mi_nivel() in ('lider', 'operacion')) then
    raise exception 'Solo drivers, líderes y Operación.';
  end if;
  return jsonb_build_object(
    'actualizado_en', (select actualizado_en from public.trafico_estado where id = 1),
    'error', (select error from public.trafico_estado where id = 1),
    'incidencias', coalesce((select jsonb_agg(jsonb_build_object(
        'tipo', t.tipo, 'gravedad', t.gravedad, 'municipio', t.municipio, 'zona', t.zona,
        'desde', t.desde_calle, 'hasta_calle', t.hasta_calle, 'retraso_min', t.retraso_min, 'km', t.km,
        'detalle', t.detalle, 'hasta', t.hasta)
        order by case t.tipo when 8 then 0 when 1 then 1 when 7 then 2 else 3 end, t.retraso_min desc)
      from public.trafico t), '[]'::jsonb));
end $$;
revoke execute on function public.trafico_actual() from public, anon;
grant  execute on function public.trafico_actual() to authenticated;

-- 5. Consulta automática cada 10 minutos, de 06:00 a 23:59 de Malta (aprox., en UTC) ---------------
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
select cron.unschedule(jobid) from cron.job where jobname = 'opsflow-trafico';
select cron.schedule(
  'opsflow-trafico',
  '*/10 4-22 * * *',
  $$ select net.http_post(
       url     := 'https://zxsiantglodsqqvigndk.supabase.co/functions/v1/trafico',
       headers := '{"Content-Type": "application/json"}'::jsonb,
       body    := '{}'::jsonb) $$
);
-- Comprobación: debe salir una fila "opsflow-trafico"
select jobname, schedule, active from cron.job where jobname = 'opsflow-trafico';
