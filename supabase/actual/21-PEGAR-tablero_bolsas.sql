-- OpsFlow · tablero de zonas para drivers + bolsas de linens con QR (10 oct 2026)
-- Todos los drivers ven lo pendiente de Norte / Centro / Sur, cogen tareas ("I'll take it") y el líder asigna.
-- Cada limpieza tiene su bolsa de linens: linens la prepara (etiqueta QR) → el driver la escanea → la entrega con foto.
-- Ejecutar DESPUES de 020. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.

-- 1. Quién lleva cada tarea --------------------------------------------------------
alter table public.pendientes add column if not exists tomado_por uuid references public.perfiles(id);
alter table public.pendientes add column if not exists tomado_en timestamptz;
alter table public.pendientes add column if not exists asignado_por uuid;     -- si lo asignó el líder

-- Todos los drivers ven lo que está en manos de los drivers en TODAS las zonas (antes, solo la suya)
drop policy if exists "pendientes: lectura por rol" on public.pendientes;
create policy "pendientes: lectura por rol" on public.pendientes for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Limpieza')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Linens' and tipo::text = 'linens')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Bodega' and tipo::text = 'utiles')
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers' and tipo::text in ('linens', 'recogida', 'utiles'))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Limpieza'
       and limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid())))
  or ((select public.mi_nivel()) = 'operador' and (select public.mi_departamento()) = 'Drivers'
       and (tipo::text = 'recogida' or (tipo::text in ('linens', 'utiles') and estado <> 'abierto')))
);

-- ¿Puede quien llama trabajar como driver? (driver, líder de drivers u Operación)
create or replace function public._es_driver()
returns boolean language sql stable security definer set search_path = ''
as $$ select public.mi_departamento() = 'Drivers' or public.mi_nivel() = 'operacion' $$;
revoke execute on function public._es_driver() from public, anon, authenticated;

-- ¿Está esta tarea en manos de los drivers?
create or replace function public._en_driver(v public.pendientes)
returns boolean language sql immutable set search_path = ''
as $$ select (v.tipo::text in ('linens', 'utiles') and v.estado::text = 'preparado') or (v.tipo::text = 'recogida' and v.estado::text = 'abierto') $$;
revoke execute on function public._en_driver(public.pendientes) from public, anon, authenticated;

-- 2. Tablero de zonas: todo lo pendiente para drivers (últimos 7 días), check-in de hoy primero ----
create or replace function public.tablero_zonas()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return coalesce((select jsonb_agg(x order by x->>'zona', (x->>'prioridad')::int desc, x->>'entrada' nulls last, x->>'desde') from (
    select jsonb_build_object(
      'id', pe.id, 'zona', pe.zona, 'tipo', pe.tipo, 'detalle', pe.detalle, 'cantidad', pe.cantidad, 'items', pe.items,
      'foto', pe.foto, 'incidencia', pe.incidencia, 'fecha', pe.fecha,
      'desde', coalesce(pe.preparado_en, pe.creado_en),
      'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo, 'direccion', p.direccion, 'mapa', p.mapa_url,
      'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
      'prioridad', case when c.fecha = v_hoy and c.hora_entrada is not null then 1 else 0 end,
      'tomado_por', t.nombre, 'mio', pe.tomado_por = (select auth.uid()), 'asignado', pe.asignado_por is not null) as x
    from public.pendientes pe
    join public.propiedades p on p.id = pe.propiedad_id
    join public.limpiezas l on l.id = pe.limpieza_id
    join public.checkouts c on c.id = l.checkout_id
    left join public.perfiles t on t.id = pe.tomado_por
    where public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb);
end $$;

-- 3. Coger, soltar y asignar --------------------------------------------------------------
create or replace function public.tomar_tarea(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes; v_quien text;
begin
  if not (public.mi_departamento() = 'Drivers' and public.mi_nivel() = 'operador') then raise exception 'Only drivers take jobs.'; end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or not public._en_driver(v) then raise exception 'This job is not waiting for a driver.'; end if;
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid()) then
    select nombre into v_quien from public.perfiles where id = v.tomado_por;
    raise exception '% is already on it.', v_quien;
  end if;
  update public.pendientes set tomado_por = (select auth.uid()), tomado_en = now(), asignado_por = null where id = p_id;
  perform public._evento('tarea cogida por driver', v.limpieza_id, p_id);
end $$;

create or replace function public.soltar_tarea(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  if v.tomado_por is distinct from (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Only the driver who took it (or the leader) can release it.';
  end if;
  update public.pendientes set tomado_por = null, tomado_en = null, asignado_por = null where id = p_id;
  perform public._evento('tarea soltada', v.limpieza_id, p_id);
end $$;

create or replace function public.asignar_tarea(p_id uuid, p_driver uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo el líder de drivers u Operación asignan.';
  end if;
  select * into v from public.pendientes where id = p_id for update;
  if not found or not public._en_driver(v) then raise exception 'Ese pendiente no está esperando a un driver.'; end if;
  if not exists (select 1 from public.perfiles where id = p_driver and activo and departamento = 'Drivers' and nivel = 'operador') then
    raise exception 'Solo se asigna a un driver activo.';
  end if;
  update public.pendientes set tomado_por = p_driver, tomado_en = now(), asignado_por = (select auth.uid()) where id = p_id;
  perform public._evento('asignada a driver por el líder', v.limpieza_id, p_id);
end $$;

-- 4. Bolsas de linens con QR ---------------------------------------------------------------
create table if not exists public.bolsas (
  id           uuid primary key default gen_random_uuid(),
  limpieza_id  uuid not null unique references public.limpiezas(id) on delete cascade,
  propiedad_id uuid not null references public.propiedades(id),
  zona         public.zona not null,
  fecha        date not null,
  token        text not null unique default replace(gen_random_uuid()::text, '-', ''),
  estado       text not null default 'por_preparar' check (estado in ('por_preparar', 'preparada', 'en_camion', 'entregada')),
  preparada_por uuid, preparada_en timestamptz,
  driver       uuid references public.perfiles(id), recogida_en timestamptz,
  entregada_en timestamptz, comentario text check (length(comentario) <= 300),
  incidencia   text, incidencia_en timestamptz,
  es_prueba    boolean not null default false
);
alter table public.bolsas enable row level security;
revoke all on public.bolsas from anon;
revoke insert, update, delete, truncate on public.bolsas from authenticated;
revoke select (token) on public.bolsas from authenticated;
drop policy if exists "bolsas: lectura" on public.bolsas;
create policy "bolsas: lectura" on public.bolsas for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) in ('Linens', 'Drivers', 'Limpieza'))
  or ((select public.mi_departamento()) = 'Drivers' and (select public.mi_nivel()) = 'operador')
  or limpieza_id in (select id from public.limpiezas where asignada_a = (select auth.uid()))
);
-- El token (lo que lleva el QR) no se lee de la tabla: solo linens lo imprime
do $$ begin
  revoke select on public.bolsas from authenticated;
  grant select (id, limpieza_id, propiedad_id, zona, fecha, estado, preparada_por, preparada_en, driver, recogida_en,
                entregada_en, comentario, incidencia, incidencia_en, es_prueba) on public.bolsas to authenticated;
end $$;

-- La foto de entrega se guarda como una "sala" más de la limpieza: <limpieza>/bolsa.jpg (se borra a los 30 días)
do $$ declare c text; begin
  for c in select conname from pg_constraint
           where conrelid = 'public.fotos_cierre'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%sala%'
  loop execute format('alter table public.fotos_cierre drop constraint %I', c); end loop;
end $$;
alter table public.fotos_cierre add constraint fotos_cierre_sala_check
  check (sala in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura', 'bolsa'));

-- Subir foto: el cleaner (su limpieza en curso) o el driver que lleva esa bolsa (solo bolsa.jpg)
create or replace function public._puede_subir_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and l.asignada_a = (select auth.uid()) and l.publicada and l.estado = 'en_curso'
      and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and exists (
    select 1 from public.bolsas b
    where b.limpieza_id::text = split_part(p_nombre, '/', 1) and b.driver = (select auth.uid()) and b.estado = 'en_camion'))
$$;
-- Ver fotos: como antes + la de la bolsa la ven linens, drivers y el cleaner de esa limpieza
create or replace function public._puede_ver_foto(p_nombre text)
returns boolean language sql stable security definer set search_path = ''
as $$
  select public._lider_limpieza()
  or exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1) and l.asignada_a = (select auth.uid()) and public.mi_nivel() is not null)
  or (split_part(p_nombre, '/', 2) = 'basura.jpg' and public.mi_departamento() = 'Drivers' and exists (
    select 1 from public.limpiezas l
    where l.id::text = split_part(p_nombre, '/', 1)
      and (public.mi_nivel() = 'lider' or l.zona = public.mi_zona())))
  or (split_part(p_nombre, '/', 2) = 'bolsa.jpg' and (public.mi_departamento() in ('Drivers', 'Linens')))
$$;
revoke execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) from public, anon;
grant  execute on function public._puede_subir_foto(text), public._puede_ver_foto(text) to authenticated;

-- Bolsas de un día (se crean solas para cada limpieza no cancelada). Linens, líderes de drivers/limpieza y Operación.
create or replace function public.bolsas_dia(p_fecha date)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() in ('Linens', 'Drivers', 'Limpieza'))) then
    raise exception 'Solo linens, los líderes u Operación.';
  end if;
  insert into public.bolsas (limpieza_id, propiedad_id, zona, fecha, es_prueba)
  select l.id, l.propiedad_id, l.zona, l.fecha, l.es_prueba from public.limpiezas l
  where l.fecha = p_fecha and l.estado::text <> 'cancelada'
  on conflict (limpieza_id) do nothing;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', b.id, 'estado', b.estado, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
      'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'salida', to_char(c.hora_salida, 'HH24:MI'),
      'cancelada', l.estado::text = 'cancelada', 'driver', d.nombre, 'recogida_en', b.recogida_en, 'entregada_en', b.entregada_en,
      'comentario', b.comentario, 'incidencia', b.incidencia,
      'foto', (select f.ruta from public.fotos_cierre f where f.limpieza_id = b.limpieza_id and f.sala = 'bolsa'))
      order by (c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
    from public.bolsas b join public.limpiezas l on l.id = b.limpieza_id join public.propiedades p on p.id = b.propiedad_id
    join public.checkouts c on c.id = l.checkout_id left join public.perfiles d on d.id = b.driver
    where b.fecha = p_fecha), '[]'::jsonb);
end $$;

-- Linens: bolsa preparada (y deshacer si se equivocó, mientras no la haya cogido un driver)
create or replace function public.preparar_bolsa(p_bolsa uuid, p_lista boolean default true)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Linens')) then
    raise exception 'Solo linens u Operación preparan bolsas.';
  end if;
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found then raise exception 'Esa bolsa no existe.'; end if;
  if v.estado not in ('por_preparar', 'preparada') then raise exception 'Esa bolsa ya la tiene un driver.'; end if;
  if exists (select 1 from public.limpiezas where id = v.limpieza_id and estado::text = 'cancelada') then raise exception 'Esa limpieza está cancelada.'; end if;
  update public.bolsas set estado = case when p_lista then 'preparada' else 'por_preparar' end,
         preparada_por = case when p_lista then (select auth.uid()) end, preparada_en = case when p_lista then now() end
   where id = p_bolsa;
  perform public._evento(case when p_lista then 'bolsa preparada' else 'bolsa vuelve a por preparar' end, v.limpieza_id, null);
end $$;

-- Etiquetas para imprimir (con el código del QR): solo linens y Operación
create or replace function public.bolsas_etiquetas(p_fecha date)
returns table (codigo text, nombre text, fecha date, zona text, qr text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Linens')) then
    raise exception 'Solo linens u Operación.';
  end if;
  return query select p.codigo, p.nombre, b.fecha, b.zona::text, 'OPSFLOW-BAG:' || b.token
    from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
    where b.fecha = p_fecha and l.estado::text <> 'cancelada' order by p.codigo;
end $$;

-- Driver: escanear la etiqueta → la bolsa pasa a SU lista
create or replace function public.escanear_bolsa(p_qr text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas; v_quien text; v_cod text;
begin
  if not (public.mi_departamento() = 'Drivers' and public.mi_nivel() = 'operador') then raise exception 'Only drivers scan bags.'; end if;
  select * into v from public.bolsas where token = regexp_replace(btrim(coalesce(p_qr, '')), '^OPSFLOW-BAG:', '') for update;
  if not found then raise exception 'This is not an OpsFlow bag label.'; end if;
  select codigo into v_cod from public.propiedades where id = v.propiedad_id;
  if exists (select 1 from public.limpiezas where id = v.limpieza_id and estado::text = 'cancelada') then raise exception 'Cleaning cancelled: leave the bag % at linens.', v_cod; end if;
  if v.estado = 'por_preparar' then raise exception 'Bag % is not ready yet (linens has not marked it).', v_cod; end if;
  if v.estado = 'entregada' then raise exception 'Bag % was already delivered.', v_cod; end if;
  if v.estado = 'en_camion' and v.driver <> (select auth.uid()) then
    select nombre into v_quien from public.perfiles where id = v.driver;
    raise exception 'Bag % is already with %.', v_cod, v_quien;
  end if;
  update public.bolsas set estado = 'en_camion', driver = (select auth.uid()), recogida_en = coalesce(recogida_en, now()) where id = v.id;
  perform public._evento('bolsa recogida en linens', v.limpieza_id, null);
  return jsonb_build_object('id', v.id, 'codigo', v_cod);
end $$;

-- Driver: entregada, con foto (obligatoria, ya subida a <limpieza>/bolsa.jpg) y comentario opcional
create or replace function public.entregar_bolsa(p_bolsa uuid, p_ruta text, p_comentario text default null)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found or v.driver is distinct from (select auth.uid()) or v.estado <> 'en_camion' then
    raise exception 'This bag is not on your list.';
  end if;
  if p_ruta is distinct from v.limpieza_id || '/bolsa.jpg' then raise exception 'Take the delivery photo first.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por) values (v.limpieza_id, 'bolsa', p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
  update public.bolsas set estado = 'entregada', entregada_en = now(), comentario = nullif(left(btrim(coalesce(p_comentario, '')), 300), ''),
         incidencia = null, incidencia_en = null where id = p_bolsa;
  perform public._evento('bolsa entregada' || coalesce(': ' || nullif(btrim(coalesce(p_comentario, '')), ''), ''), v.limpieza_id, null);
end $$;

-- Driver: no pudo entregar la bolsa (sigue en su lista; el líder lo ve)
create or replace function public.no_pude_entregar_bolsa(p_bolsa uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.bolsas;
begin
  select * into v from public.bolsas where id = p_bolsa for update;
  if not found or v.driver is distinct from (select auth.uid()) or v.estado <> 'en_camion' then raise exception 'This bag is not on your list.'; end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.bolsas set incidencia = left(btrim(p_motivo), 200), incidencia_en = now() where id = p_bolsa;
  perform public._evento('bolsa no entregada: ' || left(btrim(p_motivo), 200), v.limpieza_id, null);
end $$;

-- Lista del driver: sus bolsas y sus tareas cogidas
create or replace function public.mis_trabajos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return jsonb_build_object(
    'bolsas', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'limpieza_id', b.limpieza_id, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'incidencia', b.incidencia,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end)
        order by (c.fecha = v_hoy and c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = (select auth.uid()) and b.estado = 'en_camion'), '[]'::jsonb));
end $$;

-- 5. Entregar y "no pude": quien cogió la tarea (aunque sea de otra zona); si nadie, el driver de la zona ----
create or replace function public.marcar_entregado(p_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  -- Lo hace quien la cogió; si nadie la cogió, cualquier driver de esa zona; siempre el líder u Operación
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Another driver is on this job.';
  end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and (public.mi_zona() = v.zona or coalesce(v.tomado_por = (select auth.uid()), false)))) then
    raise exception 'Solo el driver de la zona puede marcar la entrega.';
  end if;
  if v.tipo = 'linens' and v.estado = 'preparado' then
    update public.pendientes set estado = 'entregado', entregado_por = (select auth.uid()), entregado_en = now() where id = p_id;
    perform public._evento('entregado por driver', v.limpieza_id, p_id);
  elsif v.tipo::text = 'utiles' and v.estado = 'preparado' then
    -- Utiles: el driver los deja en el apto y queda cerrado (no hay nadie que marque recibido)
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('útiles entregados por driver', v.limpieza_id, p_id);
  elsif v.tipo = 'recogida' and v.estado = 'abierto' then
    update public.pendientes set estado = 'cerrado', entregado_por = (select auth.uid()), entregado_en = now(),
                                 cerrado_por = (select auth.uid()), cerrado_en = now() where id = p_id;
    perform public._evento('recogido por driver', v.limpieza_id, p_id);
  else
    raise exception 'Ese pendiente todavía no está listo para el driver.';
  end if;
end $$;

create or replace function public.no_pude_entregar(p_id uuid, p_motivo text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.pendientes;
begin
  select * into v from public.pendientes where id = p_id for update;
  if not found then raise exception 'Ese pendiente no existe.'; end if;
  -- Lo hace quien la cogió; si nadie la cogió, cualquier driver de esa zona; siempre el líder u Operación
  if v.tomado_por is not null and v.tomado_por <> (select auth.uid())
     and not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Another driver is on this job.';
  end if;
  if not (public.mi_nivel() = 'operacion'
          or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')
          or (public.mi_nivel() = 'operador' and public.mi_departamento() = 'Drivers' and (public.mi_zona() = v.zona or coalesce(v.tomado_por = (select auth.uid()), false)))) then
    raise exception 'Solo el driver de la zona puede marcarlo.';
  end if;
  if not ((v.tipo::text in ('linens', 'utiles') and v.estado = 'preparado') or (v.tipo = 'recogida' and v.estado = 'abierto')) then
    raise exception 'Ese pendiente no está en manos del driver.';
  end if;
  if length(btrim(coalesce(p_motivo, ''))) < 3 then raise exception 'Write the reason.'; end if;
  update public.pendientes set incidencia = left(btrim(p_motivo), 200), incidencia_en = now() where id = p_id;
  perform public._evento('no se pudo entregar: ' || left(btrim(p_motivo), 200), v.limpieza_id, p_id);
end $$;

-- 6. Pantallas: el driver ve primero los check-in de hoy; el cleaner ve su bolsa; avisos de asignación ----
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
        order by pe.prioritario desc, c.hora_entrada nulls last, pe.creado_en)
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

create or replace function public.mi_dia(p_fecha date)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select coalesce(jsonb_agg(x order by (x->>'orden')::int nulls last), '[]'::jsonb) from (
    select jsonb_build_object(
      'id', l.id, 'orden', l.orden, 'tipo', l.tipo, 'estado', l.estado, 'motivo', l.motivo_no_entrar, 'linens_revisado', l.linens_revisado,
      'bolsa', (select jsonb_build_object('estado', b.estado, 'entregada_en', to_char(b.entregada_en at time zone 'Europe/Malta', 'HH24:MI'), 'comentario', b.comentario) from public.bolsas b where b.limpieza_id = l.id),
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

    if pe.asignado_por is not null and pe.tomado_por is not null and pe.tomado_en > now() - interval '2 minutes' then
      -- 14. El líder asigna una tarea a un driver concreto → ese driver
      insert into _dest select p.id, p.idioma,
        'Asignado a ti: ' || pr.codigo, 'Assigned to you: ' || pr.codigo,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'recoger' else 'entregar' end,
        pr.pueblo || ' · ' || case when pe.tipo = 'recogida' then 'pick up' else 'deliver' end,
        './', 'pendiente:' || pe.id || ':asignado:' || extract(epoch from pe.tomado_en)::bigint || ':' || p.id
      from public.perfiles p where p.activo and p.id = pe.tomado_por;

    elsif pe.incidencia is not null and pe.incidencia_en > now() - interval '2 minutes'
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

-- 7. Permisos -------------------------------------------------------------------------
revoke execute on function public.tablero_zonas(), public.tomar_tarea(uuid), public.soltar_tarea(uuid), public.asignar_tarea(uuid, uuid),
  public.bolsas_dia(date), public.preparar_bolsa(uuid, boolean), public.bolsas_etiquetas(date), public.escanear_bolsa(text),
  public.entregar_bolsa(uuid, text, text), public.no_pude_entregar_bolsa(uuid, text), public.mis_trabajos() from public, anon;
grant execute on function public.tablero_zonas(), public.tomar_tarea(uuid), public.soltar_tarea(uuid), public.asignar_tarea(uuid, uuid),
  public.bolsas_dia(date), public.preparar_bolsa(uuid, boolean), public.bolsas_etiquetas(date), public.escanear_bolsa(text),
  public.entregar_bolsa(uuid, text, text), public.no_pude_entregar_bolsa(uuid, text), public.mis_trabajos() to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;
