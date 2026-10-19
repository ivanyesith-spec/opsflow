-- OpsFlow · mejoras antes del piloto (10 oct 2026)
-- Cancelar y reabrir limpiezas · códigos QR solo para Operación · GPS al escanear · "no pude entregar" del driver
-- Zona horaria de Malta · informe del piloto · historial de cada limpieza.
-- Ejecutar DESPUES de 015. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.

-- 1. Datos nuevos -----------------------------------------------------------------
alter type public.estado_limpieza add value if not exists 'cancelada';
-- (en este archivo el valor nuevo se compara como texto: estado::text = 'cancelada')
alter table public.limpiezas   add column if not exists cancelada_motivo text;
alter table public.limpiezas   add column if not exists reabierta_en timestamptz;
alter table public.limpiezas   add column if not exists gps jsonb;            -- {"inicio": {"dist": 35, "prec": 20}, "fin": {...}}
alter table public.propiedades add column if not exists lat double precision;
alter table public.propiedades add column if not exists lng double precision;
alter table public.pendientes  add column if not exists incidencia text;     -- el driver no pudo entregar/recoger
alter table public.pendientes  add column if not exists incidencia_en timestamptz;

-- 2. Los códigos QR solo los ve Operación (antes cualquier líder podía leerlos de la tabla) ----
revoke select on public.propiedades from authenticated;
grant select (id, codigo, nombre, zona, pueblo, direccion, mapa_url, camas_dobles, camas_indiv, sofas_cama, banos,
              notas, activa, es_prueba, creado_en, lat, lng) on public.propiedades to authenticated;
-- Las coordenadas las edita Operación igual que el resto de la ficha
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'propiedades_coordenadas_check') then
    alter table public.propiedades add constraint propiedades_coordenadas_check
      check ((lat is null and lng is null) or (lat between -90 and 90 and lng between -180 and 180));
  end if;
end $$;

-- 3. GPS al escanear: distancia (en metros) entre el teléfono y el apartamento -------------
create or replace function public._distancia_m(a_lat double precision, a_lng double precision, b_lat double precision, b_lng double precision)
returns int language sql immutable set search_path = ''
as $$
  select round(2 * 6371000 * asin(sqrt(
    power(sin(radians(b_lat - a_lat) / 2), 2) +
    cos(radians(a_lat)) * cos(radians(b_lat)) * power(sin(radians(b_lng - a_lng) / 2), 2))))::int
$$;
-- Resultado guardado: dist (null si el apto no tiene coordenadas), prec (precisión del teléfono), sin_gps
create or replace function public._gps(p_prop uuid, p_lat double precision, p_lng double precision, p_prec double precision)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_lat double precision; v_lng double precision;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return jsonb_build_object('sin_gps', true);
  end if;
  select lat, lng into v_lat, v_lng from public.propiedades where id = p_prop;
  return jsonb_build_object('sin_gps', false,
    'dist', case when v_lat is null then null else public._distancia_m(v_lat, v_lng, p_lat, p_lng) end,
    'prec', case when p_prec is null or p_prec < 0 then null else least(round(p_prec), 100000)::int end);
end $$;
revoke execute on function public._distancia_m(double precision, double precision, double precision, double precision),
  public._gps(uuid, double precision, double precision, double precision) from public, anon, authenticated;

-- Empezar y cerrar ahora reciben la posición del teléfono (opcional: si el cleaner no da permiso, queda "sin GPS")
drop function if exists public.iniciar_con_qr(uuid, text);
drop function if exists public.iniciar_limpieza(uuid);
drop function if exists public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text);

create or replace function public.iniciar_con_qr(p_id uuid, p_qr text, p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_token text; v_cod text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  select qr_token, codigo into v_token, v_cod from public.propiedades where id = v.propiedad_id;
  -- El QR lleva "OPSFLOW:<token>"; se acepta tambien el token solo
  if coalesce(regexp_replace(btrim(p_qr), '^OPSFLOW:', ''), '') <> v_token then
    raise exception 'This QR is not for %.', v_cod;
  end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = true,
    gps = jsonb_build_object('inicio', public._gps(v.propiedad_id, p_lat, p_lng, p_prec)) where id = p_id;
  perform public._evento('limpieza iniciada (QR)', p_id, null);
end $$;

create or replace function public.iniciar_limpieza(p_id uuid, p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'asignada' then raise exception 'Solo se puede empezar una limpieza asignada.'; end if;
  update public.limpiezas set estado = 'en_curso', inicio = now(), inicio_qr = false,
    gps = jsonb_build_object('inicio', public._gps(v.propiedad_id, p_lat, p_lng, p_prec)) where id = p_id;
  perform public._evento('limpieza iniciada (sin QR)', p_id, null);
end $$;

create or replace function public.cerrar_limpieza(
  p_id uuid, p_qr text, p_escoba boolean, p_squeegee boolean, p_recogedor boolean,
  p_basura boolean, p_llaves boolean, p_motivo_llaves text default null, p_lat double precision default null, p_lng double precision default null, p_prec double precision default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v public.limpiezas; v_faltan int; v_fotos int; v_prop public.propiedades; v_prio boolean;
  v_utiles text[] := '{}'; v_ids uuid[] := '{}'; v_id uuid; v_foto text;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  select count(*) into v_faltan from public.checklist_pasos p
   where p.tipo = v.tipo and p.activo and p.obligatorio and not (v.checklist ? p.id::text);
  if v_faltan > 0 then raise exception 'Checklist not finished: % step(s) left.', v_faltan; end if;
  select count(distinct sala) into v_fotos from public.fotos_cierre
   where limpieza_id = p_id and sala in ('bedroom', 'bathroom', 'kitchen', 'living');
  if v_fotos < 4 then raise exception 'Take the 4 photos first (% of 4).', v_fotos; end if;
  if p_escoba is null or p_squeegee is null or p_recogedor is null or p_basura is null or p_llaves is null then
    raise exception 'Answer the 3 closing questions first.';
  end if;
  if p_basura then
    select ruta into v_foto from public.fotos_cierre where limpieza_id = p_id and sala = 'basura';
    if v_foto is null then raise exception 'Take a photo of the trash first.'; end if;
  end if;
  if not p_llaves and length(btrim(coalesce(p_motivo_llaves, ''))) < 3 then
    raise exception 'Write why the keys are not in the key box.';
  end if;
  select * into v_prop from public.propiedades where id = v.propiedad_id;
  if p_qr is not null and btrim(p_qr) <> 'OPSFLOW:' || v_prop.qr_token then
    raise exception 'This QR is not for %. Scan the sticker inside this apartment.', v_prop.codigo;
  end if;

  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  if not p_escoba    then v_utiles := v_utiles || 'escoba'::text; end if;
  if not p_squeegee  then v_utiles := v_utiles || 'squeegee'::text; end if;
  if not p_recogedor then v_utiles := v_utiles || 'recogedor'::text; end if;
  if cardinality(v_utiles) > 0 then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'utiles'::text::public.tipo_pendiente,
            'Falta: ' || array_to_string(v_utiles, ', '), cardinality(v_utiles), coalesce(v_prio, false), (select auth.uid()), v.es_prueba)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: faltan útiles', v.id, v_id);
  end if;
  if p_basura then
    insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, foto)
    values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Basura dejada en el apto', 1, coalesce(v_prio, false),
            (select auth.uid()), v.es_prueba, v_foto)
    returning id into v_id;
    v_ids := v_ids || v_id;
    perform public._evento('cierre: basura en el apto', v.id, v_id);
  end if;

  update public.limpiezas set estado = 'terminada', fin = now(), fin_qr = (p_qr is not null),
    gps = coalesce(gps, '{}'::jsonb) || jsonb_build_object('fin', public._gps(v.propiedad_id, p_lat, p_lng, p_prec)),
    cierre = jsonb_build_object('escoba', p_escoba, 'squeegee', p_squeegee, 'recogedor', p_recogedor,
                                'basura', p_basura, 'llaves', p_llaves,
                                'motivo_llaves', case when p_llaves then null else left(btrim(p_motivo_llaves), 200) end)
  where id = p_id;
  perform public._evento('limpieza terminada' || case when p_qr is null then ' (salida sin QR)' else '' end
                         || case when p_llaves then '' else ' · llaves NO en key box' end, p_id, null);
  return jsonb_build_object('pendientes', to_jsonb(v_ids), 'llaves', p_llaves);
end $$;

-- 4. Cancelar y reabrir limpiezas (líder de limpieza u Operación) -----------------------
-- Cancelar: reserva cancelada, cambio de planes... Solo si aún no ha empezado (o no pudo entrar)
create or replace function public.cancelar_limpieza(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación cancelan limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado::text not in ('sin_asignar', 'asignada', 'no_pude_entrar') then
    raise exception 'Solo se cancela una limpieza que no ha empezado (o en la que no se pudo entrar).';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Escribe el motivo.'; end if;
  update public.limpiezas set estado = 'cancelada'::text::public.estado_limpieza, cancelada_motivo = left(btrim(p_motivo), 200)
   where id = p_id;
  perform public._evento('cancelada: ' || left(btrim(p_motivo), 200), p_id, null);
end $$;

-- Reabrir tras "no pude entrar": vuelve a la lista del mismo cleaner (el líder puede reasignarla luego)
create or replace function public.reabrir_limpieza(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación reabren limpiezas.'; end if;
  select * into v from public.limpiezas where id = p_id for update;
  if not found then raise exception 'Esa limpieza no existe.'; end if;
  if v.estado <> 'no_pude_entrar' then raise exception 'Solo se reabre una limpieza en la que no se pudo entrar.'; end if;
  update public.limpiezas set estado = 'asignada', inicio = null, fin = null, inicio_qr = null, gps = null,
         motivo_no_entrar = null, reabierta_en = now()
   where id = p_id;
  perform public._evento('reabierta (antes: ' || coalesce(v.motivo_no_entrar, '') || ')', p_id, null);
end $$;

-- 5. El driver no pudo entregar o recoger --------------------------------------------
create or replace function public.no_pude_entregar(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and public.mi_zona() = v.zona)) then
    raise exception 'Solo el driver de la zona puede marcarlo.';
  end if;
  if not ((v.tipo::text in ('linens', 'utiles') and v.estado = 'preparado') or (v.tipo = 'recogida' and v.estado = 'abierto')) then
    raise exception 'Ese pendiente no está en manos del driver.';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.pendientes set incidencia = left(btrim(p_motivo), 200), incidencia_en = now() where id = p_id;
  perform public._evento('no se pudo entregar: ' || left(btrim(p_motivo), 200), v.limpieza_id, p_id);
end $$;

-- El líder de drivers lo resuelve: vuelve a la ruta como normal (el driver lo intenta de nuevo)
create or replace function public.resolver_incidencia(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo el líder de drivers u Operación.';
  end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or v.incidencia is null then raise exception 'Ese pendiente no tiene incidencia.'; end if;
  update public.pendientes set incidencia = null, incidencia_en = null where id = p_id;
  perform public._evento('incidencia resuelta: ' || v.incidencia, v.limpieza_id, p_id);
end $$;


-- Pantallas del cleaner y del driver: sin canceladas; el driver ve su incidencia
create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'camas_dobles', p.camas_dobles, 'camas_indiv', p.camas_indiv, 'sofas', p.sofas_cama, 'banos', p.banos, 'notas', p.notas,
      'salida', to_char(c.hora_salida, 'HH24:MI'), 'entrada', to_char(c.hora_entrada, 'HH24:MI'),
      'pendientes', coalesce((select jsonb_agg(jsonb_build_object('id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle,
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid()) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

create or replace function public.mi_ruta(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_zona public.zona := public.mi_zona();
begin
  if not (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers') then
    raise exception 'Esta pantalla es para drivers.';
  end if;
  return jsonb_build_object(
    'tareas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', pe.id, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'estado', pe.estado,
        'prioritario', pe.prioritario, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto, 'items', pe.items, 'incidencia', pe.incidencia)
        order by pe.prioritario desc, pe.creado_en)
      from public.pendientes pe
      join public.limpiezas l on l.id = pe.limpieza_id
      join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.fecha = p_fecha and pe.zona = v_zona
        and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto'))), '[]'::jsonb),
    'orden', coalesce((select jsonb_agg(jsonb_build_object(
        'cleaner', pf.nombre, 'orden', l.orden, 'estado', l.estado, 'codigo', p.codigo, 'nombre', p.nombre,
        'pueblo', p.pueblo, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'))
        order by pf.nombre, l.orden)
      from public.limpiezas l
      join public.propiedades p on p.id = l.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      join public.perfiles pf on pf.id = l.asignada_a
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

-- 6. Zona horaria de Malta en los tiempos -----------------------------------------
create or replace function public.tiempos_aptos(p_dias int default 90)
returns table (codigo text, nombre text, tipo text, limpiezas bigint, media_min int, mediana_min int, ultima date)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return query
  select p.codigo, p.nombre, l.tipo::text, count(*),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60))::int,
         round(percentile_cont(0.5) within group (order by extract(epoch from (l.fin - l.inicio)) / 60))::int,
         max(l.fecha)
  from public.limpiezas l join public.propiedades p on p.id = l.propiedad_id
  where l.estado = 'terminada' and l.inicio_qr and l.fin_qr and l.fin is not null and l.inicio is not null
    and l.fecha >= (now() at time zone 'Europe/Malta')::date - p_dias
    and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'
  group by p.codigo, p.nombre, l.tipo
  order by p.codigo, l.tipo::text;
end $$;

create or replace function public.tiempos_personas(p_dias int default 90)
returns table (cleaner text, tipo text, limpiezas bigint, media_min int, sin_qr bigint)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  return query
  select pf.nombre, l.tipo::text,
         count(*) filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'),
         round(avg(extract(epoch from (l.fin - l.inicio)) / 60)
               filter (where l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours'))::int,
         count(*) filter (where l.inicio_qr is false or l.fin_qr is false)
  from public.limpiezas l join public.perfiles pf on pf.id = l.asignada_a
  where l.estado = 'terminada' and l.fecha >= (now() at time zone 'Europe/Malta')::date - p_dias
  group by pf.nombre, l.tipo
  order by pf.nombre, l.tipo::text;
end $$;

-- 7. Avisos: no se pudo entregar → lider de drivers; cancelada / reabierta → cleaner --------
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

    if pe.incidencia is not null and pe.incidencia_en > now() - interval '2 minutes'
       and ((pe.tipo::text in ('linens', 'utiles') and pe.estado = 'preparado') or (pe.tipo = 'recogida' and pe.estado = 'abierto')) then
      -- 11. El driver no pudo entregar/recoger → lider de drivers
      insert into _dest select p.id, p.idioma,
        'No se pudo entregar: ' || pr.codigo, 'Couldn''t deliver: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.incidencia, pr.pueblo || ' · ' || pe.incidencia,
        './?v=drivers', 'pendiente:' || pe.id || ':incidencia:' || extract(epoch from pe.incidencia_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Drivers'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'abierto' then
      -- 2. Cleaner reporta linens → lider de linens
      insert into _dest select p.id, p.idioma,
        'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Linens: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './?v=linens', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Linens'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo = 'linens' and pe.estado = 'preparado' then
      -- 3. Linens preparado → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Deliver: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Check-in ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        pr.codigo || ' · ' || pr.pueblo || coalesce(' · Guest arrives ' || to_char(ck.hora_entrada, 'HH24:MI'), ''),
        './', null
      from public.perfiles p where p.activo and p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = pe.zona;

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.foto is not null then
      -- 4b. Basura dejada en el apto (con foto) → drivers de la zona y lider de drivers
      insert into _dest select p.id, p.idioma,
        'Basura en el apto: ' || pr.codigo, 'Trash left: ' || pr.codigo,
        pr.pueblo || ' · ' || pe.detalle, pr.pueblo || ' · pick it up (photo in the app)',
        './', null
      from public.perfiles p where p.activo and p.departamento = 'Drivers'
        and ((p.nivel = 'operador' and p.zona = pe.zona) or (p.nivel = 'lider' and (p.zona is null or p.zona = pe.zona)));

    elsif pe.tipo::text = 'utiles' and pe.estado = 'abierto' then
      -- 8. Faltan utiles → lider de bodega
      insert into _dest select p.id, p.idioma,
        'Útiles: ' || pe.detalle, 'Tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=bodega', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Bodega'
        and (p.zona is null or p.zona = pe.zona);

    elsif pe.tipo::text = 'utiles' and pe.estado = 'preparado' then
      -- 9. Utiles preparados → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Entregar útiles: ' || pe.detalle, 'Deliver tools: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
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
        'Entregado: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'es') end, 'Delivered: ' || case when pe.items is null then pe.cantidad || ' × ' || pe.detalle else public._linens_texto(pe.items, 'en') end,
        pr.codigo || ' · marca Recibido', pr.codigo || ' · tap Received',
        './', null
      from public.perfiles p where p.activo and p.id = pe.creado_por;

    elsif pe.tipo = 'otro' and pe.estado = 'abierto' then
      -- 7. Pendiente "otro" → lider de limpieza
      insert into _dest select p.id, p.idioma,
        'Pendiente: ' || pe.detalle, 'Issue: ' || pe.detalle,
        pr.codigo || ' · ' || pr.pueblo, pr.codigo || ' · ' || pr.pueblo,
        './?v=seguimiento', null
      from public.perfiles p where p.activo and p.nivel = 'lider' and p.departamento = 'Limpieza'
        and (p.zona is null or p.zona = pe.zona);
    end if;

    if pe.prioritario then
      update _dest set t_es = '⚠ ' || t_es, t_en = '⚠ ' || t_en where true;  -- Supabase exige WHERE en todo UPDATE
    end if;

  elsif p_tipo = 'limpieza' then
    select * into li from public.limpiezas where id = p_id;
    if not found then return; end if;
    select * into pr from public.propiedades where id = li.propiedad_id;
    if li.estado = 'terminada' and li.cierre->>'llaves' = 'false' then
      -- 10. Llaves NO dejadas en el key box → lider de limpieza y lider de drivers (urgente)
      insert into _dest select p.id, p.idioma,
        '⚠ Llaves NO en el key box: ' || pr.codigo, '⚠ Keys NOT in the key box: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''), pr.pueblo || coalesce(' · ' || (li.cierre->>'motivo_llaves'), ''),
        case when p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, 'limpieza:' || li.id || ':llaves:' || p.id
      from public.perfiles p
      where p.activo and p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona);
      v_aviso := 'limpieza:' || li.id || ':llaves';
    elsif li.estado::text = 'cancelada' and li.publicada then
      -- 12. Limpieza cancelada → su cleaner
      insert into _dest select p.id, p.idioma,
        'Cancelada: ' || pr.codigo, 'Cancelled: ' || pr.codigo,
        pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''), pr.pueblo || coalesce(' · ' || li.cancelada_motivo, ''),
        './', 'limpieza:' || li.id || ':cancelada:' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':cancelada';
    elsif li.estado = 'asignada' and li.publicada and li.reabierta_en > now() - interval '2 minutes' then
      -- 13. Limpieza reabierta (tras "no pude entrar") → su cleaner
      insert into _dest select p.id, p.idioma,
        'Reabierta: ' || pr.codigo, 'Reopened: ' || pr.codigo,
        pr.pueblo || ' · vuelve a tu lista', pr.pueblo || ' · back on your list',
        './', 'limpieza:' || li.id || ':reabierta:' || extract(epoch from li.reabierta_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = li.asignada_a;
      v_aviso := 'limpieza:' || li.id || ':reabierta';
    elsif li.estado <> 'no_pude_entrar' then
      return;
    else
    v_aviso := 'limpieza:' || li.id || ':' || li.estado;
    -- 6. No pude entrar → lider de limpieza, lider de drivers y drivers de la zona
    insert into _dest select p.id, p.idioma,
      'No pudo entrar: ' || pr.codigo, 'Couldn''t get in: ' || pr.codigo,
      pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''), pr.pueblo || coalesce(' · ' || li.motivo_no_entrar, ''),
      case when p.nivel = 'lider' and p.departamento = 'Limpieza' then './?v=seguimiento' else './' end, null
    from public.perfiles p
    where p.activo and (
         (p.nivel = 'lider' and p.departamento in ('Limpieza', 'Drivers') and (p.zona is null or p.zona = li.zona))
      or (p.nivel = 'operador' and p.departamento = 'Drivers' and p.zona = li.zona));
    end if;

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

  update _dest set clave = coalesce(clave, v_aviso || ':' || _dest.perfil_id) where true;

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

-- 8. Historial de una limpieza (líder de limpieza u Operación) -----------------------
create or replace function public.historial(p_limpieza uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo el líder de limpieza u Operación.'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('en', e.cuando, 'que', e.que, 'quien', coalesce(p.nombre, '—')) order by e.cuando, e.id)
                   from public.eventos e left join public.perfiles p on p.id = e.quien
                   where e.limpieza_id = p_limpieza), '[]'::jsonb);
end $$;

-- 9. Informe del piloto (solo Operación): lo que mide si el piloto funciona ----------------
create or replace function public.informe(p_desde date, p_hasta date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 366 then
    raise exception 'Periodo no válido (máximo un año).';
  end if;
  return jsonb_build_object(
    'limpiezas', (select jsonb_build_object(
        'total', count(*),
        'terminadas', count(*) filter (where l.estado = 'terminada'),
        'canceladas', count(*) filter (where l.estado::text = 'cancelada'),
        'no_pudo_entrar', count(*) filter (where l.estado = 'no_pude_entrar'),
        'qr_ambos', count(*) filter (where l.estado = 'terminada' and l.inicio_qr and l.fin_qr),
        'sin_qr', count(*) filter (where l.estado = 'terminada' and (l.inicio_qr is not true or l.fin_qr is not true)),
        'gps_lejos', count(*) filter (where (l.gps->'inicio'->>'dist')::int > 200 or (l.gps->'fin'->>'dist')::int > 200),
        'sin_gps', count(*) filter (where l.estado = 'terminada' and ((l.gps->'inicio'->>'sin_gps')::boolean or (l.gps->'fin'->>'sin_gps')::boolean)),
        'linens_revisados', count(*) filter (where l.estado = 'terminada' and l.linens_revisado is not null),
        'llaves_no', count(*) filter (where l.cierre->>'llaves' = 'false'),
        'basura', count(*) filter (where l.cierre->>'basura' = 'true'),
        'media_min', round(avg(extract(epoch from l.fin - l.inicio) / 60) filter (
                       where l.estado = 'terminada' and l.inicio_qr and l.fin_qr and l.fin - l.inicio between interval '10 minutes' and interval '6 hours')))
      from public.limpiezas l where l.fecha between p_desde and p_hasta),
    'pendientes', (select coalesce(jsonb_object_agg(t.tipo, t.datos), '{}'::jsonb) from (
        select pe.tipo::text as tipo, jsonb_build_object(
          'total', count(*), 'cerrados', count(*) filter (where pe.estado = 'cerrado'),
          'abiertos', count(*) filter (where pe.estado <> 'cerrado'),
          'abiertos_24h', count(*) filter (where pe.estado <> 'cerrado' and pe.creado_en < now() - interval '24 hours'),
          'incidencias', count(*) filter (where pe.incidencia is not null),
          'minutos_cierre', round(avg(extract(epoch from pe.cerrado_en - pe.creado_en) / 60) filter (where pe.estado = 'cerrado'))) as datos
        from public.pendientes pe where pe.fecha between p_desde and p_hasta group by pe.tipo) t),
    'articulos', (select coalesce(jsonb_agg(jsonb_build_object('item', a.item, 'cantidad', a.n) order by a.n desc), '[]'::jsonb) from (
        select x->>'item' as item, sum((x->>'cantidad')::int) as n
        from public.pendientes pe, jsonb_array_elements(pe.items) x
        where pe.fecha between p_desde and p_hasta and pe.items is not null group by x->>'item') a),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('fecha', d.fecha, 'terminadas', d.terminadas, 'pendientes', d.pendientes, 'cerrados', d.cerrados) order by d.fecha), '[]'::jsonb) from (
        select f.fecha,
               (select count(*) from public.limpiezas l where l.fecha = f.fecha and l.estado = 'terminada') as terminadas,
               (select count(*) from public.pendientes pe where pe.fecha = f.fecha) as pendientes,
               (select count(*) from public.pendientes pe where pe.fecha = f.fecha and pe.estado = 'cerrado') as cerrados
        from generate_series(p_desde, p_hasta, interval '1 day') g, lateral (select g::date as fecha) f) d
        where d.terminadas + d.pendientes > 0));
end $$;

-- 10. Permisos -----------------------------------------------------------------------
revoke execute on function
  public.iniciar_con_qr(uuid, text, double precision, double precision, double precision),
  public.iniciar_limpieza(uuid, double precision, double precision, double precision),
  public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text, double precision, double precision, double precision),
  public.cancelar_limpieza(uuid, text), public.reabrir_limpieza(uuid), public.no_pude_entregar(uuid, text),
  public.resolver_incidencia(uuid), public.historial(uuid), public.informe(date, date)
from public, anon;
grant execute on function
  public.iniciar_con_qr(uuid, text, double precision, double precision, double precision),
  public.iniciar_limpieza(uuid, double precision, double precision, double precision),
  public.cerrar_limpieza(uuid, text, boolean, boolean, boolean, boolean, boolean, text, double precision, double precision, double precision),
  public.cancelar_limpieza(uuid, text), public.reabrir_limpieza(uuid), public.no_pude_entregar(uuid, text),
  public.resolver_incidencia(uuid), public.historial(uuid), public.informe(date, date)
to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;
