-- OpsFlow · limpieza guiada v4: revisión de linens al empezar y reporte único (10 oct 2026)
-- Después del QR, el cleaner revisa la bolsa: reporta todo lo que falta en UN pedido, o "Nothing missing".
-- Hasta entonces no puede marcar pasos, subir fotos ni cerrar. Ejecutar DESPUES de 013. Se puede ejecutar varias veces.
-- Todo UPDATE/DELETE lleva WHERE (Supabase los bloquea si no).

-- 1. Datos nuevos -----------------------------------------------------------------
alter table public.limpiezas  add column if not exists linens_revisado timestamptz;  -- cuándo hizo la revisión de linens
alter table public.pendientes add column if not exists items jsonb;                  -- [{"item": "sabana_doble", "cantidad": 2}, ...]

-- Artículos de la bolsa de linens (clave, nombre en español para linens)
create or replace function public._linens_nombre(p_item text)
returns text language sql immutable set search_path = ''
as $$
  select case p_item
    when 'sabana_doble' then 'Sábana doble'            when 'sabana_sencilla' then 'Sábana sencilla'
    when 'funda_duvet_doble' then 'Funda duvet doble'  when 'funda_duvet_sencilla' then 'Funda duvet sencilla'
    when 'funda_almohada' then 'Funda de almohada'     when 'toalla_grande' then 'Toalla grande'
    when 'toalla_pequena' then 'Toalla pequeña'        when 'alfombra_bano' then 'Alfombra de baño'
    when 'toalla_cocina' then 'Toalla de cocina'       when 'esponja' then 'Esponja'
    when 'papel_higienico' then 'Papel higiénico'      else null end
$$;
revoke execute on function public._linens_nombre(text) from public, anon, authenticated;

-- Texto del pedido para los avisos: "2 × Sábana doble · 1 × Toalla grande" / "2 × Double sheet · 1 × Large towel"
create or replace function public._linens_texto(p_items jsonb, p_idioma text)
returns text language sql immutable set search_path = ''
as $$
  select string_agg((x->>'cantidad') || ' × ' || case when p_idioma = 'es' then public._linens_nombre(x->>'item') else
    case x->>'item'
      when 'sabana_doble' then 'Double sheet'           when 'sabana_sencilla' then 'Single sheet'
      when 'funda_duvet_doble' then 'Double duvet cover' when 'funda_duvet_sencilla' then 'Single duvet cover'
      when 'funda_almohada' then 'Pillowcase'           when 'toalla_grande' then 'Large towel'
      when 'toalla_pequena' then 'Small towel'          when 'alfombra_bano' then 'Bath mat'
      when 'toalla_cocina' then 'Kitchen towel'         when 'esponja' then 'Sponge'
      when 'papel_higienico' then 'Toilet paper'        else x->>'item' end end, ' · ')
  from jsonb_array_elements(p_items) x
$$;
revoke execute on function public._linens_texto(jsonb, text) from public, anon, authenticated;

-- 2. Revisión de linens --------------------------------------------------------------
-- Reporte único: varios artículos con cantidad → UN pendiente de linens
create or replace function public.reportar_linens(p_limpieza uuid, p_items jsonb)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas; v_prio boolean; v_id uuid; v_items jsonb; v_total int; v_texto text; v_malo int;
begin
  v := public._mi_limpieza(p_limpieza);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Choose at least one item.';
  end if;
  -- Validar: artículos conocidos, cantidades 1..50, sin repetir
  select count(*) into v_malo from jsonb_array_elements(p_items) x
   where public._linens_nombre(x->>'item') is null
      or jsonb_typeof(x->'cantidad') is distinct from 'number'
      or (x->>'cantidad')::numeric not between 1 and 50 or (x->>'cantidad')::numeric <> floor((x->>'cantidad')::numeric);
  if v_malo > 0 then raise exception 'Item or quantity not valid.'; end if;
  if (select count(distinct x->>'item') from jsonb_array_elements(p_items) x) <> jsonb_array_length(p_items) then
    raise exception 'Each item only once (use the quantity).';
  end if;
  select jsonb_agg(jsonb_build_object('item', x->>'item', 'cantidad', (x->>'cantidad')::int)),
         sum((x->>'cantidad')::int),
         string_agg((x->>'cantidad') || ' × ' || public._linens_nombre(x->>'item'), ' · ')
    into v_items, v_total, v_texto
    from jsonb_array_elements(p_items) x;
  select (hora_entrada is not null) into v_prio from public.checkouts where id = v.checkout_id;
  insert into public.pendientes (limpieza_id, propiedad_id, zona, fecha, tipo, detalle, cantidad, prioritario, creado_por, es_prueba, items)
  values (v.id, v.propiedad_id, v.zona, v.fecha, 'linens', left(v_texto, 200), least(v_total, 50), coalesce(v_prio, false),
          (select auth.uid()), v.es_prueba, v_items)
  returning id into v_id;
  update public.limpiezas set linens_revisado = coalesce(linens_revisado, now()) where id = v.id;
  perform public._evento('linens reportados (' || v_total || ')', v.id, v_id);
  return v_id;
end $$;

-- "Nothing missing": la bolsa está completa
create or replace function public.linens_ok(p_limpieza uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_limpieza);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  update public.limpiezas set linens_revisado = coalesce(linens_revisado, now()) where id = v.id;
  perform public._evento('linens revisados: nada falta', v.id, null);
end $$;

-- 3. Checklist, fotos y cierre: bloqueados hasta la revisión de linens ---------------
create or replace function public.marcar_paso(p_id uuid, p_paso int, p_hecho boolean)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if not exists (select 1 from public.checklist_pasos where id = p_paso and tipo = v.tipo and activo) then
    raise exception 'Ese paso no es de esta limpieza.';
  end if;
  update public.limpiezas
     set checklist = case when p_hecho then checklist || jsonb_build_object(p_paso::text, now())
                          else checklist - p_paso::text end
   where id = p_id;
end $$;

create or replace function public.registrar_foto(p_id uuid, p_sala text, p_ruta text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  v := public._mi_limpieza(p_id);
  if v.estado <> 'en_curso' then raise exception 'Primero hay que empezar la limpieza.'; end if;
  if v.linens_revisado is null then raise exception 'Check the linens bag first.'; end if;
  if p_sala not in ('bedroom', 'bathroom', 'kitchen', 'living', 'basura') then raise exception 'Sala no válida.'; end if;
  if split_part(p_ruta, '/', 1) <> p_id::text then raise exception 'La foto no es de esta limpieza.'; end if;
  insert into public.fotos_cierre (limpieza_id, sala, ruta, subida_por)
  values (p_id, p_sala, p_ruta, (select auth.uid()))
  on conflict (limpieza_id, sala) do update set ruta = excluded.ruta, subida_en = now(), subida_por = excluded.subida_por;
end $$;

create or replace function public.cerrar_limpieza(
  p_id uuid, p_qr text, p_escoba boolean, p_squeegee boolean, p_recogedor boolean,
  p_basura boolean, p_llaves boolean, p_motivo_llaves text default null)
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
    cierre = jsonb_build_object('escoba', p_escoba, 'squeegee', p_squeegee, 'recogedor', p_recogedor,
                                'basura', p_basura, 'llaves', p_llaves,
                                'motivo_llaves', case when p_llaves then null else left(btrim(p_motivo_llaves), 200) end)
  where id = p_id;
  perform public._evento('limpieza terminada' || case when p_qr is null then ' (salida sin QR)' else '' end
                         || case when p_llaves then '' else ' · llaves NO en key box' end, p_id, null);
  return jsonb_build_object('pendientes', to_jsonb(v_ids), 'llaves', p_llaves);
end $$;

-- 4. Pantallas: los artículos del reporte llegan a cleaner y driver; la checklist sabe si ya revisó -----
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
    where l.fecha = p_fecha and l.publicada and l.asignada_a = (select auth.uid())
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
        'direccion', p.direccion, 'mapa', p.mapa_url, 'entrada', to_char(c.hora_entrada, 'HH24:MI'), 'foto', pe.foto, 'items', pe.items)
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
      where l.fecha = p_fecha and l.zona = v_zona and l.publicada), '[]'::jsonb));
end $$;

create or replace function public.mi_checklist(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare v public.limpiezas;
begin
  select * into v from public.limpiezas where id = p_id;
  if not found or public.mi_nivel() is null
     or not (public._lider_limpieza() or (v.asignada_a = (select auth.uid()) and v.publicada)) then
    raise exception 'Esta limpieza no es tuya.';
  end if;
  return jsonb_build_object(
    'inicio_qr', v.inicio_qr, 'fin_qr', v.fin_qr, 'linens_revisado', v.linens_revisado, 'cierre', v.cierre, 'personas', v.personas, 'estado', v.estado,
    'pasos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'sala', p.sala, 'en', p.texto_en, 'es', p.texto_es,
                          'obligatorio', p.obligatorio, 'hecho', v.checklist ? p.id::text) order by p.orden)
                       from public.checklist_pasos p where p.tipo = v.tipo and p.activo), '[]'::jsonb),
    'fotos', coalesce((select jsonb_object_agg(f.sala, f.ruta) from public.fotos_cierre f where f.limpieza_id = p_id), '{}'::jsonb));
end $$;

-- Avisos: el pedido completo en un solo aviso, en el idioma de cada persona
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

-- 5. Permisos -------------------------------------------------------------------------
revoke execute on function public.reportar_linens(uuid, jsonb), public.linens_ok(uuid) from public, anon;
grant  execute on function public.reportar_linens(uuid, jsonb), public.linens_ok(uuid) to authenticated;
revoke execute on function public.avisos_para(text, uuid, date) from public, anon, authenticated;
grant  execute on function public.avisos_para(text, uuid, date) to service_role;
