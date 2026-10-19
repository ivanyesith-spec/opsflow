-- OpsFlow · modulo avisos · 006
-- Suscripciones de los telefonos y calculo de quien recibe cada aviso.
-- Se ejecuta UNA vez: SQL Editor → pegar todo → Run.

-- 1. Tablas --------------------------------------------------------------
create table public.suscripciones (
  id           uuid primary key default gen_random_uuid(),
  perfil_id    uuid not null references public.perfiles(id) on delete cascade,
  endpoint     text not null unique check (endpoint like 'https://%' and length(endpoint) < 1000),
  p256dh       text not null check (length(p256dh) between 20 and 200),
  auth         text not null check (length(auth) between 10 and 100),
  dispositivo  text check (length(dispositivo) <= 120),
  creado_en    timestamptz not null default now(),
  ultimo_ok    timestamptz
);
create index suscripciones_perfil on public.suscripciones (perfil_id);

create table public.avisos_enviados (
  id           bigint generated always as identity primary key,
  clave        text not null unique,          -- que paso + a quien: evita mandar dos veces lo mismo
  perfil_id    uuid references public.perfiles(id) on delete set null,
  titulo       text not null,
  enviado_en   timestamptz not null default now(),
  resultado    text
);

-- Nadie las lee ni las escribe desde la app: solo las funciones de abajo y el servidor.
alter table public.suscripciones   enable row level security;
alter table public.avisos_enviados enable row level security;
revoke all on public.suscripciones, public.avisos_enviados from anon, authenticated;

-- 2. Funciones para la app -----------------------------------------------
-- Guardar el telefono de quien esta conectado (si el telefono era de otra cuenta, pasa a esta)
create or replace function public.guardar_suscripcion(p_endpoint text, p_p256dh text, p_auth text, p_dispositivo text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is null then raise exception 'Cuenta no activa.'; end if;
  insert into public.suscripciones (perfil_id, endpoint, p256dh, auth, dispositivo)
  values ((select auth.uid()), p_endpoint, p_p256dh, p_auth, left(p_dispositivo, 120))
  on conflict (endpoint) do update
     set perfil_id = excluded.perfil_id, p256dh = excluded.p256dh, auth = excluded.auth,
         dispositivo = excluded.dispositivo, creado_en = now();
end $$;

-- Quitar un telefono: solo si es tuyo
create or replace function public.borrar_suscripcion(p_endpoint text)
returns void language sql security definer set search_path = ''
as $$ delete from public.suscripciones where endpoint = p_endpoint and perfil_id = (select auth.uid()) $$;

-- Cuantos telefonos tengo con avisos (para el boton)
create or replace function public.mis_avisos()
returns int language sql stable security definer set search_path = ''
as $$ select count(*)::int from public.suscripciones where perfil_id = (select auth.uid()) and public.mi_nivel() is not null $$;

revoke execute on function public.guardar_suscripcion(text, text, text, text), public.borrar_suscripcion(text), public.mis_avisos()
  from public, anon;
grant execute on function public.guardar_suscripcion(text, text, text, text), public.borrar_suscripcion(text), public.mis_avisos()
  to authenticated;

-- 3. Quien recibe cada aviso (solo el servidor) ---------------------------
-- Devuelve una fila por persona NUEVA a avisar, con sus telefonos, y la deja apuntada
-- en avisos_enviados para que el mismo aviso no salga dos veces.
create or replace function public.avisos_para(p_tipo text, p_id uuid default null, p_fecha date default null)
returns table (perfil_id uuid, titulo text, cuerpo text, url text, clave text, telefonos jsonb)
language plpgsql security definer set search_path = ''
as $$
#variable_conflict use_column
declare
  pe public.pendientes; li public.limpiezas; pr public.propiedades; ck public.checkouts;
  v_aviso text; v_ok boolean := true;
begin
  create temp table if not exists _dest (perfil_id uuid, idioma text, t_es text, t_en text, c_es text, c_en text, url text, clave text) on commit drop;
  truncate _dest;

  if p_tipo = 'pendiente' then
    select * into pe from public.pendientes where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = pe.propiedad_id;
    select c.* into ck from public.checkouts c join public.limpiezas l on l.checkout_id = c.id where l.id = pe.limpieza_id;
    v_aviso := 'pendiente:' || pe.id || ':' || pe.estado;

    if pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || pe.cantidad || ' × ' || pe.detalle, 'Linens: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || pe.cantidad || ' × ' || pe.detalle, 'Deliver: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' then
      -- 4. Recogida → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Recoger: basura y linens sucios', 'Pick up: trash & dirty linens',
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'linens' and pe.estado = 'entregado' then
      -- 5. Entregado → el cleaner que lo pidio
      insert into _dest select p.id, p.idioma,
        'Entregado: ' || pe.cantidad || ' × ' || pe.detalle, 'Delivered: ' || pe.cantidad || ' × ' || pe.detalle,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=asignar', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en;
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found or li.estado <> 'no_pude_entrar' then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=asignar' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));

  elsif p_tipo = 'orden' then
    if p_fecha is null then return; end if;
    -- 1. Orden publicado → cada cleaner con limpiezas publicadas ese dia
    --    (la clave lleva cuantas tiene: si el lider le anade otra y publica, le vuelve a sonar)
    insert into _dest select p.id, p.idioma,
      'Orden de limpieza listo', 'Your cleaning order is ready',
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartamento' || case when count(*) > 1 then 's' else '' end,
      to_char(p_fecha, 'DD/MM') || ' · ' || count(*) || ' apartment' || case when count(*) > 1 then 's' else '' end,
      './', 'orden:' || p_fecha || ':' || p.id || ':' || count(*)
    from public.limpiezas l join public.perfiles p on p.id = l.asignada_a
    where l.fecha = p_fecha and l.publicada and p.activo
    group by p.id, p.idioma;

  else
    return;
  end if;

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id);

  -- Apuntar los nuevos; los que ya estaban apuntados no salen otra vez
  return query
  with nuevos as (
    insert into public.avisos_enviados (clave, perfil_id, titulo)
    select d.clave, d.perfil_id, case when d.idioma = 'es' then d.t_es else d.t_en end from _dest d
    on conflict (clave) do nothing
    returning avisos_enviados.clave
  )
  select d.perfil_id,
         case when d.idioma = 'es' then d.t_es else d.t_en end,
         case when d.idioma = 'es' then d.c_es else d.c_en end,
         d.url, d.clave,
         coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth))
                   from public.suscripciones s where s.perfil_id = d.perfil_id), '[]'::jsonb)
  from _dest d join nuevos n on n.clave = d.clave;
end $$;

revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;
