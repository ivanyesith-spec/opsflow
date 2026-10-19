-- OpsFlow · ubicaciones: coordenada revisada de cada apartamento (10 oct 2026)
-- Tres fuentes: enlace de mapa → TomTom → GPS de los escaneos. Solo Operación confirma.
-- Solo las coordenadas CONFIRMADAS se usan para el GPS de la limpieza.
-- Ejecutar DESPUES de 023. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.

-- 1. Datos nuevos -----------------------------------------------------------------
alter table public.propiedades add column if not exists coord_estado text not null default 'sin';
alter table public.propiedades add column if not exists coord_fuente text;         -- enlace / tomtom / gps / manual
alter table public.propiedades add column if not exists coord_motivo text;         -- por qué está dudosa (una frase)
alter table public.propiedades add column if not exists coord_info jsonb;          -- resumen de TomTom, punto anterior…
alter table public.propiedades add column if not exists coord_confirmada_por uuid;
alter table public.propiedades add column if not exists coord_confirmada_en timestamptz;
alter table public.propiedades add column if not exists pueblo_tomtom text;        -- el pueblo como lo escribe TomTom
alter table public.eventos     add column if not exists propiedad_id uuid references public.propiedades(id) on delete cascade;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'propiedades_coord_estado_check') then
    alter table public.propiedades add constraint propiedades_coord_estado_check
      check (coord_estado in ('sin', 'propuesta', 'dudosa', 'confirmada'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'propiedades_coord_fuente_check') then
    alter table public.propiedades add constraint propiedades_coord_fuente_check
      check (coord_fuente is null or coord_fuente in ('enlace', 'tomtom', 'gps', 'manual'));
  end if;
end $$;
-- Las coordenadas que ya estaban escritas a mano quedan como "propuestas": Operación las confirma
update public.propiedades set coord_estado = 'propuesta', coord_fuente = 'manual'
where lat is not null and coord_estado = 'sin';

-- Los líderes y Operación pueden ver el estado; el código QR sigue oculto
grant select (id, codigo, nombre, zona, pueblo, direccion, mapa_url, camas_dobles, camas_indiv, sofas_cama, banos,
              notas, activa, es_prueba, creado_en, lat, lng, coord_estado, coord_fuente, coord_motivo, coord_info,
              coord_confirmada_en, pueblo_tomtom) on public.propiedades to authenticated;

-- 2. Ayudantes ---------------------------------------------------------------------
create or replace function public._en_malta(p_lat double precision, p_lng double precision)
returns boolean language sql immutable set search_path = ''
as $$ select p_lat between 35.78 and 36.10 and p_lng between 14.15 and 14.60 $$;
revoke execute on function public._en_malta(double precision, double precision) from public, anon, authenticated;

-- Escribir la coordenada desde las funciones de este archivo (el disparador de abajo las deja pasar)
create or replace function public._fijar_coord(p_prop uuid, p_lat double precision, p_lng double precision, p_estado text,
  p_fuente text, p_motivo text, p_info jsonb, p_pueblo text, p_que text)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform set_config('opsflow.coord', '1', true);
  update public.propiedades set lat = p_lat, lng = p_lng, coord_estado = p_estado, coord_fuente = p_fuente,
    coord_motivo = p_motivo, coord_info = p_info, pueblo_tomtom = coalesce(p_pueblo, pueblo_tomtom),
    coord_confirmada_por = case when p_estado = 'confirmada' then (select auth.uid()) end,
    coord_confirmada_en  = case when p_estado = 'confirmada' then now() end
  where id = p_prop;
  perform set_config('opsflow.coord', '', true);
  insert into public.eventos (quien, que, propiedad_id) values ((select auth.uid()), p_que, p_prop);
end $$;
revoke execute on function public._fijar_coord(uuid, double precision, double precision, text, text, text, jsonb, text, text) from public, anon, authenticated;

-- 3. Cambios hechos a mano desde la ficha ----------------------------------------------
--   · El estado, la fuente y la confirmación no se pueden escribir directamente.
--   · Punto nuevo escrito a mano → "propuesta" (o "dudosa" si cae fuera de Malta).
--   · Cambia la dirección, el pueblo o el enlace → la coordenada vuelve a "propuesta".
create or replace function public._coord_cambios()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if coalesce(current_setting('opsflow.coord', true), '') = '1' then return new; end if;
  if tg_op = 'INSERT' then
    new.coord_fuente := null; new.coord_motivo := null; new.coord_info := null; new.pueblo_tomtom := null;
    new.coord_confirmada_por := null; new.coord_confirmada_en := null; new.coord_estado := 'sin';
    if new.lat is not null then new.coord_estado := 'propuesta'; new.coord_fuente := 'manual'; end if;
  else
    new.coord_estado := old.coord_estado; new.coord_fuente := old.coord_fuente; new.coord_motivo := old.coord_motivo;
    new.coord_info := old.coord_info; new.pueblo_tomtom := old.pueblo_tomtom;
    new.coord_confirmada_por := old.coord_confirmada_por; new.coord_confirmada_en := old.coord_confirmada_en;
    if (new.lat, new.lng) is distinct from (old.lat, old.lng) then
      new.coord_confirmada_por := null; new.coord_confirmada_en := null; new.coord_info := null; new.coord_motivo := null;
      if new.lat is null then new.coord_estado := 'sin'; new.coord_fuente := null;
      else new.coord_estado := 'propuesta'; new.coord_fuente := 'manual';
      end if;
    elsif (new.direccion, new.pueblo, new.mapa_url) is distinct from (old.direccion, old.pueblo, old.mapa_url)
          and old.coord_estado <> 'sin' then
      new.coord_estado := 'propuesta'; new.coord_confirmada_por := null; new.coord_confirmada_en := null;
      new.coord_motivo := 'La dirección cambió: revisa el punto';
    end if;
  end if;
  if new.lat is not null and not public._en_malta(new.lat, new.lng) then
    new.coord_estado := 'dudosa'; new.coord_motivo := 'Fuera de Malta y Gozo';
  end if;
  return new;
end $$;
revoke execute on function public._coord_cambios() from public, anon, authenticated;
drop trigger if exists propiedades_coord on public.propiedades;
create trigger propiedades_coord before insert or update on public.propiedades
for each row execute function public._coord_cambios();

-- 4. Confirmar (solo Operación, después de mirar el punto en el mapa) -------------------
create or replace function public.ubicacion_confirmar(p_prop uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare p public.propiedades;
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación confirma ubicaciones.'; end if;
  select * into p from public.propiedades where id = p_prop;
  if not found then raise exception 'Esa propiedad no existe.'; end if;
  if p.lat is null then raise exception 'No hay ningún punto que confirmar.'; end if;
  if not public._en_malta(p.lat, p.lng) then raise exception 'El punto está fuera de Malta y Gozo: corrígelo antes.'; end if;
  perform public._fijar_coord(p_prop, p.lat, p.lng, 'confirmada', p.coord_fuente, null, p.coord_info, null, 'ubicación confirmada');
end $$;
revoke execute on function public.ubicacion_confirmar(uuid) from public, anon;
grant  execute on function public.ubicacion_confirmar(uuid) to authenticated;

-- 5. Lo que usa la función "geocodificar" (solo el servidor) ------------------------------
-- Qué buscar: las marcadas (si no están confirmadas) o, si no se marca ninguna, las activas sin coordenada. Máx. 50.
create or replace function public.ubicaciones_para_buscar(p_ids uuid[] default null)
returns table (id uuid, codigo text, direccion text, pueblo text, mapa_url text, lat double precision, lng double precision, coord_estado text)
language sql stable security definer set search_path = ''
as $$
  select p.id, p.codigo, p.direccion, p.pueblo, p.mapa_url, p.lat, p.lng, p.coord_estado
  from public.propiedades p
  where p.coord_estado <> 'confirmada'
    and (case when p_ids is null or cardinality(p_ids) = 0 then p.activa and p.coord_estado = 'sin' else p.id = any(p_ids) end)
  order by p.codigo limit 50
$$;
revoke execute on function public.ubicaciones_para_buscar(uuid[]) from public, anon, authenticated;
grant  execute on function public.ubicaciones_para_buscar(uuid[]) to service_role;

-- Guardar lo encontrado. Nunca pisa una confirmada. Devuelve el estado final (o 'confirmada' si no tocó nada).
create or replace function public.ubicacion_guardar(p_prop uuid, p_lat double precision, p_lng double precision, p_fuente text,
  p_dudosa boolean, p_motivo text, p_info jsonb default null, p_pueblo text default null)
returns text language plpgsql security definer set search_path = ''
as $$
declare p public.propiedades; v_estado text; v_motivo text := nullif(btrim(coalesce(p_motivo, '')), ''); d int;
        v_info jsonb := coalesce(p_info, '{}'::jsonb);
begin
  if coalesce(p_fuente, '') not in ('enlace', 'tomtom') then raise exception 'Fuente no válida.'; end if;
  if p_lat is null or p_lng is null then raise exception 'Faltan las coordenadas.'; end if;
  select * into p from public.propiedades where id = p_prop for update;
  if not found then raise exception 'Esa propiedad no existe.'; end if;
  if p.coord_estado = 'confirmada' then return 'confirmada'; end if;
  v_estado := case when coalesce(p_dudosa, false) then 'dudosa' else 'propuesta' end;
  if not public._en_malta(p_lat, p_lng) then
    v_estado := 'dudosa'; v_motivo := 'Fuera de Malta y Gozo';
  elsif p.lat is not null then
    -- Había otro punto (escrito a mano o del GPS): si están a más de 150 m, algo no cuadra
    d := public._distancia_m(p.lat, p.lng, p_lat, p_lng);
    if d > 150 then
      v_estado := 'dudosa';
      v_motivo := concat_ws(' · ', v_motivo, format('El punto anterior (%s) y %s están a %s m', coalesce(p.coord_fuente, 'manual'),
                  case p_fuente when 'enlace' then 'el enlace' else 'TomTom' end, d));
      v_info := v_info || jsonb_build_object('anterior', jsonb_build_object('lat', p.lat, 'lng', p.lng, 'fuente', p.coord_fuente));
    end if;
  end if;
  if v_estado = 'propuesta' then v_motivo := null; end if;
  perform public._fijar_coord(p_prop, p_lat, p_lng, v_estado, p_fuente, left(v_motivo, 200), v_info, p_pueblo,
    format('ubicación %s (%s)', v_estado, p_fuente));
  return v_estado;
end $$;
revoke execute on function public.ubicacion_guardar(uuid, double precision, double precision, text, boolean, text, jsonb, text) from public, anon, authenticated;
grant  execute on function public.ubicacion_guardar(uuid, double precision, double precision, text, boolean, text, jsonb, text) to service_role;

-- 6. GPS de los escaneos ------------------------------------------------------------------
-- La distancia solo se calcula contra una coordenada CONFIRMADA. Con buena precisión (≤ 30 m)
-- se guarda también el punto del teléfono, para proponer o vigilar la coordenada del apartamento.
create or replace function public._gps(p_prop uuid, p_lat double precision, p_lng double precision, p_prec double precision)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_lat double precision; v_lng double precision; v_est text; r jsonb;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return jsonb_build_object('sin_gps', true);
  end if;
  select lat, lng, coord_estado into v_lat, v_lng, v_est from public.propiedades where id = p_prop;
  r := jsonb_build_object('sin_gps', false,
    'dist', case when v_est = 'confirmada' and v_lat is not null then public._distancia_m(v_lat, v_lng, p_lat, p_lng) end,
    'prec', case when p_prec is null or p_prec < 0 then null else least(round(p_prec), 100000)::int end);
  if p_prec is not null and p_prec between 0 and 30 then
    r := r || jsonb_build_object('lat', round(p_lat::numeric, 6), 'lng', round(p_lng::numeric, 6), 'en', now());
  end if;
  return r;
end $$;
revoke execute on function public._gps(uuid, double precision, double precision, double precision) from public, anon, authenticated;

-- Escaneos buenos (≤ 30 m) de una propiedad, opcionalmente desde una fecha
create or replace function public._escaneos(p_prop uuid, p_desde timestamptz default null)
returns table (lat double precision, lng double precision, en timestamptz, prec int)
language sql stable security definer set search_path = ''
as $$
  select (g.value->>'lat')::double precision, (g.value->>'lng')::double precision, (g.value->>'en')::timestamptz, (g.value->>'prec')::int
  from public.limpiezas l, jsonb_each(coalesce(l.gps, '{}'::jsonb)) g
  where l.propiedad_id = p_prop and jsonb_typeof(g.value) = 'object' and g.value ? 'lat'
    and (g.value->>'prec')::int <= 30
    and (p_desde is null or (g.value->>'en')::timestamptz >= p_desde)
$$;
revoke execute on function public._escaneos(uuid, timestamptz) from public, anon, authenticated;

-- Tras cada escaneo:
--   · sin coordenada → se propone la del teléfono
--   · propuesta (de otra fuente) y el teléfono cae a más de 150 m → dudosa
--   · confirmada y 3+ escaneos desde la confirmación caen de media a más de 100 m → dudosa
create or replace function public._revisar_ubicacion(p_prop uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare p public.propiedades; e record; n int; m int;
begin
  select * into p from public.propiedades where id = p_prop;
  if not found then return; end if;
  if p.coord_estado = 'sin' then
    select * into e from public._escaneos(p_prop) order by prec, en desc limit 1;
    if found then
      perform public._fijar_coord(p_prop, e.lat, e.lng, case when public._en_malta(e.lat, e.lng) then 'propuesta' else 'dudosa' end,
        'gps', case when public._en_malta(e.lat, e.lng) then null else 'Fuera de Malta y Gozo' end,
        jsonb_build_object('prec', e.prec), null, 'ubicación propuesta (gps)');
    end if;
  elsif p.coord_estado = 'propuesta' and p.coord_fuente <> 'gps' then
    select * into e from public._escaneos(p_prop) order by en desc limit 1;
    if found then
      m := public._distancia_m(p.lat, p.lng, e.lat, e.lng);
      if m > 150 then
        perform public._fijar_coord(p_prop, p.lat, p.lng, 'dudosa', p.coord_fuente,
          format('El GPS de un escaneo cae a %s m del punto propuesto', m),
          coalesce(p.coord_info, '{}'::jsonb) || jsonb_build_object('gps', jsonb_build_object('lat', e.lat, 'lng', e.lng)), null,
          'ubicación dudosa (gps)');
      end if;
    end if;
  elsif p.coord_estado = 'confirmada' then
    select count(*), round(avg(public._distancia_m(p.lat, p.lng, s.lat, s.lng))) into n, m
    from public._escaneos(p_prop, p.coord_confirmada_en) s;
    if n >= 3 and m > 100 then
      perform public._fijar_coord(p_prop, p.lat, p.lng, 'dudosa', p.coord_fuente,
        format('El GPS de %s escaneos cae a %s m de media', n, m), p.coord_info, null, 'ubicación dudosa (gps)');
    end if;
  end if;
end $$;
revoke execute on function public._revisar_ubicacion(uuid) from public, anon, authenticated;

create or replace function public._limpieza_gps()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.gps is distinct from old.gps and new.gps is not null then perform public._revisar_ubicacion(new.propiedad_id); end if;
  return new;
end $$;
revoke execute on function public._limpieza_gps() from public, anon, authenticated;
drop trigger if exists limpiezas_gps on public.limpiezas;
create trigger limpiezas_gps after update of gps on public.limpiezas
for each row execute function public._limpieza_gps();

-- Resumen para la ficha (solo Operación): escaneos buenos y distancia media al punto actual
create or replace function public.ubicacion_escaneos(p_prop uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare p public.propiedades; n int; m int;
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación.'; end if;
  select * into p from public.propiedades where id = p_prop;
  select count(*), case when p.lat is null then null else round(avg(public._distancia_m(p.lat, p.lng, s.lat, s.lng))) end
    into n, m from public._escaneos(p_prop) s;
  return jsonb_build_object('n', n, 'media_m', m);
end $$;
revoke execute on function public.ubicacion_escaneos(uuid) from public, anon;
grant  execute on function public.ubicacion_escaneos(uuid) to authenticated;

-- 7. Tráfico: un pueblo también se reconoce por cómo lo escribe TomTom (solo coordenadas confirmadas) ----
create or replace function public._zona_de_pueblo(p_pueblo text)
returns text language sql stable security definer set search_path = ''
as $$
  select coalesce((
    select p.zona::text from public.propiedades p
    where p.activa and coalesce(p_pueblo, '') <> ''
      and (lower(regexp_replace(p.pueblo, '[^[:alpha:]]', '', 'g')) = lower(regexp_replace(p_pueblo, '[^[:alpha:]]', '', 'g'))
           or (p.coord_estado = 'confirmada' and p.pueblo_tomtom is not null
               and lower(regexp_replace(p.pueblo_tomtom, '[^[:alpha:]]', '', 'g')) = lower(regexp_replace(p_pueblo, '[^[:alpha:]]', '', 'g'))))
    group by p.zona order by count(*) desc limit 1), 'General')
$$;
revoke execute on function public._zona_de_pueblo(text) from public, anon, authenticated;

-- Comprobación: debe salir una fila con el número de propiedades por estado
select coord_estado, count(*) from public.propiedades group by 1 order by 1;
