-- OpsFlow · rutas con TomTom, hora de entrada de los equipos y aviso "listo en 30 min" (12 oct 2026)
-- SPEC-rutas-driver.md (aprobado). Ejecutar DESPUES de 025. Se puede ejecutar varias veces. Todo UPDATE/DELETE lleva WHERE.
--   1. Hora de entrada de cada equipo (la fija la líder de limpieza; por defecto 11:00) = hora límite de sus bolsas.
--   2. "Ready for pickup in 30 min": el cleaner avisa y los drivers de la zona lo ven y lo cogen.
--   3. Punto de salida (linens / bodega) y la última ruta calculada de cada driver (la escribe la función "ruta").

-- 1. Hora de entrada por equipo y día ---------------------------------------------------
create table if not exists public.entradas_equipo (
  fecha        date not null,
  cleaner      uuid not null references public.perfiles(id),
  hora         time not null check (hora between '05:00' and '20:00'),
  fijada_por   uuid, fijada_en timestamptz not null default now(),
  primary key (fecha, cleaner)
);
alter table public.entradas_equipo enable row level security;
revoke all on public.entradas_equipo from anon;
revoke insert, update, delete, truncate on public.entradas_equipo from authenticated;
drop policy if exists "entradas: lectura" on public.entradas_equipo;
create policy "entradas: lectura" on public.entradas_equipo for select to authenticated using (
  (select public.mi_nivel()) = 'operacion'
  or (select public.mi_departamento()) in ('Limpieza', 'Drivers') and (select public.mi_nivel()) = 'lider'
  or (select public.mi_departamento()) = 'Drivers'
  or cleaner = (select auth.uid())
);

-- Hora de entrada de un equipo (11:00 si nadie la cambió) y hora límite de la bolsa de una limpieza
create or replace function public._hora_entrada(p_fecha date, p_cleaner uuid)
returns time language sql stable security definer set search_path = ''
as $$ select coalesce((select hora from public.entradas_equipo where fecha = p_fecha and cleaner = p_cleaner), time '11:00') $$;
create or replace function public._limite_bolsa(p_limpieza uuid)
returns timestamptz language sql stable security definer set search_path = ''
as $$ select (l.fecha + public._hora_entrada(l.fecha, l.asignada_a)) at time zone 'Europe/Malta' from public.limpiezas l where l.id = p_limpieza $$;
revoke execute on function public._hora_entrada(date, uuid), public._limite_bolsa(uuid) from public, anon, authenticated;

-- Líder de limpieza u Operación: fijar la hora de entrada de un equipo
create or replace function public.fijar_entrada(p_fecha date, p_cleaner uuid, p_hora time)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public._lider_limpieza() then raise exception 'Solo la líder de limpieza u Operación fijan la hora de entrada.'; end if;
  if p_hora is null or p_hora < time '05:00' or p_hora > time '20:00' then raise exception 'La hora tiene que estar entre las 05:00 y las 20:00.'; end if;
  if p_fecha < (now() at time zone 'Europe/Malta')::date then raise exception 'No se cambia la hora de un día que ya pasó.'; end if;
  if not exists (select 1 from public.perfiles where id = p_cleaner and departamento = 'Limpieza' and nivel = 'operador') then
    raise exception 'Ese equipo no existe.';
  end if;
  insert into public.entradas_equipo (fecha, cleaner, hora, fijada_por) values (p_fecha, p_cleaner, p_hora, (select auth.uid()))
  on conflict (fecha, cleaner) do update set hora = excluded.hora, fijada_por = excluded.fijada_por, fijada_en = now();
  insert into public.eventos (quien, que) values ((select auth.uid()),
    'hora de entrada ' || to_char(p_hora, 'HH24:MI') || ' · ' || (select nombre from public.perfiles where id = p_cleaner) || ' · ' || to_char(p_fecha, 'DD/MM'));
end $$;

-- Equipos con limpiezas ese día y su hora de entrada (pantalla de reparto)
create or replace function public.entradas_dia(p_fecha date)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public._lider_limpieza() or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo los líderes u Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('cleaner', p.id, 'nombre', p.nombre, 'zona', p.zona,
      'hora', to_char(public._hora_entrada(p_fecha, p.id), 'HH24:MI'),
      'fijada', exists (select 1 from public.entradas_equipo e where e.fecha = p_fecha and e.cleaner = p.id),
      'limpiezas', (select count(*) from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada'))
      order by p.nombre)
    from public.perfiles p
    where exists (select 1 from public.limpiezas l where l.fecha = p_fecha and l.asignada_a = p.id and l.estado::text <> 'cancelada')), '[]'::jsonb);
end $$;

-- 2. Aviso "listo para recoger en 30 min" -------------------------------------------------
alter table public.pendientes add column if not exists listo_a timestamptz;   -- solo en la recogida que nace del aviso

create or replace function public.avisar_listo(p_limpieza uuid)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_id uuid; v_prio boolean;
begin
  v := public._mi_limpieza(p_limpieza);
  if v.estado <> 'en_curso' then raise exception 'Start the cleaning first.'; end if;
  if exists (select 1 from public.pendientes where limpieza_id = v.id and tipo = 'recogida' and listo_a is not null) then
    raise exception 'You already told the drivers.';
  end if;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, listo_a)
  values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Listo para recoger', 1, coalesce(v_prio, false),
          (select auth.uid()), v.es_prueba, now() + interval '30 minutes')
  returning id into v_id;
  perform public._evento('aviso: listo para recoger en 30 min', v.id, v_id);
  return v_id;
end $$;

-- Deshacer el aviso (solo en los 5 minutos siguientes y si nadie lo ha recogido)
create or replace function public.deshacer_listo(p_limpieza uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; pe public.pendientes;
begin
  v := public._mi_limpieza(p_limpieza);
  select * into pe from public.pendientes where limpieza_id = v.id and tipo = 'recogida' and listo_a is not null for update;
  if not found then raise exception 'There is nothing to undo.'; end if;
  if pe.estado <> 'abierto' then raise exception 'A driver already picked it up.'; end if;
  if pe.creado_en < now() - interval '5 minutes' then raise exception 'Too late to undo (5 minutes). Call your leader.'; end if;
  delete from public.pendientes where id = pe.id;
  perform public._evento('aviso de recogida deshecho por el cleaner', v.id, null);
end $$;

-- 3. Punto de salida (linens / bodega) y rutas calculadas --------------------------------
create table if not exists public.puntos_base (
  clave       text primary key,
  nombre      text not null,
  enlace      text,
  lat         double precision, lng double precision,
  cambiado_por uuid, cambiado_en timestamptz not null default now()
);
alter table public.puntos_base enable row level security;
revoke all on public.puntos_base from anon;
revoke insert, update, delete, truncate on public.puntos_base from authenticated;
drop policy if exists "puntos: lectura" on public.puntos_base;
create policy "puntos: lectura" on public.puntos_base for select to authenticated using (
  (select public.mi_nivel()) = 'operacion' or (select public.mi_departamento()) = 'Drivers');
-- El enlace que dio Ivan; la función "ruta" saca la coordenada la primera vez que hace falta
insert into public.puntos_base (clave, nombre, enlace) values ('bodega', 'Linens / bodega', 'https://maps.app.goo.gl/eDVmMA2AUQfzM4My5')
on conflict (clave) do nothing;

-- Operación: cambiar el punto (coordenadas, o un enlace nuevo para que la función lo resuelva)
create or replace function public.fijar_bodega(p_lat double precision, p_lng double precision, p_enlace text default null)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if public.mi_nivel() is distinct from 'operacion' then raise exception 'Solo Operación cambia el punto de bodega.'; end if;
  if p_lat is null and nullif(btrim(coalesce(p_enlace, '')), '') is null then raise exception 'Da las coordenadas o un enlace de mapa.'; end if;
  if p_lat is not null and not public._en_malta(p_lat, p_lng) then raise exception 'Ese punto está fuera de Malta y Gozo.'; end if;
  update public.puntos_base set lat = p_lat, lng = case when p_lat is null then null else p_lng end,
         enlace = coalesce(nullif(btrim(coalesce(p_enlace, '')), ''), enlace), cambiado_por = (select auth.uid()), cambiado_en = now()
   where clave = 'bodega';
  insert into public.eventos (quien, que) values ((select auth.uid()), 'punto de bodega cambiado');
end $$;

-- Servidor (función "ruta"): guardar la coordenada resuelta del enlace, solo si aún no hay
create or replace function public.guardar_bodega_resuelta(p_lat double precision, p_lng double precision)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if not public._en_malta(p_lat, p_lng) then raise exception 'Fuera de Malta.'; end if;
  update public.puntos_base set lat = p_lat, lng = p_lng, cambiado_en = now() where clave = 'bodega' and lat is null;
end $$;

create table if not exists public.rutas_driver (
  driver       uuid primary key references public.perfiles(id),
  fecha        date not null,
  calculada_en timestamptz not null default now(),
  firma        text not null,
  datos        jsonb not null
);
alter table public.rutas_driver enable row level security;
revoke all on public.rutas_driver from anon;
revoke insert, update, delete, truncate on public.rutas_driver from authenticated;
drop policy if exists "rutas: lectura" on public.rutas_driver;
create policy "rutas: lectura" on public.rutas_driver for select to authenticated using (
  driver = (select auth.uid())
  or (select public.mi_nivel()) = 'operacion'
  or ((select public.mi_nivel()) = 'lider' and (select public.mi_departamento()) = 'Drivers'));

create or replace function public.guardar_ruta(p_driver uuid, p_firma text, p_datos jsonb)
returns void language sql security definer set search_path = ''
as $$
  insert into public.rutas_driver (driver, fecha, calculada_en, firma, datos)
  values (p_driver, (now() at time zone 'Europe/Malta')::date, now(), p_firma, p_datos)
  on conflict (driver) do update set fecha = excluded.fecha, calculada_en = now(), firma = excluded.firma, datos = excluded.datos
$$;

-- Servidor: las paradas de un driver (sus bolsas en el camión y las tareas que ha cogido) con punto y horas
create or replace function public.paradas_driver(p_driver uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not exists (select 1 from public.perfiles where id = p_driver and activo and departamento = 'Drivers' and nivel = 'operador') then
    raise exception 'Solo para drivers activos.';
  end if;
  return jsonb_build_object(
    'bodega', (select jsonb_build_object('lat', lat, 'lng', lng, 'enlace', enlace) from public.puntos_base where clave = 'bodega'),
    'paradas', coalesce((select jsonb_agg(x) from (
      select jsonb_build_object('id', b.id, 'clase', 'bolsa', 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end,
        'coord', p.coord_estado, 'limite', public._limite_bolsa(l.id), 'no_antes', null,
        'equipo', to_char(public._hora_entrada(l.fecha, l.asignada_a), 'HH24:MI'),
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end) as x
      from public.bolsas b join public.limpiezas l on l.id = b.limpieza_id join public.propiedades p on p.id = b.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = p_driver and b.estado = 'en_camion'
      union all
      select jsonb_build_object('id', pe.id, 'clase', pe.tipo::text, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end,
        'coord', p.coord_estado,
        -- faltantes de linens: antes del check-in de hoy; basura y útiles no tienen hora límite
        'limite', case when pe.tipo = 'linens' and c.fecha = v_hoy and c.hora_entrada is not null
                       then (c.fecha + c.hora_entrada) at time zone 'Europe/Malta' end,
        'no_antes', case when pe.tipo = 'recogida' and l.estado <> 'terminada' then pe.listo_a end,
        'listo', pe.listo_a is not null, 'equipo', null,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end)
      from public.pendientes pe join public.limpiezas l on l.id = pe.limpieza_id join public.propiedades p on p.id = pe.propiedad_id
      join public.checkouts c on c.id = l.checkout_id
      where pe.tomado_por = p_driver and public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb));
end $$;

-- Líder de drivers u Operación: la última ruta de hoy de cada driver
create or replace function public.rutas_hoy()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
begin
  if not (public.mi_nivel() = 'operacion' or (public.mi_nivel() = 'lider' and public.mi_departamento() = 'Drivers')) then
    raise exception 'Solo el líder de drivers u Operación.';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object('driver', p.nombre, 'zona', p.zona, 'calculada_en', r.calculada_en, 'datos', r.datos) order by p.nombre)
    from public.rutas_driver r join public.perfiles p on p.id = r.driver
    where r.fecha = (now() at time zone 'Europe/Malta')::date and p.activo), '[]'::jsonb);
end $$;

-- 4. Pantallas que cambian ---------------------------------------------------------------
-- Tablero de zonas: + hora de "listo", si la limpieza ya terminó y el punto confirmado del apto
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
      'tomado_por', t.nombre,
      'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'terminada', l.estado = 'terminada',
      'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado, 'mio', pe.tomado_por = (select auth.uid()), 'asignado', pe.asignado_por is not null) as x
    from public.pendientes pe
    join public.propiedades p on p.id = pe.propiedad_id
    join public.limpiezas l on l.id = pe.limpieza_id
    join public.checkouts c on c.id = l.checkout_id
    left join public.perfiles t on t.id = pe.tomado_por
    where public._en_driver(pe) and pe.fecha >= v_hoy - 7) s), '[]'::jsonb);
end $$;

-- Lista del driver: sus bolsas (con la hora límite = entrada del equipo y el punto) y las bolsas listas en linens hoy
create or replace function public.mis_trabajos()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v_hoy date := (now() at time zone 'Europe/Malta')::date;
begin
  if not public._es_driver() then raise exception 'Esta pantalla es para drivers.'; end if;
  return jsonb_build_object(
    'bolsas', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'limpieza_id', b.limpieza_id, 'zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'direccion', p.direccion, 'mapa', p.mapa_url, 'incidencia', b.incidencia,
        'entrada', case when c.fecha = v_hoy then to_char(c.hora_entrada, 'HH24:MI') end,
        'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'),
        'lat', case when p.coord_estado = 'confirmada' then p.lat end, 'lng', case when p.coord_estado = 'confirmada' then p.lng end, 'coord', p.coord_estado)
        order by public._limite_bolsa(l.id), (c.fecha = v_hoy and c.hora_entrada is not null) desc, c.hora_entrada, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.driver = (select auth.uid()) and b.estado = 'en_camion'), '[]'::jsonb),
    'listas', coalesce((select jsonb_agg(jsonb_build_object('zona', b.zona, 'codigo', p.codigo, 'nombre', p.nombre, 'pueblo', p.pueblo,
        'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'limite', to_char(public._limite_bolsa(l.id) at time zone 'Europe/Malta', 'HH24:MI'))
        order by public._limite_bolsa(l.id), c.hora_entrada nulls last, p.codigo)
      from public.bolsas b join public.propiedades p on p.id = b.propiedad_id join public.limpiezas l on l.id = b.limpieza_id
      join public.checkouts c on c.id = l.checkout_id
      where b.fecha = v_hoy and b.estado = 'preparada' and l.estado::text <> 'cancelada'), '[]'::jsonb));
end $$;

-- Día del cleaner: + la hora de "listo" del aviso de recogida (y cuándo lo mandó, para poder deshacer 5 min)
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
                     'cantidad', pe.cantidad, 'estado', pe.estado, 'items', pe.items,
                     'listo_a', to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI'), 'listo_creado', case when pe.listo_a is not null then pe.creado_en end) order by pe.creado_en)
                     from public.pendientes pe where pe.limpieza_id = l.id), '[]'::jsonb)) x
    from public.limpiezas l
    join public.propiedades p on p.id = l.propiedad_id
    join public.checkouts c on c.id = l.checkout_id
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid()) and l.estado::text <> 'cancelada'
      and public.mi_nivel() is not null
  ) t
$$;

-- Cierre: igual que en 017, pero la basura se une al aviso "listo en 30 min" si lo hubo
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
    -- Si ya avisó "listo en 30 min", la basura va en esa misma recogida (no se crea otra)
    v_id := null;
    select id into v_id from public.pendientes
     where limpieza_id = v.id and tipo = 'recogida' and listo_a is not null and estado = 'abierto';
    if v_id is not null then
      update public.pendientes set detalle = 'Basura dejada en el apto', foto = v_foto where id = v_id;
      perform public._evento('cierre: basura en el apto (va en el aviso de recogida)', v.id, v_id);
    else
      insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, foto)
      values (v.id, v.propiedad_id, v.zona, v.fecha, 'recogida', 'Basura dejada en el apto', 1, coalesce(v_prio, false),
              (select auth.uid()), v.es_prueba, v_foto)
      returning id into v_id;
      perform public._evento('cierre: basura en el apto', v.id, v_id);
    end if;
    v_ids := v_ids || v_id;
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

-- Avisos: + "listo para recoger a las HH:MM" a los drivers de la zona
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

    elsif pe.tipo = 'recogida' and pe.estado = 'abierto' and pe.listo_a is not null then
      -- 15. El cleaner avisa "listo en 30 min" → drivers de la zona
      insert into _dest select p.id, p.idioma,
        'Listo a las ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        'Ready at ' || to_char(pe.listo_a at time zone 'Europe/Malta', 'HH24:MI') || ': ' || pr.codigo,
        pr.pueblo || ' · recoger basura y linens sucios', pr.pueblo || ' · pick up trash & dirty linens',
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

-- 5. Permisos ----------------------------------------------------------------------------
revoke execute on function public.fijar_entrada(date, uuid, time), public.entradas_dia(date), public.avisar_listo(uuid),
  public.deshacer_listo(uuid), public.fijar_bodega(double precision, double precision, text), public.rutas_hoy() from public, anon;
grant  execute on function public.fijar_entrada(date, uuid, time), public.entradas_dia(date), public.avisar_listo(uuid),
  public.deshacer_listo(uuid), public.fijar_bodega(double precision, double precision, text), public.rutas_hoy() to authenticated;
revoke execute on function public.guardar_bodega_resuelta(double precision, double precision), public.guardar_ruta(uuid, text, jsonb),
  public.paradas_driver(uuid) from public, anon, authenticated;
grant  execute on function public.guardar_bodega_resuelta(double precision, double precision), public.guardar_ruta(uuid, text, jsonb),
  public.paradas_driver(uuid) to service_role;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;
